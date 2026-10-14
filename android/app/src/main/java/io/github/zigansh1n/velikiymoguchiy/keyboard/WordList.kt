package io.github.zigansh1n.velikiymoguchiy.keyboard

import java.io.BufferedReader

/** The dictionary calls the suggestion bar needs; on iOS `UITextChecker` answers them. */
interface TextChecker {
    fun isValidWord(word: String): Boolean
    fun completions(partial: String): List<String>
    fun guesses(word: String): List<String>
}

/**
 * A frequency word list (android/tools/build_wordlists.py). Lookups ignore case and treat «ё» as
 * «е», since most people type «еще» for «ещё»; candidates keep the dictionary spelling.
 * Not thread-safe for [addWord]: use from one thread.
 */
class WordList(entries: List<Pair<String, Int>>, private val alphabet: String) : TextChecker {
    private val words: Array<String>
    private val keys: Array<String>
    private val frequencies: IntArray

    /** Normalized key -> index of its most frequent spelling. */
    private val best = HashMap<String, Int>(entries.size * 2)
    private val learned = HashSet<String>()

    init {
        val normalized = Array(entries.size) { normalize(entries[it].first) }
        val order = entries.indices.sortedWith { a, b ->
            val byKey = normalized[a].compareTo(normalized[b])
            if (byKey != 0) byKey else entries[b].second.compareTo(entries[a].second)
        }
        words = Array(order.size) { entries[order[it]].first }
        keys = Array(order.size) { normalized[order[it]] }
        frequencies = IntArray(order.size) { entries[order[it]].second }
        for (i in keys.indices) best.putIfAbsent(keys[i], i)
    }

    val size: Int get() = words.size

    /** Words the user kept as typed or has in the personal dictionary. */
    fun addWord(word: String) {
        if (word.isNotBlank()) learned += normalize(word)
    }

    override fun isValidWord(word: String): Boolean {
        val key = normalize(word)
        return key in best || key in learned
    }

    override fun completions(partial: String): List<String> {
        val prefix = normalize(partial)
        if (prefix.isEmpty()) return emptyList()
        var index = lowerBound(prefix)
        val found = ArrayList<Int>()
        while (index < keys.size && keys[index].startsWith(prefix)) {
            if (frequencies[index] > 0 && words[index] != partial) found += index
            index++
        }
        return found.sortedByDescending { frequencies[it] }.take(MAX_CANDIDATES).map { words[it] }
    }

    override fun guesses(word: String): List<String> {
        val key = normalize(word)
        if (key.isEmpty() || key.length > MAX_GUESS_LENGTH) return emptyList()
        val found = LinkedHashSet<Int>()
        for (candidate in edits(key)) {
            val index = best[candidate] ?: continue
            if (frequencies[index] > 0 && candidate != key) found += index
        }
        return found.sortedByDescending { frequencies[it] }.take(MAX_CANDIDATES).map { words[it] }
    }

    private fun lowerBound(prefix: String): Int {
        var low = 0
        var high = keys.size
        while (low < high) {
            val mid = (low + high) ushr 1
            if (keys[mid] < prefix) low = mid + 1 else high = mid
        }
        return low
    }

    /** Every string one deletion, swap, replacement or insertion away. */
    private fun edits(word: String): Set<String> {
        val result = HashSet<String>()
        for (i in 0..word.length) {
            val head = word.substring(0, i)
            val tail = word.substring(i)
            if (tail.isNotEmpty()) result += head + tail.substring(1)
            if (tail.length > 1) result += head + tail[1] + tail[0] + tail.substring(2)
            for (c in alphabet) {
                if (tail.isNotEmpty()) result += head + c + tail.substring(1)
                result += head + c + tail
            }
        }
        return result
    }

    companion object {
        const val RUSSIAN_ALPHABET = "абвгдежзийклмнопрстуфхцчшщъыьэюя-"
        const val ENGLISH_ALPHABET = "abcdefghijklmnopqrstuvwxyz'-"
        private const val MAX_CANDIDATES = 5
        private const val MAX_GUESS_LENGTH = 16

        fun normalize(word: String): String = word.lowercase().replace('ё', 'е').replace('’', '\'')

        fun alphabet(language: LayoutLanguage) =
            if (language == LayoutLanguage.RUSSIAN) RUSSIAN_ALPHABET else ENGLISH_ALPHABET

        /** `word<TAB>frequency` lines; frequency 0 marks a word that is valid but never offered. */
        fun read(reader: BufferedReader, language: LayoutLanguage): WordList {
            val entries = ArrayList<Pair<String, Int>>(200_000)
            reader.forEachLine { line ->
                val tab = line.indexOf('\t')
                if (tab > 0) entries += line.substring(0, tab) to (line.substring(tab + 1).toIntOrNull() ?: 0)
            }
            return WordList(entries, alphabet(language))
        }

        /** `typo<TAB>replacement` lines. */
        fun readReplacements(reader: BufferedReader): List<Pair<String, String>> =
            reader.lineSequence().mapNotNull { line ->
                val tab = line.indexOf('\t')
                if (tab > 0) line.substring(0, tab) to line.substring(tab + 1) else null
            }.toList()
    }
}
