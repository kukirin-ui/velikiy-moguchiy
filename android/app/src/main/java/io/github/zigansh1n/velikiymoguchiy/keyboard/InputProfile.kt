package io.github.zigansh1n.velikiymoguchiy.keyboard

import android.text.InputType
import android.view.inputmethod.EditorInfo

enum class InputKind {
    STANDARD,
    EMAIL,
    URL,
    WEB_SEARCH,
    NUMBER_PAD,
    DECIMAL_PAD,
    PHONE_PAD;

    val isTechnical: Boolean get() = this != STANDARD
    val isDigitPad: Boolean get() = this == NUMBER_PAD || this == DECIMAL_PAD || this == PHONE_PAD
}

enum class CapitalizationMode { NONE, CHARACTERS, WORDS, SENTENCES }

/** What the return key does: a new line, or the editor action with this id. */
enum class ReturnKind(val actionId: Int) {
    NEWLINE(EditorInfo.IME_ACTION_NONE),
    GO(EditorInfo.IME_ACTION_GO),
    SEARCH(EditorInfo.IME_ACTION_SEARCH),
    SEND(EditorInfo.IME_ACTION_SEND),
    NEXT(EditorInfo.IME_ACTION_NEXT),
    PREVIOUS(EditorInfo.IME_ACTION_PREVIOUS),
    DONE(EditorInfo.IME_ACTION_DONE),
}

/** How the keyboard serves one text field, decided from its [EditorInfo] fields. */
data class InputProfile(
    val kind: InputKind,
    val capitalization: CapitalizationMode,
    val returnKind: ReturnKind,
    /** Predictions and corrections: ordinary text only, never passwords or technical fields. */
    val allowsSuggestions: Boolean,
    val smartPunctuation: Boolean,
    /** Number-and-punctuation style fields (dates, times) open on the "123" page. */
    val startsOnNumbers: Boolean,
    val isSecure: Boolean,
    /** Return types a new line here even when the field also has an action. */
    val multiLine: Boolean = false,
) {
    companion object {
        fun resolve(inputType: Int, imeOptions: Int): InputProfile {
            val inputClass = inputType and InputType.TYPE_MASK_CLASS
            val variation = inputType and InputType.TYPE_MASK_VARIATION
            val flags = inputType and InputType.TYPE_MASK_FLAGS
            val returnKind = returnKind(imeOptions)

            val kind = when (inputClass) {
                InputType.TYPE_CLASS_NUMBER ->
                    if (flags and InputType.TYPE_NUMBER_FLAG_DECIMAL != 0) InputKind.DECIMAL_PAD else InputKind.NUMBER_PAD
                InputType.TYPE_CLASS_PHONE -> InputKind.PHONE_PAD
                InputType.TYPE_CLASS_TEXT -> when (variation) {
                    InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS,
                    InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS -> InputKind.EMAIL
                    // An address bar with Go or Search also takes queries, so it keeps the space bar.
                    InputType.TYPE_TEXT_VARIATION_URI ->
                        if (returnKind == ReturnKind.GO || returnKind == ReturnKind.SEARCH) InputKind.WEB_SEARCH else InputKind.URL
                    else -> InputKind.STANDARD
                }
                else -> InputKind.STANDARD
            }

            val isPassword = inputClass == InputType.TYPE_CLASS_TEXT && variation in PASSWORD_VARIATIONS ||
                inputClass == InputType.TYPE_CLASS_NUMBER && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
            val isText = inputClass == InputType.TYPE_CLASS_TEXT
            val technicalVariation = variation in TECHNICAL_VARIATIONS
            val noSuggestions = flags and InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS != 0
            val plainText = isText && kind == InputKind.STANDARD && !isPassword && !technicalVariation

            val capitalization = when {
                !plainText -> CapitalizationMode.NONE
                flags and InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS != 0 -> CapitalizationMode.CHARACTERS
                flags and InputType.TYPE_TEXT_FLAG_CAP_WORDS != 0 -> CapitalizationMode.WORDS
                flags and InputType.TYPE_TEXT_FLAG_CAP_SENTENCES != 0 -> CapitalizationMode.SENTENCES
                else -> CapitalizationMode.NONE
            }

            return InputProfile(
                kind = kind,
                capitalization = capitalization,
                returnKind = returnKind,
                allowsSuggestions = plainText && !noSuggestions,
                smartPunctuation = plainText,
                startsOnNumbers = inputClass == InputType.TYPE_CLASS_DATETIME,
                isSecure = isPassword,
                multiLine = isText && flags and InputType.TYPE_TEXT_FLAG_MULTI_LINE != 0,
            )
        }

        fun returnKind(imeOptions: Int): ReturnKind {
            if (imeOptions and EditorInfo.IME_FLAG_NO_ENTER_ACTION != 0) return ReturnKind.NEWLINE
            return when (imeOptions and EditorInfo.IME_MASK_ACTION) {
                EditorInfo.IME_ACTION_GO -> ReturnKind.GO
                EditorInfo.IME_ACTION_SEARCH -> ReturnKind.SEARCH
                EditorInfo.IME_ACTION_SEND -> ReturnKind.SEND
                EditorInfo.IME_ACTION_NEXT -> ReturnKind.NEXT
                EditorInfo.IME_ACTION_PREVIOUS -> ReturnKind.PREVIOUS
                EditorInfo.IME_ACTION_DONE -> ReturnKind.DONE
                else -> ReturnKind.NEWLINE
            }
        }

        private val PASSWORD_VARIATIONS = setOf(
            InputType.TYPE_TEXT_VARIATION_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
        )

        private val TECHNICAL_VARIATIONS = setOf(
            InputType.TYPE_TEXT_VARIATION_URI,
            InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS,
            InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS,
            InputType.TYPE_TEXT_VARIATION_FILTER,
        )

        // After the sets above: companion properties initialize in order.
        val DEFAULT = resolve(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES, 0)
    }
}
