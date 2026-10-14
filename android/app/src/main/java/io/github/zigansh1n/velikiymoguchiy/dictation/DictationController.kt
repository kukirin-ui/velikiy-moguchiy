package io.github.zigansh1n.velikiymoguchiy.dictation

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import io.github.zigansh1n.velikiymoguchiy.settings.AppSettings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

enum class DictationProvider { DASHSCOPE, SYSTEM }

sealed interface DictationState {
    data object Idle : DictationState
    data class Listening(val provider: DictationProvider, val preview: String = "", val level: Float = 0f) : DictationState
    data class Transcribing(val preview: String) : DictationState
    data class Failed(val message: String, val needsSettings: Boolean = false) : DictationState
}

/**
 * The microphone key: DashScope with the user's key, or Android's recognizer without one.
 * Lives on the main thread; [onResult] receives the recognized text there.
 */
class DictationController(
    private val context: Context,
    private val settings: AppSettings,
    private val onResult: (String) -> Unit,
) {
    private val main = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val io = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val socketFactory by lazy { OkHttpSocketFactory() }

    private val _state = MutableStateFlow<DictationState>(DictationState.Idle)
    val state: StateFlow<DictationState> = _state

    private var recorder: AudioRecorder? = null
    private var session: DashScopeSession? = null
    private var connectJob: Job? = null
    private var limitJob: Job? = null
    private var clearJob: Job? = null
    private var systemSpeech: SystemSpeech? = null

    val isActive: Boolean get() = _state.value is DictationState.Listening || _state.value is DictationState.Transcribing

    fun hasMicrophonePermission() =
        ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    /** The microphone key: start, or finish a running dictation. */
    fun toggle(language: DictationLanguage) {
        when (_state.value) {
            is DictationState.Listening -> stop()
            is DictationState.Transcribing -> Unit
            DictationState.Idle, is DictationState.Failed -> start(language)
        }
    }

    fun start(language: DictationLanguage) {
        clearJob?.cancel()
        if (!hasMicrophonePermission()) {
            fail(DictationException.NoPermission(), needsSettings = true)
            return
        }
        val key = settings.apiKey()
        try {
            if (DashScopeProtocol.isUsableKey(key)) startDashScope(key!!, language) else startSystem(language)
        } catch (error: DictationException) {
            cleanUp()
            fail(error, needsSettings = error is DictationException.NoPermission)
            return
        }
        limitJob = main.launch {
            delay(MAX_DICTATION_MILLIS)
            stop()
        }
    }

    private fun startDashScope(key: String, language: DictationLanguage) {
        val endpoint = DashScopeProtocol.endpoint(key, settings.model, settings.region)
        val session = DashScopeSession(endpoint, settings.model, language, socketFactory, io) { preview ->
            _state.update { if (it is DictationState.Listening) it.copy(preview = preview) else it }
        }
        this.session = session
        val recorder = AudioRecorder(session::offerAudio) { level ->
            _state.update { if (it is DictationState.Listening) it.copy(level = level) else it }
        }
        this.recorder = recorder
        // Recording starts at once; chunks wait in the session until the socket is ready.
        @Suppress("MissingPermission")
        recorder.start()
        _state.value = DictationState.Listening(DictationProvider.DASHSCOPE)
        connectJob = io.launch {
            try {
                session.connect()
            } catch (error: DictationException) {
                main.launch {
                    if (isCurrent(session)) {
                        cleanUp()
                        fail(error, needsSettings = error is DictationException.KeyRejected)
                    }
                }
            }
        }
    }

    private fun startSystem(language: DictationLanguage) {
        val speech = SystemSpeech(context, language, object : SystemSpeech.Listener {
            override fun onPartial(text: String) =
                _state.update {
                    when (it) {
                        is DictationState.Listening -> it.copy(preview = text)
                        is DictationState.Transcribing -> DictationState.Transcribing(text)
                        else -> it
                    }
                }

            override fun onLevel(level: Float) =
                _state.update { if (it is DictationState.Listening) it.copy(level = level) else it }

            override fun onFinal(text: String) {
                cleanUp()
                _state.value = DictationState.Idle
                onResult(TranscriptFormatter.cleaned(text))
            }

            override fun onError(error: DictationException) {
                cleanUp()
                fail(error, needsSettings = error is DictationException.NoPermission)
            }
        })
        systemSpeech = speech
        speech.start()
        _state.value = DictationState.Listening(DictationProvider.SYSTEM)
    }

    /** Finish: the recognized text goes to [onResult]. */
    fun stop() {
        val current = _state.value as? DictationState.Listening ?: return
        limitJob?.cancel()
        _state.value = DictationState.Transcribing(current.preview)
        systemSpeech?.let {
            it.stop()
            return
        }
        val session = session ?: return
        val recorder = recorder
        val connecting = connectJob
        io.launch {
            recorder?.stop()
            try {
                connecting?.join()
                val text = session.finish()
                main.launch {
                    if (!isCurrent(session)) return@launch
                    cleanUp()
                    _state.value = DictationState.Idle
                    onResult(text)
                }
            } catch (error: DictationException) {
                main.launch {
                    if (!isCurrent(session)) return@launch
                    cleanUp()
                    fail(error, needsSettings = error is DictationException.KeyRejected)
                }
            }
        }
    }

    fun cancel() {
        session?.cancel()
        systemSpeech?.cancel()
        val recorder = recorder
        cleanUp()
        if (recorder != null) io.launch { recorder.stop() }
        _state.value = DictationState.Idle
    }

    fun dismissError() {
        if (_state.value is DictationState.Failed) _state.value = DictationState.Idle
    }

    fun destroy() {
        cancel()
        main.cancel()
        io.cancel()
    }

    private fun isCurrent(candidate: DashScopeSession) = session === candidate

    private fun cleanUp() {
        limitJob?.cancel()
        connectJob = null
        session = null
        recorder = null
        systemSpeech = null
    }

    private fun fail(error: DictationException, needsSettings: Boolean) {
        _state.value = DictationState.Failed(error.message.orEmpty(), needsSettings)
        clearJob?.cancel()
        clearJob = main.launch {
            delay(if (needsSettings) 8_000 else 4_000)
            dismissError()
        }
    }

    private companion object {
        const val MAX_DICTATION_MILLIS = 5 * 60_000L
    }
}
