package io.github.zigansh1n.velikiymoguchiy.dictation

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DashScopeProtocolTest {
    private fun obj(text: String) = Json.parseToJsonElement(text).jsonObject

    @Test
    fun keyStaysOutOfTheUrl() {
        val endpoint = DashScopeProtocol.endpoint(" sk-test-key \n", DashScopeModel.ASR, DashScopeRegion.INTERNATIONAL)
        assertEquals("wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime", endpoint.url)
        assertEquals("Bearer sk-test-key", endpoint.headers["Authorization"])
    }

    @Test(expected = DictationException.MissingKey::class)
    fun placeholderKeyIsMissing() {
        DashScopeProtocol.endpoint("YOUR_DASHSCOPE_API_KEY", DashScopeModel.OMNI, DashScopeRegion.CHINA)
    }

    @Test
    fun asrSessionUpdate() {
        val session = obj(DashScopeProtocol.sessionUpdate(DashScopeModel.ASR, DictationLanguage.RUSSIAN))["session"]!!.jsonObject
        assertEquals(JsonNull, session["turn_detection"])
        assertEquals(16000, session["sample_rate"]!!.jsonPrimitive.content.toInt())
        val transcription = session["input_audio_transcription"]!!.jsonObject
        assertEquals("qwen3-asr-flash-realtime", transcription["model"]!!.jsonPrimitive.content)
        assertEquals("ru", transcription["language"]!!.jsonPrimitive.content)
        assertFalse("voice" in session)
    }

    @Test
    fun omniSessionUpdateHasVoiceAndInstructions() {
        val session = obj(DashScopeProtocol.sessionUpdate(DashScopeModel.OMNI, DictationLanguage.ENGLISH))["session"]!!.jsonObject
        assertEquals("Serena", session["voice"]!!.jsonPrimitive.content)
        assertTrue(session["instructions"]!!.jsonPrimitive.content.startsWith("You are a dictation module"))
        assertEquals("en", session["input_audio_transcription"]!!.jsonObject["language"]!!.jsonPrimitive.content)
    }

    @Test
    fun audioIsBase64() {
        val message = obj(DashScopeProtocol.audioAppend(byteArrayOf(1, 2, 3, 4), length = 3))
        assertEquals("input_audio_buffer.append", message["type"]!!.jsonPrimitive.content)
        assertEquals("AQID", message["audio"]!!.jsonPrimitive.content)
    }

    @Test
    fun parsesServerEvents() {
        assertEquals(DashScopeProtocol.ServerEvent.SessionCreated, DashScopeProtocol.parse("""{"type":"session.created"}"""))
        assertEquals(
            DashScopeProtocol.ServerEvent.Preview("Привет как"),
            DashScopeProtocol.parse("""{"type":"conversation.item.input_audio_transcription.delta","text":"Привет ","stash":"как"}"""),
        )
        assertEquals(
            DashScopeProtocol.ServerEvent.Completed("Привет."),
            DashScopeProtocol.parse("""{"type":"conversation.item.input_audio_transcription.completed","transcript":"Привет."}"""),
        )
        assertEquals(
            DashScopeProtocol.ServerEvent.Completed("Да."),
            DashScopeProtocol.parse(
                """{"type":"conversation.item.input_audio_transcription.completed","item":{"content":[{"transcript":"Да."}]}}""",
            ),
        )
        assertEquals(
            DashScopeProtocol.ServerEvent.Error("InvalidApiKey", "Invalid API-key provided."),
            DashScopeProtocol.parse("""{"type":"error","error":{"code":"InvalidApiKey","message":"Invalid API-key provided."}}"""),
        )
        assertEquals(DashScopeProtocol.ServerEvent.Other, DashScopeProtocol.parse("""{"type":"input_audio_buffer.committed"}"""))
    }

    @Test(expected = DictationException.InvalidMessage::class)
    fun garbageIsInvalid() {
        DashScopeProtocol.parse("not json")
    }

    @Test
    fun keyProblems() {
        assertTrue(DashScopeProtocol.isKeyProblem("InvalidApiKey", ""))
        assertTrue(DashScopeProtocol.isKeyProblem("", "Arrearage: account overdue"))
        assertFalse(DashScopeProtocol.isKeyProblem("InternalError", "timeout"))
    }
}
