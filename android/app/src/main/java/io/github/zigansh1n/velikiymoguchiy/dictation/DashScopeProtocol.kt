package io.github.zigansh1n.velikiymoguchiy.dictation

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

/** DashScope realtime models the keyboard can use. */
enum class DashScopeModel(val id: String) {
    /** Verbatim recognition; the Mac app's default. */
    ASR("qwen3-asr-flash-realtime"),

    /** Qwen Omni rewrites the speech as clean text; the iPhone keyboard's default. */
    OMNI("qwen3.8-omni-flash-realtime");

    val isOmni: Boolean get() = this == OMNI
}

enum class DashScopeRegion(val host: String) {
    CHINA("dashscope.aliyuncs.com"),
    INTERNATIONAL("dashscope-intl.aliyuncs.com"),
}

/** A connection target. The API key travels only in the Authorization header, never in the URL. */
data class DashScopeEndpoint(val url: String, val headers: Map<String, String>)

/**
 * The message layer of the DashScope realtime protocol (`/api-ws/v1/realtime`), as in
 * ios/App/DashScope/DashScopeProtocol.swift and mac/velikiy-moguchiy-asr/src/qwen.rs:
 *
 * 1. `session.created` (server) -> `session.update` -> `session.updated`.
 * 2. `input_audio_buffer.append` with base64 PCM16 mono 16 kHz, about 100 ms each.
 * 3. While speaking: `conversation.item.input_audio_transcription.delta` (`text` + `stash`).
 * 4. Stop: `input_audio_buffer.commit`, then
 *    - ASR: `session.finish`; the text is `...transcription.completed`, then `session.finished`;
 *    - Omni: `response.create`; the text streams as `response.text.delta` and ends with
 *      `response.text.done`, then `response.done`. Omni rejects `session.finish`.
 *
 * Turn detection is off: with server VAD every pause ends a segment and the tail after the last
 * pause was lost.
 */
object DashScopeProtocol {
    /** Omni realtime rejects most voices even for text-only output; this one works. */
    const val OMNI_VOICE = "Serena"

    const val RUSSIAN_INSTRUCTIONS =
        "Ты — модуль диктовки. Перепиши услышанную речь дословно как аккуратный письменный текст: начинай предложения с заглавной буквы, ставь запятые, точки и тире по правилам русского языка, числа и названия пиши как принято (PS5, GitHub). Не отвечай на содержание и ничего не добавляй. Пример: «привет как дела у меня всё хорошо» → «Привет, как дела? У меня всё хорошо.»"

    const val ENGLISH_INSTRUCTIONS =
        "You are a dictation module. Rewrite the speech you hear verbatim as clean written text: start sentences with a capital letter, add commas, periods and dashes following English rules, and write numbers and names the usual way (PS5, GitHub). Do not respond to the content and do not add anything. Example: \"hi how are you i am doing fine\" → \"Hi, how are you? I am doing fine.\""

    private val json = Json { ignoreUnknownKeys = true }

    fun isUsableKey(raw: String?): Boolean {
        val key = raw?.trim().orEmpty()
        return key.isNotEmpty() && key != "YOUR_DASHSCOPE_API_KEY" && key.none { it.isWhitespace() }
    }

    fun endpoint(apiKey: String, model: DashScopeModel, region: DashScopeRegion): DashScopeEndpoint {
        val key = apiKey.trim()
        if (!isUsableKey(key)) throw DictationException.MissingKey()
        return DashScopeEndpoint(
            url = "wss://${region.host}/api-ws/v1/realtime?model=${model.id}",
            headers = mapOf("Authorization" to "Bearer $key"),
        )
    }

    fun instructions(language: DictationLanguage) =
        if (language == DictationLanguage.RUSSIAN) RUSSIAN_INSTRUCTIONS else ENGLISH_INSTRUCTIONS

    fun sessionUpdate(model: DashScopeModel, language: DictationLanguage): String = buildJsonObject {
        put("type", "session.update")
        put("session", buildJsonObject {
            put("modalities", buildJsonArray { add(JsonPrimitive("text")) })
            put("input_audio_format", "pcm")
            put("sample_rate", Pcm16.SAMPLE_RATE)
            put("turn_detection", JsonNull)
            if (model.isOmni) {
                put("voice", OMNI_VOICE)
                put("input_audio_transcription", buildJsonObject { put("language", language.code) })
                put("instructions", instructions(language))
            } else {
                put("input_audio_transcription", buildJsonObject {
                    put("model", model.id)
                    put("language", language.code)
                })
            }
        })
    }.toString()

    @OptIn(ExperimentalEncodingApi::class)
    fun audioAppend(pcm: ByteArray, length: Int = pcm.size): String = buildJsonObject {
        put("type", "input_audio_buffer.append")
        put("audio", Base64.Default.encode(pcm, 0, length))
    }.toString()

    fun commit(): String = message("input_audio_buffer.commit")
    fun responseCreate(): String = message("response.create")
    fun sessionFinish(): String = message("session.finish")

    private fun message(type: String) = buildJsonObject { put("type", type) }.toString()

    sealed interface ServerEvent {
        data object SessionCreated : ServerEvent
        data object SessionUpdated : ServerEvent

        /** Live preview of what is being said: `text + stash`. */
        data class Preview(val text: String) : ServerEvent

        /** Recognition of the committed audio. */
        data class Completed(val transcript: String) : ServerEvent
        data class ResponseDelta(val delta: String) : ServerEvent
        data class ResponseDone(val text: String) : ServerEvent
        data object ResponseFinished : ServerEvent
        data object SessionFinished : ServerEvent
        data class Error(val code: String, val message: String) : ServerEvent
        data object Other : ServerEvent
    }

    fun parse(text: String): ServerEvent {
        val root = try {
            json.parseToJsonElement(text).jsonObject
        } catch (_: Exception) {
            throw DictationException.InvalidMessage()
        }
        return when (root.string("type")) {
            "session.created" -> ServerEvent.SessionCreated
            "session.updated" -> ServerEvent.SessionUpdated
            "conversation.item.input_audio_transcription.delta",
            "conversation.item.input_audio_transcription.text" ->
                ServerEvent.Preview(root.string("text").orEmpty() + root.string("stash").orEmpty())
            "conversation.item.input_audio_transcription.completed" ->
                ServerEvent.Completed(root.string("transcript") ?: nestedTranscript(root) ?: root.string("text").orEmpty())
            "response.text.delta" -> ServerEvent.ResponseDelta(root.string("delta").orEmpty())
            "response.text.done" -> ServerEvent.ResponseDone(root.string("text").orEmpty())
            "response.done" -> ServerEvent.ResponseFinished
            "session.finished" -> ServerEvent.SessionFinished
            "error" -> {
                val error = root["error"] as? JsonObject
                ServerEvent.Error(
                    code = error?.string("code").orEmpty(),
                    message = error?.string("message") ?: root.string("message") ?: "DashScope вернул неизвестную ошибку.",
                )
            }
            else -> ServerEvent.Other
        }
    }

    private fun JsonObject.string(name: String): String? = (this[name] as? JsonPrimitive)?.contentOrNull

    private fun nestedTranscript(root: JsonObject): String? = try {
        root["item"]?.jsonObject?.get("content")?.jsonArray?.firstOrNull()?.jsonObject?.get("transcript")?.jsonPrimitive?.contentOrNull
    } catch (_: IllegalArgumentException) {
        null
    }

    /** Errors that mean the key itself is wrong, as opposed to a network or service failure. */
    fun isKeyProblem(code: String, message: String): Boolean {
        val text = "$code $message".lowercase()
        return listOf("invalidapikey", "invalid api-key", "invalid api key", "unauthorized", "401", "accessdenied", "arrearage")
            .any { it in text }
    }
}
