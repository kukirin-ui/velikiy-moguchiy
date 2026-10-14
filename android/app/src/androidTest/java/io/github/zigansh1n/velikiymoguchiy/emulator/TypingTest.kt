package io.github.zigansh1n.velikiymoguchiy.emulator

import androidx.test.ext.junit.runners.AndroidJUnit4
import io.github.zigansh1n.velikiymoguchiy.keyboard.KeyAction
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TypingTest : EmulatorTest() {
    @Test
    fun lettersSpaceAndBackspaceReachTheField() {
        keyboard.show()
        keyboard.type("приветы")
        keyboard.press(KeyAction.Backspace)
        keyboard.type(" мир")
        // The field asks for sentence capitals, so the keyboard starts on Shift.
        assertEquals("Привет мир", keyboard.fieldText())
    }
}
