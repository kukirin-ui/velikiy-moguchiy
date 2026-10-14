package io.github.zigansh1n.velikiymoguchiy.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SuggestionRulesTest {
    @Test
    fun casePreservation() {
        assertEquals("Help", CasePreservation.apply("help", "Hel"))
        assertEquals("HELP", CasePreservation.apply("help", "HELL"))
        assertEquals("help", CasePreservation.apply("help", "hel"))
        assertEquals("Москва", CasePreservation.apply("Москва", "мос"))
    }

    @Test
    fun editDistanceCountsSwapsOnce() {
        assertEquals(1, EditDistance.between("привет", "пирвет"))
        assertEquals(1, EditDistance.between("cat", "cart"))
        assertEquals(3, EditDistance.between("kitten", "sitting"))
        assertEquals(0, EditDistance.between("Да", "да"))
    }

    @Test
    fun partialWord() {
        assertEquals("прив", WordBoundary.partialWord("Ну прив"))
        assertEquals("", WordBoundary.partialWord("Ну "))
        assertEquals("", WordBoundary.partialWord("mail@exa"))
        assertEquals("", WordBoundary.partialWord("site.co"))
        assertEquals("don't", WordBoundary.partialWord("I don't"))
        assertEquals("quote", WordBoundary.partialWord("say 'quote"))
        assertEquals("", WordBoundary.partialWord("abc123"))
    }

    @Test
    fun composerPutsTypedWordFirst() {
        val cells = SuggestionComposer.compose(
            typed = "Превет",
            isValidWord = false,
            guesses = listOf("привет", "предмет"),
            completions = emptyList(),
            lexiconMatches = emptyList(),
            autocorrection = "Привет",
        )
        assertEquals(listOf("“Превет”", "Привет", "Предмет"), cells.map { it.display })
        assertTrue(cells[1].isAutocorrection)
        assertTrue(cells[0].isTypedWord)
    }

    @Test
    fun validWordLeadsWithCompletions() {
        val cells = SuggestionComposer.compose("при", true, listOf("про"), listOf("привет", "при", "прийти"), emptyList())
        assertEquals(listOf("при", "привет", "прийти"), cells.map { it.text })
    }

    @Test
    fun autocorrectRules() {
        assertEquals("Привет", AutocorrectRules.correction("Превет", listOf("привет"), false, emptySet()))
        assertNull(AutocorrectRules.correction("пр", listOf("про"), false, emptySet()))
        assertNull(AutocorrectRules.correction("iPhon", listOf("iphone"), false, emptySet()))
        assertNull(AutocorrectRules.correction("превет", listOf("привет"), false, setOf("превет")))
        assertNull(AutocorrectRules.correction("превед", listOf("привет"), false, emptySet()))
        assertNull(AutocorrectRules.correction("дом", listOf("дым"), true, emptySet()))
    }

    @Test
    fun replacementTable() {
        val table = TextReplacementTable(listOf("спб" to "Санкт-Петербург", "x" to "x", "омв" to "on my way"))
        assertEquals("Санкт-Петербург", table.replacement("СПБ"))
        assertNull(table.replacement("x"))
        assertEquals(listOf("on my way"), table.documentTexts("ом"))
    }

    @Test
    fun sentenceStarters() {
        assertEquals(listOf("Я", "Ну"), SentenceStarters.suggestions(LayoutLanguage.RUSSIAN, "").map { it.text })
        assertEquals(listOf("I", "The", "I'm"), SentenceStarters.suggestions(LayoutLanguage.ENGLISH, "Done. ").map { it.text })
        assertTrue(SentenceStarters.suggestions(LayoutLanguage.RUSSIAN, "и ").isEmpty())
    }
}
