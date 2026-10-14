package io.github.zigansh1n.velikiymoguchiy.dictation

import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class DashScopeSessionTest {
    /** Answers each client message type with scripted server messages. */
    private class FakeServer(private val replies: Map<String, List<String>>) : SocketFactory {
        val sent = mutableListOf<String>()
        var closed = false

        override fun open(endpoint: DashScopeEndpoint, listener: (SocketEvent) -> Unit): RealtimeSocket {
            listener(SocketEvent.Text(event("session.created")))
            return object : RealtimeSocket {
                override fun send(text: String): Boolean {
                    val type = Json.parseToJsonElement(text).jsonObject["type"]!!.jsonPrimitive.content
                    sent += type
                    replies[type].orEmpty().forEach { listener(SocketEvent.Text(it)) }
                    return true
                }

                override fun close(code: Int, reason: String?) {
                    closed = true
                }
            }
        }
    }

    companion object {
        fun event(type: String, vararg fields: Pair<String, String>) =
            "{\"type\":\"$type\"" + fields.joinToString("") { ",\"${it.first}\":\"${it.second}\"" } + "}"

        val UPDATED = "session.update" to listOf(event("session.updated"))
        val speech = ByteArray(Pcm16.CHUNK_BYTES) { if (it % 2 == 1) 0x20 else 0 }
        val silence = ByteArray(Pcm16.CHUNK_BYTES)
    }

    private fun TestScope.session(server: FakeServer, model: DashScopeModel) = DashScopeSession(
        DashScopeEndpoint("wss://example.invalid", emptyMap()),
        model,
        DictationLanguage.RUSSIAN,
        server,
        backgroundScope,
    )

    @Test
    fun asrQueuesEarlyAudioAndReturnsTheTranscript() = runTest {
        val server = FakeServer(
            mapOf(
                UPDATED,
                "session.finish" to listOf(
                    event("conversation.item.input_audio_transcription.completed", "transcript" to "Привет, мир."),
                    event("session.finished"),
                ),
            ),
        )
        val session = session(server, DashScopeModel.ASR)
        session.offerAudio(speech)
        session.connect()
        session.offerAudio(speech)
        assertEquals("Привет, мир.", session.finish())
        assertEquals(
            listOf("session.update", "input_audio_buffer.append", "input_audio_buffer.append", "input_audio_buffer.commit", "session.finish"),
            server.sent,
        )
        assertTrue(server.closed)
    }

    @Test
    fun omniReturnsTheRewrittenText() = runTest {
        val server = FakeServer(
            mapOf(
                UPDATED,
                "response.create" to listOf(
                    event("conversation.item.input_audio_transcription.completed", "transcript" to "привет мир"),
                    event("response.text.delta", "delta" to "Привет, "),
                    event("response.text.done", "text" to "Привет, мир."),
                    event("response.done"),
                ),
            ),
        )
        val session = session(server, DashScopeModel.OMNI)
        session.connect()
        session.offerAudio(speech)
        assertEquals("Привет, мир.", session.finish())
        assertFalse("session.finish" in server.sent)
    }

    @Test
    fun omniWaitsOnlyBrieflyAfterTheText() = runTest {
        val server = FakeServer(
            mapOf(
                UPDATED,
                "response.create" to listOf(
                    event("conversation.item.input_audio_transcription.delta", "text" to "да"),
                    event("response.text.done", "text" to "Да."),
                ),
            ),
        )
        val session = session(server, DashScopeModel.OMNI)
        session.connect()
        session.offerAudio(speech)
        assertEquals("Да.", session.finish())
    }

    @Test
    fun omniAnswerToNoiseIsDropped() = runTest {
        val server = FakeServer(
            mapOf(
                UPDATED,
                "response.create" to listOf(event("response.text.done", "text" to "Не расслышал."), event("response.done")),
            ),
        )
        val session = session(server, DashScopeModel.OMNI)
        session.connect()
        session.offerAudio(speech)
        expect<DictationException.EmptyResult> { session.finish() }
    }

    @Test
    fun silenceIsNeverCommitted() = runTest {
        val server = FakeServer(mapOf(UPDATED))
        val session = session(server, DashScopeModel.ASR)
        session.connect()
        session.offerAudio(silence)
        expect<DictationException.EmptyResult> { session.finish() }
        assertFalse("input_audio_buffer.commit" in server.sent)
    }

    @Test
    fun rejectedKeyFailsTheConnection() = runTest {
        val server = FakeServer(
            mapOf(
                "session.update" to listOf(
                    "{\"type\":\"error\",\"error\":{\"code\":\"InvalidApiKey\",\"message\":\"Invalid API-key provided.\"}}",
                ),
            ),
        )
        val session = session(server, DashScopeModel.ASR)
        expect<DictationException.KeyRejected> { session.connect() }
        assertTrue(server.closed)
    }

    @Test
    fun missingSessionTimesOut() = runTest {
        val session = DashScopeSession(
            DashScopeEndpoint("wss://example.invalid", emptyMap()),
            DashScopeModel.ASR,
            DictationLanguage.RUSSIAN,
            { _, _ ->
                object : RealtimeSocket {
                    override fun send(text: String) = true
                    override fun close(code: Int, reason: String?) = Unit
                }
            },
            backgroundScope,
        )
        expect<DictationException.ConnectionClosed> { session.connect() }
    }

    private suspend inline fun <reified T : Throwable> expect(block: suspend () -> Unit) {
        try {
            block()
            fail("expected ${T::class.simpleName}")
        } catch (error: Throwable) {
            if (error !is T) throw error
        }
    }
}
