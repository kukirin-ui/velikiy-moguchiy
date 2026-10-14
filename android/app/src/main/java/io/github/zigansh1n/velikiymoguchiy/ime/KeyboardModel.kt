package io.github.zigansh1n.velikiymoguchiy.ime

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import io.github.zigansh1n.velikiymoguchiy.keyboard.Capitalization
import io.github.zigansh1n.velikiymoguchiy.keyboard.InputProfile
import io.github.zigansh1n.velikiymoguchiy.keyboard.KeyAction
import io.github.zigansh1n.velikiymoguchiy.keyboard.KeyboardPage
import io.github.zigansh1n.velikiymoguchiy.keyboard.LayoutKey
import io.github.zigansh1n.velikiymoguchiy.keyboard.LayoutLanguage
import io.github.zigansh1n.velikiymoguchiy.keyboard.LayoutRow
import io.github.zigansh1n.velikiymoguchiy.keyboard.Suggestion

/** What the keyboard view draws; the service owns and updates it on the main thread. */
class KeyboardModel {
    var language by mutableStateOf(LayoutLanguage.RUSSIAN)
    var page by mutableStateOf(KeyboardPage.LETTERS)
    var capitalization by mutableStateOf(Capitalization.LOWERCASE)
    var rows by mutableStateOf(emptyList<LayoutRow>())
    var profile by mutableStateOf(InputProfile.DEFAULT)
    var suggestions by mutableStateOf(emptyList<Suggestion>())

    /** Dictation text that could not go into the field it was meant for. */
    var pendingText by mutableStateOf<String?>(null)
}

/** Everything the keyboard view can ask the service to do. */
interface KeyboardActions {
    /** A key went down: click sound and vibration. */
    fun onKeyDown(key: LayoutKey)
    fun onKey(action: KeyAction)
    fun onDeleteStart()
    fun onDeleteStop()
    fun onMoveCursor(steps: Int)
    fun onLongPress(action: KeyAction)
    fun onSuggestion(suggestion: Suggestion)
    fun onDictationDone()
    fun onDictationCancel()
    fun onDismissError()
    fun onInsertPending()
    fun onDiscardPending()
    fun onOpenSettings()
    fun alternates(key: LayoutKey): List<String>
}
