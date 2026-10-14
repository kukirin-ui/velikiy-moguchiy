package io.github.zigansh1n.velikiymoguchiy.keyboard

/** The text field as the typing logic sees it; lengths are UTF-16 units, as in InputConnection. */
interface TextEditor {
    fun textBeforeCursor(): String?
    fun deleteBefore(length: Int)
    fun insert(text: String)
}

/** Per-field switches the typing logic follows. */
data class TypingOptions(
    val smartPunctuation: Boolean,
    val doubleSpacePeriod: Boolean,
)

/**
 * One key press worth of text, as in ios/KeyboardExtension/Controller/KeyboardViewController+Suggestions.swift:
 * replacements and corrections at word boundaries, smart punctuation, the double-space period,
 * and ⌫ right after a correction putting the original word back.
 */
class TypingController(
    private val editor: TextEditor,
    private val clock: () -> Long,
) {
    private var lastReplacement: Pair<BoundaryReplacement, String>? = null
    private var lastSpaceAt: Long? = null

    /** [plan] answers the engine's [SuggestionEngine.replacement] for the current context. */
    fun type(
        text: String,
        language: LayoutLanguage,
        options: TypingOptions,
        plan: (contextBefore: String?) -> BoundaryReplacement?,
    ) {
        var context = editor.textBeforeCursor()
        var replaced: BoundaryReplacement? = null

        if (WordBoundary.isBoundary(text)) {
            val replacement = plan(context)
            if (replacement != null && context?.endsWith(replacement.original) == true) {
                editor.deleteBefore(replacement.original.length)
                editor.insert(replacement.replacement)
                context = context.dropLast(replacement.original.length) + replacement.replacement
                replaced = replacement
            }
        }

        if (text == " " && replaced == null && options.doubleSpacePeriod && shouldTurnDoubleSpaceIntoPeriod(context)) {
            // Apple's shortcut: a second quick space after a word becomes ". ".
            editor.deleteBefore(1)
            editor.insert(". ")
            lastSpaceAt = null
            lastReplacement = null
            return
        }

        val edit = SmartPunctuation.edit(text, context, language, options.smartPunctuation)
        if (edit.deleteBefore > 0) editor.deleteBefore(edit.deleteBefore)
        editor.insert(edit.insert)
        lastSpaceAt = if (text == " ") clock() else null
        lastReplacement = replaced?.let { it to edit.insert }
    }

    /** Tap on a candidate: replace the word being typed and add a space. Returns the word kept as typed, if any. */
    fun applySuggestion(suggestion: Suggestion): String? {
        val partial = WordBoundary.partialWord(editor.textBeforeCursor())
        if (partial.isNotEmpty()) editor.deleteBefore(partial.length)
        editor.insert(suggestion.text + " ")
        lastReplacement = null
        lastSpaceAt = null
        return if (suggestion.isTypedWord) partial else null
    }

    /**
     * ⌫ right after an automatic replacement puts the original word back without the boundary.
     * Returns the replacement it undid, or null when ⌫ should delete as usual.
     */
    fun revertLastReplacement(): BoundaryReplacement? {
        val (plan, boundary) = lastReplacement ?: return null
        lastReplacement = null
        val expected = plan.replacement + boundary
        if (editor.textBeforeCursor()?.endsWith(expected) != true) return null
        editor.deleteBefore(expected.length)
        editor.insert(plan.original)
        return plan
    }

    /** Anything else happened (a deletion, a cursor move, dictation): forget the last edit. */
    fun reset() {
        lastReplacement = null
        lastSpaceAt = null
    }

    private fun shouldTurnDoubleSpaceIntoPeriod(context: String?): Boolean {
        val last = lastSpaceAt ?: return false
        if (clock() - last >= DOUBLE_SPACE_MILLIS) return false
        if (context == null || !context.endsWith(" ") || context.length < 2) return false
        val beforeSpace = context[context.length - 2]
        return beforeSpace.isLetterOrDigit()
    }

    companion object {
        const val DOUBLE_SPACE_MILLIS = 600L
    }
}
