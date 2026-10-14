package io.github.zigansh1n.velikiymoguchiy.dictation

/**
 * Debug builds only: the emulator tests (`app/src/androidTest`) put a scripted DashScope server and
 * microphone here, so a dictation round runs without a key, a network or a voice. The release
 * source set has the same object with both fixed to null.
 */
object DictationOverrides {
    @Volatile var socketFactory: SocketFactory? = null
    @Volatile var audioInput: AudioInputFactory? = null
}
