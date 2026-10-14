package io.github.zigansh1n.velikiymoguchiy.emulator

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Until
import io.github.zigansh1n.velikiymoguchiy.dictation.DashScopeModel
import io.github.zigansh1n.velikiymoguchiy.dictation.DictationOverrides
import io.github.zigansh1n.velikiymoguchiy.keyboard.KeyAction
import io.github.zigansh1n.velikiymoguchiy.settings.AppSettings
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** The microphone key end to end, with a scripted DashScope and microphone in place of the network and a voice. */
@RunWith(AndroidJUnit4::class)
class DictationTest : EmulatorTest() {
    private val settings = AppSettings(targetContext)
    private val server = ScriptedDashScope(PHRASE)

    @Before
    fun useScriptedService() {
        DictationOverrides.socketFactory = server
        DictationOverrides.audioInput = { onChunk, onLevel -> ScriptedMicrophone(onChunk, onLevel) }
        // Any well-formed key starts the DashScope path; it only reaches the scripted server.
        settings.setApiKey(PLACEHOLDER_KEY)
        settings.model = DashScopeModel.ASR
    }

    @After
    fun restore() {
        DictationOverrides.socketFactory = null
        DictationOverrides.audioInput = null
        settings.setApiKey(null)
    }

    @Test
    fun dictationRoundCommitsTheRecognizedPhrase() {
        keyboard.show()
        keyboard.tap(KeyAction.Microphone)
        val device = keyboard.device
        assertTrue("«Слушаю…» strip", device.wait(Until.hasObject(By.text("Слушаю…")), 10_000))
        waitFor("audio at the scripted server", timeoutMillis = 10_000) { server.audioChunks.get() >= 3 }

        val done = device.findObject(By.text("Готово"))
        assertNotNull("«Готово» button", done)
        done.click()

        waitFor("the phrase in the field", timeoutMillis = 15_000) { keyboard.fieldText() == PHRASE }
        assertEquals(listOf("session.update", "input_audio_buffer.commit", "session.finish"), server.received.toList())
        assertEquals("Bearer $PLACEHOLDER_KEY", server.endpoint?.headers?.get("Authorization"))
        assertTrue("socket closed", server.closed)
    }

    private companion object {
        const val PHRASE = "Проверка диктовки на эмуляторе."
        const val PLACEHOLDER_KEY = "emulator-test-placeholder"
    }
}
