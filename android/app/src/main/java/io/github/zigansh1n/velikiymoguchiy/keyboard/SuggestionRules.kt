package io.github.zigansh1n.velikiymoguchiy.keyboard

// A port of ios/Shared/Keyboard/SuggestionRules.swift: the same cells, ordering and correction rules.

/** One cell of the suggestion bar. */
data class Suggestion(
    /** What gets inserted. */
    val text: String,
    val isTypedWord: Boolean = false,
    /** The typed word is not a known word: shown in quotes. */
    val isQuoted: Boolean = false,
    /** The candidate that a word boundary would insert automatically. */
    val isAutocorrection: Boolean = false,
) {
    val display: String get() = if (isQuoted) "“$text”" else text
}

object CasePreservation {
    /** "Hello" -> "Help" becomes "Help", "HELLO" -> "HELP", "hello" -> "help". */
    fun apply(candidate: String, typed: String): String {
        val first = typed.firstOrNull() ?: return candidate
        if (typed.length > 1 && typed == typed.uppercase() && typed != typed.lowercase()) return candidate.uppercase()
        if (first.isUpperCase() && candidate.isNotEmpty()) return candidate[0].uppercase() + candidate.substring(1)
        return candidate
    }
}

object EditDistance {
    /** Optimal string alignment distance (Damerau-Levenshtein with adjacent swaps), case-insensitive. */
    fun between(a: String, b: String): Int {
        val left = a.lowercase()
        val right = b.lowercase()
        if (left.isEmpty()) return right.length
        if (right.isEmpty()) return left.length
        val table = Array(left.length + 1) { IntArray(right.length + 1) }
        for (i in 0..left.length) table[i][0] = i
        for (j in 0..right.length) table[0][j] = j
        for (i in 1..left.length) {
            for (j in 1..right.length) {
                val cost = if (left[i - 1] == right[j - 1]) 0 else 1
                var value = minOf(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
                if (i > 1 && j > 1 && left[i - 1] == right[j - 2] && left[i - 2] == right[j - 1]) {
                    value = minOf(value, table[i - 2][j - 2] + 1)
                }
                table[i][j] = value
            }
        }
        return table[left.length][right.length]
    }
}

object WordBoundary {
    /** Keys after which the word before the cursor is finished. */
    private val boundaries = setOf(" ", "\n", ".", ",", "!", "?", ";", ":", ")", "”", "»")

    fun isBoundary(text: String) = text in boundaries

    /** Characters that mean "this is a URL, an e-mail or a handle, not a word". */
    private val technicalNeighbours = setOf('.', '@', '/', '#', ':', '_', '\\')

    /**
     * The letters (and apostrophes) in front of the cursor, or "" when there is no word to
     * complete (the cursor follows a space, a digit, "@" and so on).
     */
    fun partialWord(contextBefore: String?): String {
        if (contextBefore.isNullOrEmpty()) return ""
        var index = contextBefore.length
        var count = 0
        while (index > 0) {
            val c = contextBefore[index - 1]
            if (!(c.isLetter() || c == '\'' || c == '’')) break
            index--
            count++
            if (count >= 40) return ""
        }
        if (count == 0) return ""
        if (index > 0) {
            val neighbour = contextBefore[index - 1]
            if (neighbour.isDigit() || neighbour in technicalNeighbours) return ""
        }
        // A leading apostrophe belongs to a quote, not to the word.
        return contextBefore.substring(index).trimStart('\'', '’')
    }

    /** The last whitespace-delimited token (replacements may contain digits and symbols). */
    fun lastToken(contextBefore: String?): String {
        if (contextBefore == null) return ""
        val start = contextBefore.indexOfLast { it.isWhitespace() } + 1
        val token = contextBefore.substring(start)
        return if (token.length > 40) "" else token
    }
}

object SuggestionComposer {
    /**
     * Up to three cells: the typed word first (quoted when it is not a word), then the best
     * candidates. The second cell is the automatic correction.
     */
    fun compose(
        typed: String,
        isValidWord: Boolean,
        guesses: List<String>,
        completions: List<String>,
        lexiconMatches: List<String>,
        autocorrection: String? = null,
    ): List<Suggestion> {
        if (typed.isEmpty()) return emptyList()
        val seen = mutableSetOf(typed.lowercase())
        val candidates = mutableListOf<String>()
        fun add(list: List<String>) {
            for (item in list) {
                val cased = CasePreservation.apply(item, typed)
                val key = cased.lowercase()
                if (cased.isEmpty() || key in seen) continue
                seen += key
                candidates += cased
            }
        }
        val lowered = typed.lowercase()
        // An exact text-replacement hit beats everything.
        val exact = lexiconMatches.filter { it.lowercase() != lowered }
        // Guesses that continue what is typed read as completions, so they lead.
        val continuing = guesses.filter { it.lowercase().startsWith(lowered) }
        val corrections = guesses.filter { !it.lowercase().startsWith(lowered) }
        autocorrection?.let { add(listOf(it)) }
        if (isValidWord) {
            add(completions); add(continuing); add(corrections); add(exact)
        } else {
            // A word list has no fuzzy completions the way UITextChecker does, so a known
            // continuation ("здравс" -> "здравствуйте") goes before one-letter fixes.
            add(continuing); add(completions); add(corrections); add(exact)
        }
        val result = mutableListOf(Suggestion(typed, isTypedWord = true, isQuoted = !isValidWord))
        candidates.take(2).forEachIndexed { index, text ->
            result += Suggestion(text, isAutocorrection = index == 0 && autocorrection != null)
        }
        return result
    }
}

object AutocorrectRules {
    /**
     * A correction only for an unknown word of at least three letters, one edit away from the best
     * guess, never for acronyms, camelCase or a word the user already put back with ⌫.
     */
    fun correction(word: String, guesses: List<String>, isValidWord: Boolean, rejectedWords: Set<String>): String? {
        if (isValidWord || word.length < 3) return null
        if (!word.all { it.isLetter() || it == '\'' || it == '’' }) return null
        if (word.lowercase() in rejectedWords) return null
        // "NASA", "iPhone", "McDonald": leave alone.
        if (word.drop(1).any { it.isUpperCase() }) return null
        val best = guesses.firstOrNull {
            it.lowercase() != word.lowercase() && EditDistance.between(it, word) == 1 && ' ' !in it
        } ?: return null
        return CasePreservation.apply(best, word)
    }
}

/** Shortcut -> phrase pairs: the user's personal dictionary shortcuts, or built-in typo fixes. */
class TextReplacementTable(pairs: List<Pair<String, String>> = emptyList()) {
    private val entries: Map<String, String> = pairs
        .filter { (input, text) -> input.isNotEmpty() && input != text }
        .associate { (input, text) -> input.lowercase() to text }

    val isEmpty: Boolean get() = entries.isEmpty()

    fun replacement(token: String): String? = entries[token.lowercase()]

    /** Phrases whose shortcut starts with what is typed (suggestion candidates). */
    fun documentTexts(prefix: String): List<String> {
        val key = prefix.lowercase()
        if (key.isEmpty()) return emptyList()
        return entries.filterKeys { it.startsWith(key) }.toSortedMap().values.toList()
    }
}

/** Plans what typing a boundary key does to the word before the cursor. */
data class BoundaryReplacement(val original: String, val replacement: String, val isAutocorrect: Boolean)

/** What Apple's keyboard offers before the first letter of a sentence. */
object SentenceStarters {
    fun suggestions(language: LayoutLanguage, contextBefore: String?): List<Suggestion> {
        if (!startsSentence(contextBefore)) return emptyList()
        val words = if (language == LayoutLanguage.RUSSIAN) listOf("Я", "Ну") else listOf("I", "The", "I'm")
        return words.map { Suggestion(it) }
    }

    /** Empty field, a new line, or a space after the end of a sentence. */
    fun startsSentence(contextBefore: String?): Boolean {
        val context = contextBefore.orEmpty()
        if (context.isEmpty() || context.endsWith("\n")) return true
        if (!context.endsWith(" ")) return false
        val last = context.trim { it == ' ' || it == '\t' }.lastOrNull() ?: return true
        return last in ".!?…"
    }
}
