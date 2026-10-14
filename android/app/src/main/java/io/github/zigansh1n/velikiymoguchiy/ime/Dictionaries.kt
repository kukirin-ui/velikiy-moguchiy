package io.github.zigansh1n.velikiymoguchiy.ime

import android.content.Context
import io.github.zigansh1n.velikiymoguchiy.keyboard.LayoutLanguage
import io.github.zigansh1n.velikiymoguchiy.keyboard.SuggestionEngine
import io.github.zigansh1n.velikiymoguchiy.keyboard.TextReplacementTable
import io.github.zigansh1n.velikiymoguchiy.keyboard.WordList
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * One suggestion engine per language, loaded in the background on first use. Every engine call
 * runs on [worker], except the word-boundary check, which takes the engine's lock from the main
 * thread like the iOS keyboard's `queue.sync`.
 */
class Dictionaries(private val context: Context, private val keptWords: () -> Set<String>) {
    val worker: ExecutorService = Executors.newSingleThreadExecutor { Thread(it, "suggestions").apply { priority = Thread.NORM_PRIORITY + 1 } }

    @Volatile private var engines: Map<LayoutLanguage, SuggestionEngine> = emptyMap()
    private val loading = mutableSetOf<LayoutLanguage>()

    fun engine(language: LayoutLanguage): SuggestionEngine? = engines[language]

    /** Starts loading [language] if needed and calls [onReady] on the worker thread when it is there. */
    fun load(language: LayoutLanguage, onReady: () -> Unit) {
        synchronized(loading) {
            if (language in engines || !loading.add(language)) return
        }
        worker.execute {
            val engine = runCatching { build(language) }.getOrNull()
            synchronized(loading) {
                loading.remove(language)
                if (engine != null) engines = engines + (language to engine)
            }
            if (engine != null) onReady()
        }
    }

    private fun build(language: LayoutLanguage): SuggestionEngine {
        val assets = context.assets
        val words = assets.open("dictionary/${language.code}.tsv").bufferedReader().use { WordList.read(it, language) }
        val corrections = assets.open("dictionary/${language.code}.replacements.tsv").bufferedReader().use {
            TextReplacementTable(WordList.readReplacements(it))
        }
        val engine = SuggestionEngine(language, words, corrections)
        for (word in keptWords()) {
            engine.reject(word)
            words.addWord(word)
        }
        return engine
    }

    fun shutdown() = worker.shutdownNow()
}
