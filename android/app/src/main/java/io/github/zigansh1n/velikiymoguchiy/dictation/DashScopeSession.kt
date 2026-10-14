package io.github.zigansh1n.velikiymoguchiy.dictation

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.TimeUnit

/** Errors shown to the user as they are, so the messages are Russian sentences. */
sealed class DictationException(message: String) : Exception(message) {
    class MissingKey : DictationException("Добавьте ключ DashScope в настройках «Великого & Могучего».")
    class KeyRejected(detail: String) : DictationException("DashScope не принял ключ: $detail")
    class InvalidMessage : DictationException("DashScope вернул ответ, который не удалось прочитать.")
    class ConnectionClosed(reason: String) :
        DictationException(if (reason.isEmpty()) "Соединение с DashScope закрылось до конца распознавания." else "Соединение с DashScope прервано: $reason")
    class Service(message: String) : DictationException(message)
    class EmptyResult : DictationException("Речь не распознана.")
    class NoRecognizer : DictationException("На телефоне нет распознавания речи. Добавьте ключ DashScope в настройках.")
    class NoPermission : DictationException("Нет доступа к микрофону: разрешите его в настройках клавиатуры.")
    class Microphone(detail: String) : DictationException("Микрофон недоступен: $detail")
}

sealed interface SocketEvent {
    data class Text(val text: String) : SocketEvent
    data class Closed(val code: Int, val reason: String) : SocketEvent
    data class Failure(val message: String, val httpCode: Int?) : SocketEvent
}

/** Session-internal steps queued behind the server events received so far. */
private data object FinishRequested : SocketEvent
private data object GraceElapsed : SocketEvent

/** The slice of a WebSocket the session uses, so tests can run it without a network. */
interface RealtimeSocket {
    fun send(text: String): Boolean
    fun close(code: Int, reason: String?)
}

fun interface SocketFactory {
    fun open(endpoint: DashScopeEndpoint, listener: (SocketEvent) -> Unit): RealtimeSocket
}

class OkHttpSocketFactory(
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .pingInterval(20, TimeUnit.SECONDS)
        .build(),
) : SocketFactory {
    override fun open(endpoint: DashScopeEndpoint, listener: (SocketEvent) -> Unit): RealtimeSocket {
        val request = Request.Builder().url(endpoint.url).apply {
            endpoint.headers.forEach { (name, value) -> header(name, value) }
        }.build()
        val socket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) = listener(SocketEvent.Text(text))

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(code, null)
                listener(SocketEvent.Closed(code, reason))
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = listener(SocketEvent.Closed(code, reason))

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) =
                listener(SocketEvent.Failure(t.message.orEmpty(), response?.code))
        })
        return object : RealtimeSocket {
            override fun send(text: String) = socket.send(text)
            override fun close(code: Int, reason: String?) {
                if (!socket.close(code, reason)) socket.cancel()
            }
        }
    }
}

/**
 * One DashScope realtime dictation: [connect], feed 100 ms PCM chunks with [offerAudio] while the
 * user speaks, then [finish] commits the audio and returns the text. Audio offered before the
 * session is configured is queued and sent in order once it is.
 */
class DashScopeSession(
    private val endpoint: DashScopeEndpoint,
    private val model: DashScopeModel,
    private val language: DictationLanguage,
    private val socketFactory: SocketFactory,
    private val scope: CoroutineScope,
    private val timeouts: Timeouts = Timeouts(),
    private val onPreview: (String) -> Unit = {},
) {
    data class Timeouts(
        val setupMillis: Long = 10_000,
        val drainMillis: Long = 10_000,
        val responseMillis: Long = 40_000,
        /** After `response.text.done` the service normally sends `response.done` at once. */
        val doneGraceMillis: Long = 1_500,
    )

    private val events = Channel<SocketEvent>(Channel.UNLIMITED)
    private val audio = Channel<ByteArray>(MAX_QUEUED_CHUNKS)
    private val created = CompletableDeferred<Unit>()
    private val updated = CompletableDeferred<Unit>()
    private val result = CompletableDeferred<String>()

    private var socket: RealtimeSocket? = null
    private var eventJob: Job? = null
    private var audioJob: Job? = null
    @Volatile private var failure: DictationException? = null
    @Volatile private var closed = false

    // Written by the audio job only; read after it has been joined.
    private var sentBytes = 0
    private var sawSpeech = false

    // Event job state.
    private var heardSpeech = false
    private var finishRequested = false
    private val completedTranscripts = mutableListOf<String>()
    private val streamed = StringBuilder()
    private var responseText: String? = null

    suspend fun connect() {
        val socket = socketFactory.open(endpoint) { events.trySend(it) }
        this.socket = socket
        eventJob = scope.launch { for (event in events) handle(event) }
        audioJob = scope.launch {
            try {
                updated.await()
            } catch (_: DictationException) {
                return@launch
            }
            for (chunk in audio) {
                if (closed) break
                if (!socket.send(DashScopeProtocol.audioAppend(chunk))) {
                    fail(DictationException.ConnectionClosed("поток звука прервался."))
                    break
                }
                sentBytes += chunk.size
                if (Pcm16.containsLikelySpeech(chunk)) sawSpeech = true
            }
        }
        try {
            await(created, timeouts.setupMillis, "DashScope не создал сеанс.")
            if (!socket.send(DashScopeProtocol.sessionUpdate(model, language))) {
                throw DictationException.ConnectionClosed("")
            }
            await(updated, timeouts.setupMillis, "DashScope не подтвердил настройки сеанса.")
        } catch (error: DictationException) {
            fail(error)
            close()
            throw failure ?: error
        }
    }

    /** Called from the recording thread; never blocks. */
    fun offerAudio(chunk: ByteArray) {
        if (chunk.isEmpty() || closed) return
        if (!audio.trySend(chunk).isSuccess) {
            fail(DictationException.Service("Звук не успевает уходить в сеть: проверьте подключение."))
        }
    }

    suspend fun finish(): String {
        audio.close()
        try {
            audioJob?.let { job -> withTimeout(timeouts.drainMillis) { job.join() } }
        } catch (_: TimeoutCancellationException) {
            fail(DictationException.ConnectionClosed("звук не успел отправиться."))
        }
        failure?.let { close(); throw it }
        val socket = socket ?: throw DictationException.ConnectionClosed("")
        // Committing an empty or silent buffer makes the model invent text.
        if (sentBytes < Pcm16.CHUNK_BYTES || !sawSpeech) {
            close()
            throw DictationException.EmptyResult()
        }
        events.trySend(FinishRequested)
        val sent = socket.send(DashScopeProtocol.commit()) &&
            socket.send(if (model.isOmni) DashScopeProtocol.responseCreate() else DashScopeProtocol.sessionFinish())
        if (!sent) fail(DictationException.ConnectionClosed(""))
        try {
            val text = await(result, timeouts.responseMillis, "DashScope не вернул итоговый текст.")
            if (text.isEmpty()) throw DictationException.EmptyResult()
            return text
        } finally {
            close()
        }
    }

    fun cancel() {
        fail(DictationException.ConnectionClosed("отменено."))
        close()
    }

    private fun close() {
        if (closed) return
        closed = true
        audio.close()
        socket?.close(1000, null)
        eventJob?.cancel()
        audioJob?.cancel()
    }

    private fun handle(event: SocketEvent) {
        when (event) {
            FinishRequested -> finishRequested = true
            GraceElapsed -> completeOmni(final = false)
            is SocketEvent.Text -> {
                val parsed = try {
                    DashScopeProtocol.parse(event.text)
                } catch (error: DictationException) {
                    fail(error)
                    return
                }
                handle(parsed)
            }
            is SocketEvent.Closed -> when {
                result.isCompleted -> Unit
                model.isOmni && responseText != null -> completeOmni(final = true)
                !model.isOmni && completedTranscripts.isNotEmpty() -> completeAsr()
                else -> fail(DictationException.ConnectionClosed(event.reason))
            }
            is SocketEvent.Failure -> fail(
                if (event.httpCode == 401 || event.httpCode == 403) {
                    DictationException.KeyRejected("сервер ответил ${event.httpCode}.")
                } else {
                    DictationException.ConnectionClosed(event.message.ifEmpty { "сетевое соединение прервано." })
                },
            )
        }
    }

    private fun handle(event: DashScopeProtocol.ServerEvent) {
        when (event) {
            DashScopeProtocol.ServerEvent.SessionCreated -> created.complete(Unit)
            DashScopeProtocol.ServerEvent.SessionUpdated -> updated.complete(Unit)
            is DashScopeProtocol.ServerEvent.Preview -> {
                noteTranscript(event.text)
                if (!TranscriptFormatter.isSilent(event.text)) onPreview(event.text)
            }
            is DashScopeProtocol.ServerEvent.Completed -> {
                noteTranscript(event.transcript)
                if (event.transcript.isNotBlank()) completedTranscripts += event.transcript
                if (!model.isOmni && finishRequested) completeAsr()
            }
            is DashScopeProtocol.ServerEvent.ResponseDelta -> streamed.append(event.delta)
            is DashScopeProtocol.ServerEvent.ResponseDone -> {
                responseText = event.text
                scope.launch {
                    delay(timeouts.doneGraceMillis)
                    events.trySend(GraceElapsed)
                }
            }
            DashScopeProtocol.ServerEvent.ResponseFinished -> completeOmni(final = true)
            DashScopeProtocol.ServerEvent.SessionFinished -> completeAsr()
            is DashScopeProtocol.ServerEvent.Error -> fail(
                if (DashScopeProtocol.isKeyProblem(event.code, event.message)) {
                    DictationException.KeyRejected(event.message)
                } else {
                    DictationException.Service(event.message)
                },
            )
            DashScopeProtocol.ServerEvent.Other -> Unit
        }
    }

    private fun noteTranscript(text: String) {
        if (!TranscriptFormatter.isSilent(text)) heardSpeech = true
    }

    /**
     * With turn detection off Omni answers every recording, also silence ("Не расслышал…"), so its
     * reply counts only when the input transcription heard speech.
     */
    private fun completeOmni(final: Boolean) {
        if (result.isCompleted) return
        if (!heardSpeech) {
            if (final) result.complete("")
            return
        }
        val text = listOf(responseText.orEmpty(), streamed.toString(), completedTranscripts.joinToString(" "))
            .map(TranscriptFormatter::cleaned)
            .firstOrNull { it.isNotEmpty() }
            .orEmpty()
        result.complete(text)
    }

    private fun completeAsr() {
        if (result.isCompleted) return
        result.complete(TranscriptFormatter.cleaned(completedTranscripts.joinToString(" ")))
    }

    private fun fail(error: DictationException) {
        if (failure == null) failure = error
        val reported = failure ?: error
        created.completeExceptionally(reported)
        updated.completeExceptionally(reported)
        result.completeExceptionally(reported)
    }

    private suspend fun <T> await(deferred: Deferred<T>, millis: Long, timeoutMessage: String): T = try {
        withTimeout(millis) { deferred.await() }
    } catch (_: TimeoutCancellationException) {
        throw DictationException.ConnectionClosed(timeoutMessage)
    }

    private companion object {
        /** About a minute of 100 ms chunks waiting for the network. */
        const val MAX_QUEUED_CHUNKS = 600
    }
}
