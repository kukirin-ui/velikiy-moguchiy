package io.github.zigansh1n.velikiymoguchiy.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class WordListTest {
    private val small = WordList(
        listOf("привет" to 120, "приветствие" to 90, "при" to 150, "ещё" to 160, "Москва" to 130, "мат" to 0, "предмет" to 100),
        WordList.RUSSIAN_ALPHABET,
    )

    @Test
    fun lookupsIgnoreCaseAndYo() {
        assertTrue(small.isValidWord("Привет"))
        assertTrue(small.isValidWord("еще"))
        assertTrue(small.isValidWord("москва"))
        assertFalse(small.isValidWord("превет"))
        small.addWord("Превед")
        assertTrue(small.isValidWord("превед"))
    }

    @Test
    fun completionsByFrequencyAndHiddenWordsStayHidden() {
        assertEquals(listOf("привет", "приветствие"), small.completions("при"))
        assertEquals(listOf("ещё"), small.completions("еще"))
        assertTrue(small.completions("ма").isEmpty())
        assertTrue(small.isValidWord("мат"))
    }

    @Test
    fun guessesOneEditAway() {
        assertEquals(listOf("привет"), small.guesses("превет"))
        assertEquals(listOf("привет"), small.guesses("пирвет"))
        assertTrue(small.guesses("абвгд").isEmpty())
    }

    @Test
    fun shippedRussianListCorrectsCommonTypos() {
        val words = load("ru", LayoutLanguage.RUSSIAN) ?: return
        assertTrue(words.size > 100_000)
        assertTrue(words.isValidWord("здравствуйте"))
        assertTrue(words.isValidWord("еще"))
        val engine = SuggestionEngine(LayoutLanguage.RUSSIAN, words, replacements("ru"))
        assertEquals("привет", engine.replacement("Ну превет", autocorrectEnabled = true)?.replacement)
        assertEquals("сейчас", engine.replacement("щас", autocorrectEnabled = true)?.replacement)
        assertNull(engine.replacement("Ну привет", autocorrectEnabled = true))
        val cells = engine.suggestions("Здравс", autocorrectEnabled = true)
        assertTrue(cells.any { it.text.startsWith("Здравству") })
    }

    @Test
    fun shippedEnglishList() {
        val words = load("en", LayoutLanguage.ENGLISH) ?: return
        val engine = SuggestionEngine(LayoutLanguage.ENGLISH, words, replacements("en"))
        assertEquals("the", engine.replacement("teh", autocorrectEnabled = true)?.replacement)
        assertEquals("I'm", engine.replacement("im", autocorrectEnabled = true)?.replacement)
        assertNull(engine.replacement("the", autocorrectEnabled = true))
    }

    private fun asset(name: String) = File("src/main/assets/dictionary/$name").takeIf { it.exists() }

    private fun load(code: String, language: LayoutLanguage) = asset("$code.tsv")?.bufferedReader()?.use { WordList.read(it, language) }

    private fun replacements(code: String) =
        TextReplacementTable(asset("$code.replacements.tsv")!!.bufferedReader().use { WordList.readReplacements(it) })
}
