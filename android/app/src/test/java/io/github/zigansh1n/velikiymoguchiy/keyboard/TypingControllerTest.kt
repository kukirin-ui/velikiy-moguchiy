package io.github.zigansh1n.velikiymoguchiy.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class TypingControllerTest {
    private class FakeEditor(var text: String = "") : TextEditor {
        override fun textBeforeCursor() = text
        override fun deleteBefore(length: Int) {
            text = text.dropLast(length)
        }
        override fun insert(text: String) {
            this.text += text
        }
    }

    private var now = 0L
    private val editor = FakeEditor()
    private val typing = TypingController(editor) { now }
    private val options = TypingOptions(smartPunctuation = true, doubleSpacePeriod = true)
    private val engine = SuggestionEngine(
        LayoutLanguage.RUSSIAN,
        WordList(listOf("привет" to 100, "как" to 120, "дела" to 90), WordList.RUSSIAN_ALPHABET),
    )

    private fun type(text: String) = typing.type(text, LayoutLanguage.RUSSIAN, options) { engine.replacement(it, true) }

    @Test
    fun correctsOnSpaceAndUndoesWithBackspace() {
        "Превет".forEach { type(it.toString()) }
        type(" ")
        assertEquals("Привет ", editor.text)
        val undone = typing.revertLastReplacement()
        assertNotNull(undone)
        assertEquals("Превет", editor.text)
        engine.reject(undone!!.original)
        type(" ")
        assertEquals("Превет ", editor.text)
    }

    @Test
    fun revertOnlyRightAfterTheCorrection() {
        "превет".forEach { type(it.toString()) }
        type(" ")
        type("к")
        assertNull(typing.revertLastReplacement())
    }

    @Test
    fun doubleSpaceBecomesPeriod() {
        "как".forEach { type(it.toString()) }
        type(" ")
        now += 200
        type(" ")
        assertEquals("как. ", editor.text)
    }

    @Test
    fun slowDoubleSpaceStaysTwoSpaces() {
        "как".forEach { type(it.toString()) }
        type(" ")
        now += 1000
        type(" ")
        assertEquals("как  ", editor.text)
    }

    @Test
    fun smartQuotes() {
        type("\"")
        "как".forEach { type(it.toString()) }
        type("\"")
        assertEquals("«как»", editor.text)
    }

    @Test
    fun suggestionReplacesPartialWord() {
        editor.text = "Ну при"
        val kept = typing.applySuggestion(Suggestion("привет"))
        assertEquals("Ну привет ", editor.text)
        assertNull(kept)
        editor.text = "Ну превед"
        assertEquals("превед", typing.applySuggestion(Suggestion("превед", isTypedWord = true)))
    }
}
