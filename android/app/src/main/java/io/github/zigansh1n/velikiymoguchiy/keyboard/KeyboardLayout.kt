package io.github.zigansh1n.velikiymoguchiy.keyboard

// Layouts and the page/shift state follow ios/Shared/Keyboard/KeyboardInteractionState.swift,
// which adapts concepts from KeyboardKit 9.9.1 (MIT); see android/THIRD_PARTY.md.

/** Letter layout and the language of suggestions and dictation. */
enum class LayoutLanguage(val code: String) {
    RUSSIAN("ru"),
    ENGLISH("en");

    /** Letter rows as Apple ships them on iPhone: ЙЦУКЕН / QWERTY. */
    val letterRows: List<String>
        get() = when (this) {
            RUSSIAN -> listOf("йцукенгшщзх", "фывапролджэ", "ячсмитьбю")
            ENGLISH -> listOf("qwertyuiop", "asdfghjkl", "zxcvbnm")
        }

    val pageToggleTitle: String get() = if (this == RUSSIAN) "АБВ" else "ABC"
    val spaceTitle: String get() = if (this == RUSSIAN) "Русский" else "English"
    val numbersCurrencyKey: String get() = if (this == RUSSIAN) "₽" else "$"

    val other: LayoutLanguage get() = if (this == RUSSIAN) ENGLISH else RUSSIAN

    companion object {
        fun fromCode(code: String?): LayoutLanguage =
            if (code?.lowercase()?.startsWith("en") == true) ENGLISH else RUSSIAN
    }
}

enum class KeyboardPage { LETTERS, NUMBERS, SYMBOLS }

enum class Capitalization { LOWERCASE, SHIFTED, CAPS_LOCK }

enum class KeyStyle {
    /** Letters, digits, punctuation and the space bar. */
    INPUT,

    /** Shift, delete, page and language keys, the return key. */
    SYSTEM,
}

sealed interface KeyAction {
    data class Text(val value: String) : KeyAction
    data object Shift : KeyAction
    data object Backspace : KeyAction
    data object Page : KeyAction
    data object Language : KeyAction
    data object Microphone : KeyAction
    data object Space : KeyAction
    data object Return : KeyAction
    data object Blank : KeyAction
}

/**
 * One key. [fixedPoints] is the width in iPhone points at the 402 pt reference width; null means
 * "letter width" in a centered row and "share the rest" in a fill row.
 */
data class LayoutKey(
    val action: KeyAction,
    val style: KeyStyle = KeyStyle.INPUT,
    val fixedPoints: Float? = null,
    val subtitle: String? = null,
)

enum class RowArrangement {
    /** Keys of letter width, centered; shift and delete stick to the edges. */
    CENTERED,

    /** Keys stretch to fill the row. */
    FILL,
}

data class LayoutRow(val keys: List<LayoutKey>, val arrangement: RowArrangement = RowArrangement.CENTERED)

object KeyMetrics {
    const val REFERENCE_WIDTH = 402f
    const val SIDE_MARGIN = 6.5f
    const val KEY_GAP = 6f
    const val SIDE_KEY = 136f / 3f
    const val BOTTOM_KEY = 130f / 3f
    const val RETURN_KEY = 93f
    const val PUNCTUATION_KEY = 50f
}

/** Shift, page and layout of one keyboard; the service keeps one per language. */
class KeyboardState(val language: LayoutLanguage) {
    var page: KeyboardPage = KeyboardPage.LETTERS
        private set
    var capitalization: Capitalization = Capitalization.LOWERCASE
        private set
    private var lastShiftTapMillis: Long? = null

    val usesUppercaseLetters: Boolean get() = capitalization != Capitalization.LOWERCASE

    fun tapShift(atMillis: Long) {
        when (page) {
            KeyboardPage.LETTERS -> {
                if (capitalization == Capitalization.CAPS_LOCK) {
                    capitalization = Capitalization.LOWERCASE
                    lastShiftTapMillis = null
                    return
                }
                // Two taps within the interval always mean Caps Lock, also when the first tap
                // cancelled an automatic capital at the start of a sentence.
                val last = lastShiftTapMillis
                if (last != null && atMillis >= last && atMillis - last < DOUBLE_TAP_MILLIS) {
                    capitalization = Capitalization.CAPS_LOCK
                    lastShiftTapMillis = null
                } else {
                    capitalization = if (capitalization == Capitalization.LOWERCASE) {
                        Capitalization.SHIFTED
                    } else {
                        Capitalization.LOWERCASE
                    }
                    lastShiftTapMillis = atMillis
                }
            }
            KeyboardPage.NUMBERS -> page = KeyboardPage.SYMBOLS
            KeyboardPage.SYMBOLS -> page = KeyboardPage.NUMBERS
        }
    }

    fun showLetters() {
        page = KeyboardPage.LETTERS
        resetShift()
    }

    fun showNumbers() {
        page = KeyboardPage.NUMBERS
        resetShift()
    }

    fun tapPage() {
        page = if (page == KeyboardPage.LETTERS) KeyboardPage.NUMBERS else KeyboardPage.LETTERS
        resetShift()
    }

    /** A letter was typed: a single Shift is used up. */
    fun consumeText() {
        if (page == KeyboardPage.LETTERS && capitalization == Capitalization.SHIFTED) resetShift()
    }

    fun applyAutomaticCapitalization(requested: Capitalization) {
        if (page != KeyboardPage.LETTERS || capitalization == Capitalization.CAPS_LOCK) return
        capitalization = requested
        if (requested != Capitalization.SHIFTED) lastShiftTapMillis = null
    }

    private fun resetShift() {
        capitalization = Capitalization.LOWERCASE
        lastShiftTapMillis = null
    }

    fun layout(kind: InputKind): List<LayoutRow> {
        if (kind.isDigitPad) return digitPadRows(kind)
        return when (page) {
            KeyboardPage.LETTERS -> letterRows(kind)
            KeyboardPage.NUMBERS -> numberRows(kind)
            KeyboardPage.SYMBOLS -> symbolRows(kind)
        }
    }

    fun alternates(text: String): List<String> {
        val values = when (text.lowercase()) {
            "е" -> if (language == LayoutLanguage.RUSSIAN) listOf("е", "ё") else return emptyList()
            "ь" -> if (language == LayoutLanguage.RUSSIAN) listOf("ь", "ъ") else return emptyList()
            "a" -> listOf("a", "à", "á", "â", "ä", "æ", "ã", "å", "ā")
            "c" -> listOf("c", "ç", "ć", "č")
            "e" -> listOf("e", "è", "é", "ê", "ë", "ē", "ė", "ę")
            "i" -> listOf("i", "ì", "í", "î", "ï", "ī", "į")
            "l" -> listOf("l", "ł")
            "n" -> listOf("n", "ñ", "ń")
            "o" -> listOf("o", "ò", "ó", "ô", "ö", "œ", "ø", "õ", "ō")
            "s" -> listOf("s", "ß", "ś", "š")
            "u" -> listOf("u", "ù", "ú", "û", "ü", "ū")
            "y" -> listOf("y", "ý", "ÿ")
            "z" -> listOf("z", "ž", "ź", "ż")
            "$", "₽" -> listOf("$", "€", "£", "¥", "₽", "¢")
            "0" -> listOf("0", "°")
            "?" -> listOf("?", "¿")
            "!" -> listOf("!", "¡")
            "&" -> listOf("&", "§")
            "%" -> listOf("%", "‰")
            "." -> listOf(".", "…")
            "-" -> listOf("-", "–", "—", "•")
            "'" -> listOf("'", "’", "‘", "`")
            "\"" -> if (language == LayoutLanguage.RUSSIAN) {
                listOf("\"", "«", "»", "„", "“", "”")
            } else {
                listOf("\"", "”", "“", "„")
            }
            ".com", ".ru" -> if (language == LayoutLanguage.RUSSIAN) {
                listOf(".ru", ".com", ".org", ".net", ".edu")
            } else {
                listOf(".com", ".ru", ".org", ".net", ".edu")
            }
            else -> return emptyList()
        }
        // Only letter popups follow Shift; punctuation and ".com" variants do not.
        val isLetter = text.firstOrNull()?.isLetter() == true
        return if (usesUppercaseLetters && isLetter && text == text.uppercase()) values.map { it.uppercase() } else values
    }

    private fun textKeys(row: String): List<LayoutKey> = row.map {
        LayoutKey(KeyAction.Text(if (usesUppercaseLetters) it.uppercase() else it.toString()))
    }

    private fun literalKeys(values: List<String>) = values.map { LayoutKey(KeyAction.Text(it)) }

    // Apple's Russian rows have 11 keys, so shift and delete are as wide as a letter there.
    private fun sideKey(action: KeyAction) = LayoutKey(
        action,
        KeyStyle.SYSTEM,
        fixedPoints = if (language == LayoutLanguage.ENGLISH) KeyMetrics.SIDE_KEY else null,
    )

    private fun letterRows(kind: InputKind): List<LayoutRow> {
        val rows = language.letterRows
        return listOf(
            LayoutRow(textKeys(rows[0])),
            LayoutRow(textKeys(rows[1])),
            LayoutRow(listOf(sideKey(KeyAction.Shift)) + textKeys(rows[2]) + sideKey(KeyAction.Backspace)),
            bottomRow(kind),
        )
    }

    private fun symbolThirdRow(): LayoutRow = LayoutRow(
        listOf(LayoutKey(KeyAction.Shift, KeyStyle.SYSTEM, KeyMetrics.SIDE_KEY)) +
            listOf(".", ",", "?", "!", "'").map { LayoutKey(KeyAction.Text(it), fixedPoints = KeyMetrics.PUNCTUATION_KEY) } +
            LayoutKey(KeyAction.Backspace, KeyStyle.SYSTEM, KeyMetrics.SIDE_KEY),
    )

    private fun numberRows(kind: InputKind) = listOf(
        LayoutRow(literalKeys("1234567890".map(Char::toString))),
        LayoutRow(literalKeys(listOf("-", "/", ":", ";", "(", ")", language.numbersCurrencyKey, "&", "@", "\""))),
        symbolThirdRow(),
        bottomRow(kind),
    )

    private fun symbolRows(kind: InputKind): List<LayoutRow> {
        val currencies = if (language == LayoutLanguage.RUSSIAN) {
            listOf("_", "\\", "|", "~", "<", ">", "$", "€", "£", "•")
        } else {
            listOf("_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•")
        }
        return listOf(
            LayoutRow(literalKeys(listOf("[", "]", "{", "}", "#", "%", "^", "*", "+", "="))),
            LayoutRow(literalKeys(currencies)),
            symbolThirdRow(),
            bottomRow(kind),
        )
    }

    /**
     * Apple's bottom row is [123] [emoji] [space] [return]. Android has no system globe for a
     * keyboard's own languages, so the language key comes first and the microphone takes the
     * emoji slot.
     */
    private fun bottomRow(kind: InputKind): LayoutRow {
        val small = KeyMetrics.BOTTOM_KEY
        val keys = mutableListOf(
            LayoutKey(KeyAction.Page, KeyStyle.SYSTEM, small),
            LayoutKey(KeyAction.Language, KeyStyle.SYSTEM, small),
            LayoutKey(KeyAction.Microphone, KeyStyle.SYSTEM, small),
        )
        when (kind) {
            InputKind.STANDARD -> keys += LayoutKey(KeyAction.Space)
            InputKind.EMAIL -> keys += listOf(
                LayoutKey(KeyAction.Space),
                LayoutKey(KeyAction.Text("@"), KeyStyle.SYSTEM, small),
                LayoutKey(KeyAction.Text("."), KeyStyle.SYSTEM, small),
            )
            InputKind.WEB_SEARCH -> keys += listOf(
                LayoutKey(KeyAction.Space),
                LayoutKey(KeyAction.Text("."), KeyStyle.SYSTEM, small),
            )
            InputKind.URL -> keys += listOf(
                LayoutKey(KeyAction.Text("."), KeyStyle.SYSTEM),
                LayoutKey(KeyAction.Text("/"), KeyStyle.SYSTEM),
                LayoutKey(KeyAction.Text(".com"), KeyStyle.SYSTEM),
            )
            InputKind.NUMBER_PAD, InputKind.DECIMAL_PAD, InputKind.PHONE_PAD -> Unit
        }
        // With the extra language key a full-width return would squeeze the space bar.
        val returnWidth = if (kind == InputKind.STANDARD) KeyMetrics.RETURN_KEY else small * 1.5f
        keys += LayoutKey(KeyAction.Return, KeyStyle.SYSTEM, returnWidth)
        return LayoutRow(keys, RowArrangement.FILL)
    }

    /**
     * Android number fields need an action key, unlike Apple's digit pad, so the pad has a fourth
     * column: [1 2 3 -] [4 5 6 space] [7 8 9 ⌫] [corner 0 corner ↵].
     */
    private fun digitPadRows(kind: InputKind): List<LayoutRow> {
        val letters = mapOf(
            "2" to "ABC", "3" to "DEF", "4" to "GHI", "5" to "JKL",
            "6" to "MNO", "7" to "PQRS", "8" to "TUV", "9" to "WXYZ",
        )
        fun digit(d: String) = LayoutKey(KeyAction.Text(d), subtitle = if (kind == InputKind.PHONE_PAD) letters[d] else null)
        fun row(digits: String, last: LayoutKey) =
            LayoutRow(digits.map { digit(it.toString()) } + last, RowArrangement.FILL)
        val (left, right) = when (kind) {
            InputKind.PHONE_PAD -> LayoutKey(KeyAction.Text("*"), KeyStyle.SYSTEM) to LayoutKey(KeyAction.Text("#"), KeyStyle.SYSTEM)
            InputKind.DECIMAL_PAD -> LayoutKey(KeyAction.Text(","), KeyStyle.SYSTEM) to LayoutKey(KeyAction.Text("."), KeyStyle.SYSTEM)
            else -> LayoutKey(KeyAction.Blank, KeyStyle.SYSTEM) to LayoutKey(KeyAction.Blank, KeyStyle.SYSTEM)
        }
        val firstColumnEnd = if (kind == InputKind.PHONE_PAD) "+" else "-"
        return listOf(
            row("123", LayoutKey(KeyAction.Text(firstColumnEnd), KeyStyle.SYSTEM)),
            row("456", LayoutKey(KeyAction.Space, KeyStyle.SYSTEM)),
            row("789", LayoutKey(KeyAction.Backspace, KeyStyle.SYSTEM)),
            LayoutRow(listOf(left, digit("0"), right, LayoutKey(KeyAction.Return, KeyStyle.SYSTEM)), RowArrangement.FILL),
        )
    }

    companion object {
        const val DOUBLE_TAP_MILLIS = 320L
    }
}
