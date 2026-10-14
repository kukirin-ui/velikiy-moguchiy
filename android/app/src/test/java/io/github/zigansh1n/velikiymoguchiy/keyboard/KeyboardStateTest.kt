package io.github.zigansh1n.velikiymoguchiy.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyboardStateTest {
    private fun texts(row: LayoutRow) = row.keys.mapNotNull { (it.action as? KeyAction.Text)?.value }

    @Test
    fun russianLettersMatchApple() {
        val rows = KeyboardState(LayoutLanguage.RUSSIAN).layout(InputKind.STANDARD)
        assertEquals("йцукенгшщзх".map(Char::toString), texts(rows[0]))
        assertEquals("фывапролджэ".map(Char::toString), texts(rows[1]))
        assertEquals(11, rows[2].keys.size)
        assertEquals(KeyAction.Shift, rows[2].keys.first().action)
        assertEquals(KeyAction.Backspace, rows[2].keys.last().action)
        // Eleven equal keys: shift and delete are as wide as a letter.
        assertEquals(null, rows[2].keys.first().fixedPoints)
    }

    @Test
    fun englishShiftAndDeleteAreWider() {
        val rows = KeyboardState(LayoutLanguage.ENGLISH).layout(InputKind.STANDARD)
        assertEquals(10, rows[0].keys.size)
        assertEquals(KeyMetrics.SIDE_KEY, rows[2].keys.first().fixedPoints)
    }

    @Test
    fun bottomRowHasLanguageAndMicrophone() {
        val bottom = KeyboardState(LayoutLanguage.RUSSIAN).layout(InputKind.STANDARD).last()
        assertEquals(
            listOf(KeyAction.Page, KeyAction.Language, KeyAction.Microphone, KeyAction.Space, KeyAction.Return),
            bottom.keys.map { it.action },
        )
        val email = KeyboardState(LayoutLanguage.ENGLISH).layout(InputKind.EMAIL).last()
        assertTrue(email.keys.any { it.action == KeyAction.Text("@") })
        val url = KeyboardState(LayoutLanguage.ENGLISH).layout(InputKind.URL).last()
        assertTrue(url.keys.none { it.action == KeyAction.Space })
    }

    @Test
    fun shiftOnceThenDoubleTapLocks() {
        val state = KeyboardState(LayoutLanguage.RUSSIAN)
        state.tapShift(0)
        assertEquals(Capitalization.SHIFTED, state.capitalization)
        assertEquals("Й", texts(state.layout(InputKind.STANDARD)[0]).first())
        state.consumeText()
        assertEquals(Capitalization.LOWERCASE, state.capitalization)

        state.tapShift(1000)
        state.tapShift(1200)
        assertEquals(Capitalization.CAPS_LOCK, state.capitalization)
        state.consumeText()
        assertEquals(Capitalization.CAPS_LOCK, state.capitalization)
        state.tapShift(5000)
        assertEquals(Capitalization.LOWERCASE, state.capitalization)
    }

    @Test
    fun slowSecondTapOnlyToggles() {
        val state = KeyboardState(LayoutLanguage.ENGLISH)
        state.tapShift(0)
        state.tapShift(KeyboardState.DOUBLE_TAP_MILLIS + 1)
        assertEquals(Capitalization.LOWERCASE, state.capitalization)
    }

    @Test
    fun automaticCapitalDoesNotBreakCapsLock() {
        val state = KeyboardState(LayoutLanguage.ENGLISH)
        state.tapShift(0)
        state.tapShift(100)
        state.applyAutomaticCapitalization(Capitalization.LOWERCASE)
        assertEquals(Capitalization.CAPS_LOCK, state.capitalization)
    }

    @Test
    fun pagesCycle() {
        val state = KeyboardState(LayoutLanguage.RUSSIAN)
        state.tapPage()
        assertEquals(KeyboardPage.NUMBERS, state.page)
        assertTrue("₽" in texts(state.layout(InputKind.STANDARD)[1]))
        state.tapShift(0)
        assertEquals(KeyboardPage.SYMBOLS, state.page)
        state.tapPage()
        assertEquals(KeyboardPage.LETTERS, state.page)
    }

    @Test
    fun alternatesFollowShiftForLettersOnly() {
        val state = KeyboardState(LayoutLanguage.RUSSIAN)
        assertEquals(listOf("е", "ё"), state.alternates("е"))
        state.tapShift(0)
        assertEquals(listOf("Е", "Ё"), state.alternates("Е"))
        assertEquals(listOf("\"", "«", "»", "„", "“", "”"), state.alternates("\""))
        assertEquals(emptyList<String>(), state.alternates("ж"))
    }

    @Test
    fun phonePadHasPlusAndLetters() {
        val rows = KeyboardState(LayoutLanguage.RUSSIAN).layout(InputKind.PHONE_PAD)
        assertEquals(4, rows.size)
        assertEquals("ABC", rows[0].keys[1].subtitle)
        assertEquals(KeyAction.Text("+"), rows[0].keys.last().action)
        assertEquals(KeyAction.Return, rows[3].keys.last().action)
    }
}
