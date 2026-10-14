package io.github.zigansh1n.velikiymoguchiy.ime

import android.content.Context
import android.content.Intent
import android.inputmethodservice.InputMethodService
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.HapticFeedbackConstants
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.ComposeView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner
import io.github.zigansh1n.velikiymoguchiy.dictation.DictationController
import io.github.zigansh1n.velikiymoguchiy.dictation.DictationLanguage
import io.github.zigansh1n.velikiymoguchiy.dictation.DictationState
import io.github.zigansh1n.velikiymoguchiy.dictation.TranscriptFormatter
import io.github.zigansh1n.velikiymoguchiy.keyboard.Autocapitalization
import io.github.zigansh1n.velikiymoguchiy.keyboard.CapitalizationMode
import io.github.zigansh1n.velikiymoguchiy.keyboard.DeleteRepeat
import io.github.zigansh1n.velikiymoguchiy.keyboard.InputProfile
import io.github.zigansh1n.velikiymoguchiy.keyboard.KeyAction
import io.github.zigansh1n.velikiymoguchiy.keyboard.KeyboardState
import io.github.zigansh1n.velikiymoguchiy.keyboard.LayoutKey
import io.github.zigansh1n.velikiymoguchiy.keyboard.LayoutLanguage
import io.github.zigansh1n.velikiymoguchiy.keyboard.ReturnKind
import io.github.zigansh1n.velikiymoguchiy.keyboard.Suggestion
import io.github.zigansh1n.velikiymoguchiy.keyboard.TextEditor
import io.github.zigansh1n.velikiymoguchiy.keyboard.TypingController
import io.github.zigansh1n.velikiymoguchiy.keyboard.TypingOptions
import io.github.zigansh1n.velikiymoguchiy.settings.AppSettings
import io.github.zigansh1n.velikiymoguchiy.settings.SettingsActivity

/** The input method: Russian and English layouts, suggestions and the dictation key. */
class KeyboardService : InputMethodService(), LifecycleOwner, SavedStateRegistryOwner {
    private val lifecycleRegistry = LifecycleRegistry(this)
    private val savedStateController = SavedStateRegistryController.create(this)
    override val lifecycle: Lifecycle get() = lifecycleRegistry
    override val savedStateRegistry: SavedStateRegistry get() = savedStateController.savedStateRegistry

    private lateinit var settings: AppSettings
    private lateinit var dictionaries: Dictionaries
    private lateinit var dictation: DictationController
    private val model = KeyboardModel()
    private val states = LayoutLanguage.entries.associateWith { KeyboardState(it) }
    private val main = Handler(Looper.getMainLooper())
    private val deleteRepeat = DeleteRepeat()
    private val typing by lazy { TypingController(editor) { SystemClock.uptimeMillis() } }

    /** Bumped when the keyboard moves to another field; dictation results check it. */
    private var fieldGeneration = 0
    private var dictationGeneration = -1
    private var inputActive = false

    private var suggestionGeneration = 0
    private var pendingSuggestionContext: String? = null
    private var suggestionJobRunning = false

    private val state: KeyboardState get() = states.getValue(model.language)

    override fun onCreate() {
        super.onCreate()
        savedStateController.performRestore(null)
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_CREATE)
        settings = AppSettings(this)
        dictionaries = Dictionaries(this) { settings.keptWords }
        dictation = DictationController(this, settings, ::onDictationResult)
        model.language = settings.language
        publishLayout()
        dictionaries.load(model.language) { main.post { refreshTextState() } }
    }

    override fun onCreateInputView(): View {
        window.window?.decorView?.let { decor ->
            decor.setViewTreeLifecycleOwner(this)
            decor.setViewTreeSavedStateRegistryOwner(this)
        }
        return ComposeView(this).apply {
            setViewTreeLifecycleOwner(this@KeyboardService)
            setViewTreeSavedStateRegistryOwner(this@KeyboardService)
            setContent {
                val dictationState by dictation.state.collectAsState()
                KeyboardScreen(model, dictationState, actions)
            }
        }
    }

    // Keep the app visible in landscape instead of the full-screen extract view.
    override fun onEvaluateFullscreenMode(): Boolean = false

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        if (!restarting) fieldGeneration++
        inputActive = true
        val info = attribute ?: EditorInfo()
        model.profile = InputProfile.resolve(info.inputType, info.imeOptions)
        typing.reset()
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_RESUME)
        if (!restarting) {
            if (model.profile.startsOnNumbers) state.showNumbers() else state.showLetters()
        }
        refreshTextState()
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        super.onFinishInputView(finishingInput)
        stopDeleteRepeat()
        // The keyboard went away mid-dictation: finish it; the text lands in the field or waits.
        if (dictation.state.value is DictationState.Listening) dictation.stop()
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_PAUSE)
    }

    override fun onFinishInput() {
        super.onFinishInput()
        inputActive = false
    }

    override fun onUpdateSelection(
        oldSelStart: Int, oldSelEnd: Int, newSelStart: Int, newSelEnd: Int, candidatesStart: Int, candidatesEnd: Int,
    ) {
        super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
        main.removeCallbacks(refreshRunnable)
        main.post(refreshRunnable)
    }

    override fun onDestroy() {
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_DESTROY)
        dictation.destroy()
        dictionaries.shutdown()
        main.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    private val refreshRunnable = Runnable { refreshTextState() }

    private val editor = object : TextEditor {
        override fun textBeforeCursor(): String? = currentInputConnection?.getTextBeforeCursor(CONTEXT_LENGTH, 0)?.toString()

        override fun deleteBefore(length: Int) {
            currentInputConnection?.deleteSurroundingText(length, 0)
        }

        override fun insert(text: String) {
            currentInputConnection?.commitText(text, 1)
        }
    }

    // Shift, autocapitalization and suggestions follow the text before the cursor.
    private fun refreshTextState() {
        val context = editor.textBeforeCursor()
        val profile = model.profile
        val mode = profile.capitalization
        if (mode == CapitalizationMode.CHARACTERS || settings.autocapitalization) {
            state.applyAutomaticCapitalization(Autocapitalization.capitalization(mode, context))
        }
        publishLayout()
        refreshSuggestions(context)
    }

    private fun publishLayout() {
        model.page = state.page
        model.capitalization = state.capitalization
        model.rows = state.layout(model.profile.kind)
    }

    /** One job at a time, for the newest text only, like the iOS keyboard. */
    private fun refreshSuggestions(context: String?) {
        suggestionGeneration++
        if (!model.profile.allowsSuggestions || dictation.isActive) {
            model.suggestions = emptyList()
            return
        }
        val engine = dictionaries.engine(model.language)
        if (engine == null) {
            dictionaries.load(model.language) { main.post { refreshTextState() } }
            model.suggestions = emptyList()
            return
        }
        pendingSuggestionContext = context.orEmpty()
        if (!suggestionJobRunning) runPendingSuggestion()
    }

    private fun runPendingSuggestion() {
        val context = pendingSuggestionContext ?: run {
            suggestionJobRunning = false
            return
        }
        pendingSuggestionContext = null
        suggestionJobRunning = true
        val generation = suggestionGeneration
        val language = model.language
        val engine = dictionaries.engine(language) ?: return run { suggestionJobRunning = false }
        val autocorrect = settings.autocorrect
        dictionaries.worker.execute {
            val result = synchronized(engine) { engine.suggestions(context, autocorrect) }
            main.post {
                if (generation == suggestionGeneration && language == model.language) model.suggestions = result
                runPendingSuggestion()
            }
        }
    }

    private fun typeText(text: String) {
        val profile = model.profile
        val engine = dictionaries.engine(model.language)
        val canReplace = profile.allowsSuggestions || engine?.replacements?.isEmpty == false
        val autocorrect = settings.autocorrect && profile.allowsSuggestions
        currentInputConnection?.beginBatchEdit()
        typing.type(
            text,
            model.language,
            TypingOptions(
                smartPunctuation = settings.smartPunctuation && profile.smartPunctuation,
                doubleSpacePeriod = settings.doubleSpacePeriod && profile.allowsSuggestions,
            ),
        ) { context ->
            if (engine == null || !canReplace) null else synchronized(engine) { engine.replacement(context, autocorrect) }
        }
        currentInputConnection?.endBatchEdit()
        state.consumeText()
        refreshTextState()
    }

    private fun deleteOnce(step: DeleteRepeat.Step = DeleteRepeat.Step.CHARACTER) {
        val connection = currentInputConnection ?: return
        if (step == DeleteRepeat.Step.CHARACTER) {
            typing.revertLastReplacement()?.let { undone ->
                if (undone.isAutocorrect) keepWord(undone.original)
                refreshTextState()
                return
            }
        }
        typing.reset()
        val selected = connection.getSelectedText(0)
        when {
            !selected.isNullOrEmpty() -> connection.commitText("", 1)
            else -> {
                val before = editor.textBeforeCursor()
                if (before.isNullOrEmpty()) {
                    // Nothing we can see (or a field without text access): let the app handle the key.
                    sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL)
                } else {
                    val length = if (step == DeleteRepeat.Step.WORD) {
                        DeleteRepeat.wordLength(before)
                    } else {
                        DeleteRepeat.lastCharacterLength(before)
                    }
                    connection.deleteSurroundingText(length, 0)
                }
            }
        }
        refreshTextState()
    }

    private val deleteTick = object : Runnable {
        override fun run() {
            val (step, next) = deleteRepeat.tick(SystemClock.uptimeMillis()) ?: return
            deleteOnce(step)
            main.postDelayed(this, next)
        }
    }

    private fun stopDeleteRepeat() {
        deleteRepeat.end()
        main.removeCallbacks(deleteTick)
    }

    private fun handleReturn() {
        val profile = model.profile
        when {
            // Like AOSP's keyboard: a field's action wins unless it asks for no enter action.
            profile.returnKind != ReturnKind.NEWLINE -> currentInputConnection?.performEditorAction(profile.returnKind.actionId)
            profile.multiLine -> typeText("\n")
            // A single-line field without an action, or a terminal-like view: a real Enter key.
            else -> sendKeyChar('\n')
        }
    }

    private fun switchLanguage() {
        if (dictation.isActive) return
        model.language = model.language.other
        settings.language = model.language
        state.showLetters()
        model.suggestions = emptyList()
        dictionaries.load(model.language) { main.post { refreshTextState() } }
        refreshTextState()
    }

    private fun keepWord(word: String) {
        if (word.isBlank()) return
        settings.keepWord(word)
        val engine = dictionaries.engine(model.language) ?: return
        dictionaries.worker.execute { synchronized(engine) { engine.reject(word) } }
    }

    private fun onDictationResult(text: String) {
        if (text.isBlank()) return
        val connection = currentInputConnection
        if (inputActive && connection != null && dictationGeneration == fieldGeneration) {
            insertDictation(text)
        } else {
            model.pendingText = text
        }
        refreshTextState()
    }

    private fun insertDictation(text: String) {
        val connection = currentInputConnection ?: return
        connection.beginBatchEdit()
        connection.commitText(TranscriptFormatter.textForInsertion(text, editor.textBeforeCursor()), 1)
        connection.endBatchEdit()
        typing.reset()
    }

    private fun openSettings(requestMicrophone: Boolean) {
        startActivity(
            Intent(this, SettingsActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(SettingsActivity.EXTRA_REQUEST_MICROPHONE, requestMicrophone),
        )
    }

    private fun feedback(key: LayoutKey) {
        val view = window.window?.decorView ?: return
        if (settings.keyVibration) view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
        if (settings.keySound) {
            val effect = when (key.action) {
                KeyAction.Backspace -> AudioManager.FX_KEYPRESS_DELETE
                KeyAction.Space -> AudioManager.FX_KEYPRESS_SPACEBAR
                KeyAction.Return -> AudioManager.FX_KEYPRESS_RETURN
                else -> AudioManager.FX_KEYPRESS_STANDARD
            }
            (getSystemService(Context.AUDIO_SERVICE) as AudioManager).playSoundEffect(effect, -1f)
        }
    }

    private val actions = object : KeyboardActions {
        override fun onKeyDown(key: LayoutKey) = feedback(key)

        override fun onKey(action: KeyAction) {
            if (dictation.isActive && action != KeyAction.Microphone) return
            when (action) {
                is KeyAction.Text -> typeText(action.value)
                KeyAction.Space -> typeText(" ")
                KeyAction.Return -> handleReturn()
                KeyAction.Shift -> {
                    state.tapShift(SystemClock.uptimeMillis())
                    publishLayout()
                }
                KeyAction.Page -> {
                    state.tapPage()
                    publishLayout()
                }
                KeyAction.Language -> switchLanguage()
                KeyAction.Microphone -> {
                    if (!dictation.hasMicrophonePermission()) {
                        openSettings(requestMicrophone = true)
                        return
                    }
                    if (!dictation.isActive) {
                        dictationGeneration = fieldGeneration
                        model.suggestions = emptyList()
                    }
                    dictation.toggle(
                        if (model.language == LayoutLanguage.RUSSIAN) DictationLanguage.RUSSIAN else DictationLanguage.ENGLISH,
                    )
                }
                KeyAction.Backspace, KeyAction.Blank -> Unit
            }
        }

        override fun onDeleteStart() {
            if (dictation.isActive) return
            deleteOnce()
            main.removeCallbacks(deleteTick)
            main.postDelayed(deleteTick, deleteRepeat.begin(SystemClock.uptimeMillis()))
        }

        override fun onDeleteStop() = stopDeleteRepeat()

        override fun onMoveCursor(steps: Int) {
            if (dictation.isActive) return
            val key = if (steps < 0) KeyEvent.KEYCODE_DPAD_LEFT else KeyEvent.KEYCODE_DPAD_RIGHT
            repeat(kotlin.math.abs(steps)) { sendDownUpKeyEvents(key) }
            typing.reset()
        }

        override fun onLongPress(action: KeyAction) {
            when (action) {
                KeyAction.Language -> (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).showInputMethodPicker()
                KeyAction.Microphone -> openSettings(requestMicrophone = false)
                else -> Unit
            }
        }

        override fun onSuggestion(suggestion: Suggestion) {
            currentInputConnection?.beginBatchEdit()
            val kept = typing.applySuggestion(suggestion)
            currentInputConnection?.endBatchEdit()
            if (kept != null) keepWord(kept)
            state.consumeText()
            refreshTextState()
        }

        override fun onDictationDone() = dictation.stop()

        override fun onDictationCancel() = dictation.cancel()

        override fun onDismissError() = dictation.dismissError()

        override fun onInsertPending() {
            val text = model.pendingText ?: return
            model.pendingText = null
            insertDictation(text)
            refreshTextState()
        }

        override fun onDiscardPending() {
            model.pendingText = null
        }

        override fun onOpenSettings() {
            dictation.dismissError()
            openSettings(requestMicrophone = !dictation.hasMicrophonePermission())
        }

        override fun alternates(key: LayoutKey): List<String> {
            val text = (key.action as? KeyAction.Text)?.value ?: return emptyList()
            return state.alternates(text)
        }
    }

    private companion object {
        const val CONTEXT_LENGTH = 64
    }
}
