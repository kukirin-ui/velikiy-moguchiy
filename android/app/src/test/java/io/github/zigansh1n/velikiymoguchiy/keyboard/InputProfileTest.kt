package io.github.zigansh1n.velikiymoguchiy.keyboard

import android.text.InputType
import android.view.inputmethod.EditorInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InputProfileTest {
    private val text = InputType.TYPE_CLASS_TEXT

    @Test
    fun plainSentenceField() {
        val profile = InputProfile.resolve(text or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES, EditorInfo.IME_ACTION_SEND)
        assertEquals(InputKind.STANDARD, profile.kind)
        assertEquals(CapitalizationMode.SENTENCES, profile.capitalization)
        assertEquals(ReturnKind.SEND, profile.returnKind)
        assertTrue(profile.allowsSuggestions)
        assertTrue(profile.smartPunctuation)
    }

    @Test
    fun passwordsGetNothing() {
        val profile = InputProfile.resolve(text or InputType.TYPE_TEXT_VARIATION_PASSWORD, 0)
        assertFalse(profile.allowsSuggestions)
        assertFalse(profile.smartPunctuation)
        assertTrue(profile.isSecure)
        assertEquals(CapitalizationMode.NONE, profile.capitalization)
    }

    @Test
    fun technicalFields() {
        assertEquals(InputKind.EMAIL, InputProfile.resolve(text or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS, 0).kind)
        assertEquals(InputKind.URL, InputProfile.resolve(text or InputType.TYPE_TEXT_VARIATION_URI, EditorInfo.IME_ACTION_DONE).kind)
        assertEquals(InputKind.WEB_SEARCH, InputProfile.resolve(text or InputType.TYPE_TEXT_VARIATION_URI, EditorInfo.IME_ACTION_GO).kind)
        assertFalse(InputProfile.resolve(text or InputType.TYPE_TEXT_VARIATION_URI, 0).allowsSuggestions)
    }

    @Test
    fun noSuggestionsFlagKeepsCapitals() {
        val profile = InputProfile.resolve(
            text or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS or InputType.TYPE_TEXT_FLAG_CAP_WORDS,
            0,
        )
        assertFalse(profile.allowsSuggestions)
        assertEquals(CapitalizationMode.WORDS, profile.capitalization)
    }

    @Test
    fun numbersAndPhones() {
        assertEquals(InputKind.NUMBER_PAD, InputProfile.resolve(InputType.TYPE_CLASS_NUMBER, 0).kind)
        assertEquals(
            InputKind.DECIMAL_PAD,
            InputProfile.resolve(InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL, 0).kind,
        )
        assertEquals(InputKind.PHONE_PAD, InputProfile.resolve(InputType.TYPE_CLASS_PHONE, 0).kind)
        assertTrue(InputProfile.resolve(InputType.TYPE_CLASS_DATETIME, 0).startsOnNumbers)
    }

    @Test
    fun noEnterActionMeansNewLine() {
        val profile = InputProfile.resolve(
            text or InputType.TYPE_TEXT_FLAG_MULTI_LINE,
            EditorInfo.IME_ACTION_SEND or EditorInfo.IME_FLAG_NO_ENTER_ACTION,
        )
        assertEquals(ReturnKind.NEWLINE, profile.returnKind)
        assertTrue(profile.multiLine)
    }
}
