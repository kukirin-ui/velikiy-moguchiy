package io.github.zigansh1n.velikiymoguchiy.emulator

import androidx.test.ext.junit.runners.AndroidJUnit4
import io.github.zigansh1n.velikiymoguchiy.dictation.AudioRecorder
import io.github.zigansh1n.velikiymoguchiy.dictation.Pcm16
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CopyOnWriteArrayList

@RunWith(AndroidJUnit4::class)
class MicrophoneTest : EmulatorTest() {
    /** The real recorder on the emulator's virtual microphone; what it hears does not matter. */
    @Test
    fun recorderDeliversHundredMillisecondChunks() {
        val chunks = CopyOnWriteArrayList<Int>()
        val recorder = AudioRecorder({ chunks += it.size }, {})
        recorder.start()
        try {
            waitFor("three chunks from the microphone", timeoutMillis = 10_000) { chunks.size >= 3 }
        } finally {
            recorder.stop()
        }
        assertTrue("chunk sizes $chunks", chunks.dropLast(1).all { it == Pcm16.CHUNK_BYTES })
    }
}
