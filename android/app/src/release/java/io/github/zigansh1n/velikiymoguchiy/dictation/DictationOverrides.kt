package io.github.zigansh1n.velikiymoguchiy.dictation

/** A release build always talks to DashScope and records the microphone; see the debug source set. */
object DictationOverrides {
    val socketFactory: SocketFactory? = null
    val audioInput: AudioInputFactory? = null
}
