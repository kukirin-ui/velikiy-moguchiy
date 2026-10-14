package io.github.zigansh1n.velikiymoguchiy.emulator

import io.github.zigansh1n.velikiymoguchiy.dictation.AudioInput
import io.github.zigansh1n.velikiymoguchiy.dictation.DashScopeEndpoint
import io.github.zigansh1n.velikiymoguchiy.dictation.Pcm16
import io.github.zigansh1n.velikiymoguchiy.dictation.RealtimeSocket
import io.github.zigansh1n.velikiymoguchiy.dictation.SocketEvent
import io.github.zigansh1n.velikiymoguchiy.dictation.SocketFactory
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlin.math.PI
import kotlin.math.sin

/**
 * Answers like DashScope's ASR model (`qwen3-asr-flash-realtime`) without a socket: the session
 * gets the same server messages it would get over the network, and [transcript] as the result.
 */
class ScriptedDashScope(private val transcript: String) : SocketFactory {
    /** Client message types in order, without the audio appends, which are only counted. */
    val received: MutableList<String> = CopyOnWriteArrayList()
    val audioChunks = AtomicInteger()
    @Volatile var endpoint: DashScopeEndpoint? = null
    @Volatile var closed = false

    override fun open(endpoint: DashScopeEndpoint, listener: (SocketEvent) -> Unit): RealtimeSocket {
        this.endpoint = endpoint
        listener(event("session.created"))
        return object : RealtimeSocket {
            override fun send(text: String): Boolean {
                val type = Json.parseToJsonElement(text).jsonObject["type"]?.jsonPrimitive?.content.orEmpty()
                if (type == "input_audio_buffer.append") audioChunks.incrementAndGet() else received += type
                when (type) {
                    "session.update" -> listener(event("session.updated"))
                    "session.finish" -> {
                        listener(event("conversation.item.input_audio_transcription.completed", "transcript" to transcript))
                        listener(event("session.finished"))
                    }
                }
                return true
            }

            override fun close(code: Int, reason: String?) {
                closed = true
            }
        }
    }

    private fun event(type: String, vararg fields: Pair<String, String>) = SocketEvent.Text(
        buildJsonObject {
            put("type", type)
            fields.forEach { (name, value) -> put(name, value) }
        }.toString(),
    )
}

/** A steady 440 Hz tone in 100 ms chunks, loud enough to pass the keyboard's silence check. */
class ScriptedMicrophone(
    private val onChunk: (ByteArray) -> Unit,
    private val onLevel: (Float) -> Unit,
) : AudioInput {
    @Volatile private var running = false
    private var worker: Thread? = null

    override fun start() {
        running = true
        worker = thread(name = "scripted-microphone") {
            while (running) {
                onChunk(TONE.copyOf())
                onLevel(0.6f)
                Thread.sleep(100)
            }
        }
    }

    override fun stop() {
        running = false
        worker?.join(1_000)
        worker = null
    }

    private companion object {
        val TONE = ByteArray(Pcm16.CHUNK_BYTES).also { bytes ->
            for (i in 0 until bytes.size / 2) {
                val sample = (sin(2 * PI * 440 * i / Pcm16.SAMPLE_RATE) * 8_000).toInt()
                bytes[2 * i] = sample.toByte()
                bytes[2 * i + 1] = (sample shr 8).toByte()
            }
        }
    }
}
