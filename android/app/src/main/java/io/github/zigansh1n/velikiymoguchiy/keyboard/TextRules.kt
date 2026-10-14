package io.github.zigansh1n.velikiymoguchiy.keyboard

/**
 * When the next letter should be a capital. Like Apple, a sentence end counts only once a space
 * (or a new line) follows it, so "google.com", "3.14" and "e.g" stay lowercase, and a known
 * abbreviation ("т.е. ", "Mr. ") does too.
 */
object Autocapitalization {
    private val terminators = setOf('.', '!', '?', '…')
    private val closers = setOf('"', '”', '»', '’', '\'', ')', ']', '}')

    private val abbreviations = setOf(
        "mr", "mrs", "ms", "dr", "prof", "vs", "e.g", "i.e", "approx", "fig", "inc", "ltd", "jr", "sr",
        "т.е", "т.д", "т.п", "т.к", "т.н", "т.ч", "и т.д", "и т.п", "г", "гг", "ул", "им", "др", "пр",
        "см", "рис", "стр", "тыс", "млн", "млрд", "руб", "коп", "англ", "напр", "проф", "акад", "доц",
    )

    fun capitalization(mode: CapitalizationMode, contextBefore: String?): Capitalization = when (mode) {
        CapitalizationMode.NONE -> Capitalization.LOWERCASE
        CapitalizationMode.CHARACTERS -> Capitalization.SHIFTED
        CapitalizationMode.WORDS -> if (startsWord(contextBefore)) Capitalization.SHIFTED else Capitalization.LOWERCASE
        CapitalizationMode.SENTENCES -> if (startsSentence(contextBefore)) Capitalization.SHIFTED else Capitalization.LOWERCASE
    }

    fun startsWord(context: String?): Boolean {
        val last = context?.lastOrNull() ?: return true
        return last.isWhitespace()
    }

    fun startsSentence(context: String?): Boolean {
        if (context.isNullOrEmpty()) return true
        val last = context.last()
        if (last == '\n') return true
        if (context.all { it.isWhitespace() }) return true
        if (!last.isWhitespace()) return false

        var index = context.length
        while (index > 0 && context[index - 1].isWhitespace()) index--
        while (index > 0 && context[index - 1] in closers) index--
        if (index == 0) return false
        val terminator = context[index - 1]
        if (terminator !in terminators) return false
        if (terminator == '.' && endsWithAbbreviation(context.substring(0, index - 1))) return false
        return true
    }

    /** "т.е", "Mr", an initial ("А" as in "А. С. Пушкин") or a dotted chain of single letters. */
    fun endsWithAbbreviation(text: String): Boolean {
        val start = text.indexOfLast { it.isWhitespace() || it in "([{«“\"" } + 1
        val token = text.substring(start)
        if (token.isEmpty()) return false
        val lowered = token.lowercase()
        if (lowered in abbreviations) return true
        val parts = lowered.split('.')
        if (parts.size >= 2 && parts.all { it.length == 1 && it[0].isLetter() }) return true
        return token.length == 1 && token[0].isLetter() && token[0].isUpperCase()
    }
}

/** What to do instead of inserting the typed character as is. */
data class PunctuationEdit(val deleteBefore: Int, val insert: String)

/**
 * Typographic replacements like iOS Smart Punctuation: « » in Russian and “ ” in English,
 * ’ for the apostrophe, `--` becomes an em dash, `...` an ellipsis.
 */
object SmartPunctuation {
    private val openingContext = setOf('(', '[', '{', '«', '“', '‘', '—', '–', '-', '/', '<')

    fun edit(typing: String, contextBefore: String?, language: LayoutLanguage, enabled: Boolean): PunctuationEdit {
        val plain = PunctuationEdit(0, typing)
        if (!enabled) return plain
        val before = contextBefore.orEmpty()
        return when (typing) {
            "\"" -> {
                val opens = opensQuote(before.lastOrNull())
                val quote = when (language) {
                    LayoutLanguage.RUSSIAN -> if (opens) "«" else "»"
                    LayoutLanguage.ENGLISH -> if (opens) "“" else "”"
                }
                PunctuationEdit(0, quote)
            }
            "'" -> PunctuationEdit(0, if (opensQuote(before.lastOrNull())) "‘" else "’")
            "-" -> if (before.endsWith("-") && !before.endsWith("--")) PunctuationEdit(1, "—") else plain
            "." -> if (before.endsWith("..") && !before.endsWith("...")) PunctuationEdit(2, "…") else plain
            else -> plain
        }
    }

    /** A quote opens at the start, after whitespace, an opening bracket or a dash. */
    fun opensQuote(previous: Char?): Boolean = previous == null || previous.isWhitespace() || previous in openingContext
}

/** Holding ⌫ deletes characters after a short delay and, like Apple's keyboard, words later. */
class DeleteRepeat(
    private val initialDelayMillis: Long = 420,
    private val characterIntervalMillis: Long = 72,
    private val wordIntervalMillis: Long = 100,
    private val repeatsBeforeWords: Int = 10,
    private val holdBeforeWordsMillis: Long = 1200,
) {
    enum class Step { CHARACTER, WORD }

    private var startedAt: Long? = null
    private var characterRepeats = 0
    private var wordRepeats = 0

    val isHolding: Boolean get() = startedAt != null

    /** The finger went down; returns the delay before the first repeat. */
    fun begin(atMillis: Long): Long {
        startedAt = atMillis
        characterRepeats = 0
        wordRepeats = 0
        return initialDelayMillis
    }

    fun end() {
        startedAt = null
    }

    /** One timer tick: what to delete and how long to wait for the next tick. */
    fun tick(atMillis: Long): Pair<Step, Long>? {
        val started = startedAt ?: return null
        val wordsActive = wordRepeats > 0 || characterRepeats >= repeatsBeforeWords ||
            atMillis - started >= holdBeforeWordsMillis
        if (wordsActive) {
            wordRepeats++
            return Step.WORD to wordIntervalMillis
        }
        characterRepeats++
        return Step.CHARACTER to characterIntervalMillis
    }

    companion object {
        private const val MAX_WORD_LENGTH = 64

        /**
         * How many UTF-16 units "delete a word" removes: the spaces before the cursor plus the
         * word in front of them, or one other character when no word is there.
         */
        fun wordLength(contextBefore: String?): Int {
            if (contextBefore.isNullOrEmpty()) return 1
            var index = contextBefore.length
            var count = 0
            while (index > 0 && contextBefore[index - 1].isWhitespace() && contextBefore[index - 1] != '\n') {
                index--
                count++
            }
            if (index == 0) return maxOf(count, 1)
            val first = contextBefore[index - 1]
            if (first == '\n') return count + 1
            if (isWordCharacter(first)) {
                while (index > 0 && isWordCharacter(contextBefore[index - 1]) && count < MAX_WORD_LENGTH) {
                    index--
                    count++
                }
            } else {
                count += lastCharacterLength(contextBefore.substring(0, index))
            }
            return maxOf(count, 1)
        }

        private fun isWordCharacter(c: Char) = c.isLetterOrDigit() || c == '\'' || c == '’' || c == '_'

        /** UTF-16 length of the last user-perceived character (emoji sequences included). */
        fun lastCharacterLength(text: String): Int {
            if (text.isEmpty()) return 0
            val iterator = java.text.BreakIterator.getCharacterInstance()
            iterator.setText(text)
            val end = iterator.last()
            val start = iterator.previous()
            return if (start == java.text.BreakIterator.DONE) 1 else end - start
        }
    }
}
