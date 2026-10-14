package io.github.zigansh1n.velikiymoguchiy.keyboard

/** What a touch asks the keyboard to do. */
sealed interface TouchOutput {
    /** Run the key's action: on release for most keys, on touch-down for shift and delete. */
    data class Commit(val action: KeyAction) : TouchOutput

    /** ⌫ went down: delete once now and start repeating. */
    data object StartDeleteRepeat : TouchOutput
    data object StopDeleteRepeat : TouchOutput

    /** Space bar held and dragged: move the cursor by this many characters. */
    data class MoveCursor(val steps: Int) : TouchOutput

    /** A key that does something else when held: the keyboard list, the settings. */
    data class LongPress(val action: KeyAction) : TouchOutput
}

/**
 * Multi-touch key tracking. A key commits on release, like Apple's; when a second finger lands
 * before the first lifts (fast typing), the first key commits at that moment so letters keep
 * their order. Holding a key with variants opens them; sliding picks one.
 */
class KeyTouchTracker(
    private val alternatesFor: (LayoutKey) -> List<String>,
    private val cursorStepPx: Float,
) {
    class Touch(
        var frame: KeyFrame,
        val downX: Float,
        var done: Boolean = false,
        var alternates: List<String> = emptyList(),
        var selected: Int = 0,
        var popupLeft: Float = 0f,
        var alternateWidth: Float = 0f,
        var trackpadX: Float? = null,
    )

    private val touches = LinkedHashMap<Long, Touch>()

    /** Live touches, for drawing pressed keys and popups. */
    val active: Map<Long, Touch> get() = touches

    fun down(id: Long, frame: KeyFrame, x: Float): List<TouchOutput> {
        val out = ArrayList<TouchOutput>()
        for (other in touches.values) {
            if (!other.done && other.alternates.isEmpty() && other.trackpadX == null && commitsOnRollover(other.frame.key.action)) {
                out += TouchOutput.Commit(other.frame.key.action)
                other.done = true
            }
        }
        val touch = Touch(frame, x)
        touches[id] = touch
        when (frame.key.action) {
            KeyAction.Shift -> {
                out += TouchOutput.Commit(KeyAction.Shift)
                touch.done = true
            }
            KeyAction.Backspace -> {
                out += TouchOutput.StartDeleteRepeat
                touch.done = true
            }
            else -> Unit
        }
        return out
    }

    fun move(id: Long, frameUnder: KeyFrame?, x: Float): List<TouchOutput> {
        val touch = touches[id] ?: return emptyList()
        if (touch.alternates.isNotEmpty()) {
            touch.selected = cellAt(touch, x)
            return emptyList()
        }
        touch.trackpadX?.let { anchor ->
            val steps = ((x - anchor) / cursorStepPx).toInt()
            if (steps == 0) return emptyList()
            touch.trackpadX = anchor + steps * cursorStepPx
            return listOf(TouchOutput.MoveCursor(steps))
        }
        if (!touch.done && frameUnder != null && frameUnder != touch.frame && retargets(frameUnder.key.action)) {
            touch.frame = frameUnder
        }
        return emptyList()
    }

    /**
     * The finger stayed on the key long enough. [popupPlacement] says where the variants popup
     * for that many values starts and how wide one cell is.
     */
    fun longPress(id: Long, popupPlacement: (frame: KeyFrame, count: Int) -> Pair<Float, Float>): List<TouchOutput> {
        val touch = touches[id] ?: return emptyList()
        if (touch.done) return emptyList()
        val action = touch.frame.key.action
        when {
            action is KeyAction.Text -> {
                val values = alternatesFor(touch.frame.key)
                if (values.size > 1) {
                    val (left, cell) = popupPlacement(touch.frame, values.size)
                    touch.alternates = values
                    touch.popupLeft = left
                    touch.alternateWidth = cell
                    touch.selected = cellAt(touch, touch.downX)
                }
            }
            action == KeyAction.Space -> touch.trackpadX = touch.downX
            action == KeyAction.Language || action == KeyAction.Microphone -> {
                touch.done = true
                return listOf(TouchOutput.LongPress(action))
            }
        }
        return emptyList()
    }

    fun up(id: Long): List<TouchOutput> {
        val touch = touches.remove(id) ?: return emptyList()
        if (touch.frame.key.action == KeyAction.Backspace) return listOf(TouchOutput.StopDeleteRepeat)
        if (touch.done || touch.trackpadX != null) return emptyList()
        if (touch.alternates.isNotEmpty()) return listOf(TouchOutput.Commit(KeyAction.Text(touch.alternates[touch.selected])))
        return listOf(TouchOutput.Commit(touch.frame.key.action))
    }

    fun cancelAll(): List<TouchOutput> {
        val deleting = touches.values.any { it.frame.key.action == KeyAction.Backspace }
        touches.clear()
        return if (deleting) listOf(TouchOutput.StopDeleteRepeat) else emptyList()
    }

    private fun cellAt(touch: Touch, x: Float): Int =
        ((x - touch.popupLeft) / touch.alternateWidth).toInt().coerceIn(0, touch.alternates.lastIndex)

    private fun commitsOnRollover(action: KeyAction) = action is KeyAction.Text || action == KeyAction.Space

    /** A finger sliding off a letter types the key under it on release; system keys are not picked up that way. */
    private fun retargets(action: KeyAction) = action is KeyAction.Text || action == KeyAction.Space
}
