package io.github.zigansh1n.velikiymoguchiy.keyboard

/**
 * Builds the three suggestions for the word before the cursor and decides automatic corrections.
 * Not thread-safe: the service calls it from one background thread.
 */
class SuggestionEngine(
    private val language: LayoutLanguage,
    private val checker: TextChecker?,
    /** Built-in typo fixes from the word list ("щас" -> "сейчас"), applied as corrections. */
    private val corrections: TextReplacementTable = TextReplacementTable(),
) {
    /** The user's shortcuts from the Android personal dictionary, applied in every text field. */
    var replacements = TextReplacementTable()

    /** Words the user put back with ⌫ right after a correction or kept as typed. */
    val rejectedWords: MutableSet<String> = mutableSetOf()

    val hasDictionary: Boolean get() = checker != null

    fun reject(word: String) {
        rejectedWords += word.lowercase()
    }

    fun suggestions(contextBefore: String?, autocorrectEnabled: Boolean): List<Suggestion> {
        val typed = WordBoundary.partialWord(contextBefore)
        if (typed.isEmpty()) return SentenceStarters.suggestions(language, contextBefore)
        if (checker == null && replacements.isEmpty) return emptyList()
        val isValid = checker?.isValidWord(typed) ?: true
        val completions = checker?.completions(typed).orEmpty()
        // Guesses are the slow call; ask only when the word looks wrong or is short.
        val guesses = if (isValid && typed.length > 3) emptyList() else checker?.guesses(typed).orEmpty()
        val autocorrection = if (autocorrectEnabled) correction(typed, isValid, guesses) else null
        return SuggestionComposer.compose(
            typed = typed,
            isValidWord = isValid,
            guesses = guesses,
            completions = completions,
            lexiconMatches = replacements.documentTexts(typed),
            autocorrection = autocorrection,
        )
    }

    /** What typing a boundary key should do to the text before the cursor, if anything. */
    fun replacement(contextBefore: String?, autocorrectEnabled: Boolean): BoundaryReplacement? {
        val token = WordBoundary.lastToken(contextBefore)
        if (token.isEmpty()) return null
        replacements.replacement(token)?.let { return BoundaryReplacement(token, it, isAutocorrect = false) }
        if (!autocorrectEnabled || checker == null) return null
        val word = WordBoundary.partialWord(contextBefore)
        if (word != token) return null
        val isValid = checker.isValidWord(word)
        if (isValid) return null
        val corrected = correction(word, isValid = false, guesses = checker.guesses(word)) ?: return null
        return BoundaryReplacement(word, corrected, isAutocorrect = true)
    }

    private fun correction(word: String, isValid: Boolean, guesses: List<String>): String? {
        if (isValid || word.lowercase() in rejectedWords) return null
        corrections.replacement(word)?.let { return CasePreservation.apply(it, word) }
        return AutocorrectRules.correction(word, guesses, isValidWord = false, rejectedWords = rejectedWords)
    }
}
