package io.github.zigansh1n.velikiymoguchiy.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TextRulesTest {
    @Test
    fun sentenceStartsAfterTerminatorAndSpace() {
        assertTrue(Autocapitalization.startsSentence(null))
        assertTrue(Autocapitalization.startsSentence(""))
        assertTrue(Autocapitalization.startsSentence("Привет. "))
        assertTrue(Autocapitalization.startsSentence("Что? "))
        assertTrue(Autocapitalization.startsSentence("Он сказал: «Да.» "))
        assertTrue(Autocapitalization.startsSentence("строка\n"))
        assertFalse(Autocapitalization.startsSentence("Привет."))
        assertFalse(Autocapitalization.startsSentence("google.com"))
        assertFalse(Autocapitalization.startsSentence("привет "))
    }

    @Test
    fun abbreviationsAndInitialsDoNotCapitalize() {
        assertFalse(Autocapitalization.startsSentence("Яблоки, груши и т.д. "))
        assertFalse(Autocapitalization.startsSentence("ул. "))
        assertFalse(Autocapitalization.startsSentence("А. С. "))
        assertFalse(Autocapitalization.startsSentence("Talk to Mr. "))
        assertFalse(Autocapitalization.startsSentence("e.g. "))
    }

    @Test
    fun capitalizationModes() {
        assertEquals(Capitalization.SHIFTED, Autocapitalization.capitalization(CapitalizationMode.WORDS, "Анна "))
        assertEquals(Capitalization.LOWERCASE, Autocapitalization.capitalization(CapitalizationMode.WORDS, "Анна"))
        assertEquals(Capitalization.SHIFTED, Autocapitalization.capitalization(CapitalizationMode.CHARACTERS, "abc"))
        assertEquals(Capitalization.LOWERCASE, Autocapitalization.capitalization(CapitalizationMode.NONE, ""))
    }

    @Test
    fun quotesFollowLanguage() {
        val ru = SmartPunctuation.edit("\"", "Он сказал ", LayoutLanguage.RUSSIAN, true)
        assertEquals(PunctuationEdit(0, "«"), ru)
        assertEquals("»", SmartPunctuation.edit("\"", "«да", LayoutLanguage.RUSSIAN, true).insert)
        assertEquals("“", SmartPunctuation.edit("\"", "", LayoutLanguage.ENGLISH, true).insert)
        assertEquals("’", SmartPunctuation.edit("'", "don", LayoutLanguage.ENGLISH, true).insert)
        assertEquals("\"", SmartPunctuation.edit("\"", "", LayoutLanguage.ENGLISH, false).insert)
    }

    @Test
    fun dashesAndEllipsis() {
        assertEquals(PunctuationEdit(1, "—"), SmartPunctuation.edit("-", "слово -", LayoutLanguage.RUSSIAN, true))
        assertEquals(PunctuationEdit(0, "-"), SmartPunctuation.edit("-", "a--", LayoutLanguage.ENGLISH, true))
        assertEquals(PunctuationEdit(2, "…"), SmartPunctuation.edit(".", "ну..", LayoutLanguage.RUSSIAN, true))
    }

    @Test
    fun deleteRepeatSwitchesToWords() {
        val repeat = DeleteRepeat()
        assertEquals(420L, repeat.begin(0))
        repeat(10) { assertEquals(DeleteRepeat.Step.CHARACTER, repeat.tick(500L + it)!!.first) }
        assertEquals(DeleteRepeat.Step.WORD, repeat.tick(600)!!.first)
        repeat.end()
        assertEquals(null, repeat.tick(700))

        val held = DeleteRepeat()
        held.begin(0)
        assertEquals(DeleteRepeat.Step.WORD, held.tick(1300)!!.first)
    }

    @Test
    fun wordDeletionLengths() {
        assertEquals(6, DeleteRepeat.wordLength("Привет"))
        assertEquals(7, DeleteRepeat.wordLength("да привет "))
        assertEquals(1, DeleteRepeat.wordLength("да!"))
        assertEquals(1, DeleteRepeat.wordLength("строка\n"))
        assertEquals(1, DeleteRepeat.wordLength(""))
    }

    @Test
    fun lastCharacterKeepsEmojiWhole() {
        assertEquals(1, DeleteRepeat.lastCharacterLength("ab"))
        assertEquals(2, DeleteRepeat.lastCharacterLength("a😀"))
    }
}
