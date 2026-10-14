package io.github.zigansh1n.velikiymoguchiy.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyTouchTrackerTest {
    private val state = KeyboardState(LayoutLanguage.RUSSIAN)
    private val frames = KeyboardGeometry.layout(
        state.layout(InputKind.STANDARD),
        402f,
        KeyboardGeometry.Metrics(43f, 11f, 0f, 0f),
    )
    private val tracker = KeyTouchTracker({ key -> state.alternates((key.action as KeyAction.Text).value) }, cursorStepPx = 10f)

    private fun frame(action: KeyAction) = frames.first { it.key.action == action }
    private fun text(value: String) = frame(KeyAction.Text(value))

    @Test
    fun keyCommitsOnRelease() {
        assertTrue(tracker.down(1, text("к"), text("к").centerX).isEmpty())
        assertEquals(listOf(TouchOutput.Commit(KeyAction.Text("к"))), tracker.up(1))
    }

    @Test
    fun secondFingerCommitsTheFirstKeyFirst() {
        tracker.down(1, text("п"), 0f)
        assertEquals(listOf(TouchOutput.Commit(KeyAction.Text("п"))), tracker.down(2, text("р"), 0f))
        assertTrue(tracker.up(1).isEmpty())
        assertEquals(listOf(TouchOutput.Commit(KeyAction.Text("р"))), tracker.up(2))
    }

    @Test
    fun slidingTypesTheKeyUnderTheFinger() {
        tracker.down(1, text("в"), 0f)
        tracker.move(1, text("а"), 0f)
        assertEquals(listOf(TouchOutput.Commit(KeyAction.Text("а"))), tracker.up(1))
    }

    @Test
    fun holdingOpensVariants() {
        val e = text("е")
        tracker.down(1, e, e.centerX)
        tracker.longPress(1) { f, _ -> f.left to 30f }
        assertEquals(listOf("е", "ё"), tracker.active.getValue(1).alternates)
        tracker.move(1, null, e.left + 45f)
        assertEquals(listOf(TouchOutput.Commit(KeyAction.Text("ё"))), tracker.up(1))
    }

    @Test
    fun shiftAndDeleteActOnTouchDown() {
        assertEquals(listOf(TouchOutput.Commit(KeyAction.Shift)), tracker.down(1, frame(KeyAction.Shift), 0f))
        assertTrue(tracker.up(1).isEmpty())
        assertEquals(listOf(TouchOutput.StartDeleteRepeat), tracker.down(2, frame(KeyAction.Backspace), 0f))
        assertEquals(listOf(TouchOutput.StopDeleteRepeat), tracker.up(2))
    }

    @Test
    fun heldSpaceMovesTheCursor() {
        val space = frame(KeyAction.Space)
        tracker.down(1, space, 100f)
        tracker.longPress(1) { f, _ -> f.left to 30f }
        assertEquals(listOf(TouchOutput.MoveCursor(-2)), tracker.move(1, space, 75f))
        assertEquals(listOf(TouchOutput.MoveCursor(1)), tracker.move(1, space, 92f))
        assertTrue(tracker.up(1).isEmpty())
    }

    @Test
    fun holdingTheLanguageKeyOpensThePicker() {
        tracker.down(1, frame(KeyAction.Language), 0f)
        assertEquals(listOf(TouchOutput.LongPress(KeyAction.Language)), tracker.longPress(1) { f, _ -> f.left to 30f })
        assertTrue(tracker.up(1).isEmpty())
    }
}
