package io.github.zigansh1n.velikiymoguchiy.dictation

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer

/**
 * Android's own speech recognition, used when there is no DashScope key. On Android 12+ the
 * on-device recognizer comes first; when it lacks the language, the default service (often
 * online) takes over. Must be used on the main thread.
 */
class SystemSpeech(
    private val context: Context,
    private val language: DictationLanguage,
    private val listener: Listener,
) {
    interface Listener {
        fun onPartial(text: String)
        fun onFinal(text: String)
        fun onError(error: DictationException)
        fun onLevel(level: Float)
    }

    private var recognizer: SpeechRecognizer? = null
    private var onDevice = false
    private var finished = false

    fun start() {
        val canOnDevice = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        if (!canOnDevice && !SpeechRecognizer.isRecognitionAvailable(context)) throw DictationException.NoRecognizer()
        begin(onDevice = canOnDevice)
    }

    private fun begin(onDevice: Boolean) {
        this.onDevice = onDevice
        val recognizer = if (onDevice && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } else {
            SpeechRecognizer.createSpeechRecognizer(context)
        }
        this.recognizer = recognizer
        recognizer.setRecognitionListener(Callbacks())
        recognizer.startListening(
            Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE, language.localeTag)
                .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                .putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
                .putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 2500L)
                .putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName),
        )
    }

    /** Stop listening; the final text still arrives through [Listener.onFinal]. */
    fun stop() {
        recognizer?.stopListening()
    }

    fun cancel() {
        finished = true
        recognizer?.cancel()
        release()
    }

    private fun release() {
        recognizer?.destroy()
        recognizer = null
    }

    private inner class Callbacks : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) = Unit
        override fun onBeginningOfSpeech() = Unit
        override fun onBufferReceived(buffer: ByteArray?) = Unit
        override fun onEndOfSpeech() = Unit
        override fun onEvent(eventType: Int, params: Bundle?) = Unit

        override fun onRmsChanged(rmsdB: Float) {
            // The service reports roughly -2..10 dB.
            listener.onLevel(((rmsdB + 2f) / 12f).coerceIn(0f, 1f))
        }

        override fun onPartialResults(partialResults: Bundle?) {
            val text = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
            if (text.isNotBlank()) listener.onPartial(text)
        }

        override fun onResults(results: Bundle?) {
            if (finished) return
            finished = true
            val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
            release()
            if (text.isBlank()) listener.onError(DictationException.EmptyResult()) else listener.onFinal(text)
        }

        override fun onError(error: Int) {
            if (finished) return
            if (onDevice && error in LANGUAGE_ERRORS && SpeechRecognizer.isRecognitionAvailable(context)) {
                release()
                begin(onDevice = false)
                return
            }
            finished = true
            release()
            listener.onError(describe(error))
        }
    }

    companion object {
        /** ERROR_LANGUAGE_NOT_SUPPORTED and ERROR_LANGUAGE_UNAVAILABLE (API 31). */
        private val LANGUAGE_ERRORS = setOf(12, 13)

        fun describe(error: Int): DictationException = when (error) {
            SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> DictationException.EmptyResult()
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> DictationException.NoPermission()
            SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT, SpeechRecognizer.ERROR_SERVER ->
                DictationException.Service("Распознаванию речи Android нужна сеть. Добавьте ключ DashScope или подключитесь к интернету.")
            SpeechRecognizer.ERROR_AUDIO -> DictationException.Microphone("ошибка записи.")
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> DictationException.Service("Распознавание речи Android занято, попробуйте ещё раз.")
            12, 13 -> DictationException.Service("Распознавание речи Android не знает этот язык. Скачайте его в настройках голосового ввода.")
            else -> DictationException.Service("Распознавание речи Android не сработало (код $error).")
        }
    }
}
