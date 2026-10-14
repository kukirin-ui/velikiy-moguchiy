package io.github.zigansh1n.velikiymoguchiy.emulator

import android.graphics.Rect
import android.widget.EditText
import androidx.compose.ui.unit.Density
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import io.github.zigansh1n.velikiymoguchiy.ime.KEY_SURFACE_TAG
import io.github.zigansh1n.velikiymoguchiy.ime.keySurfaceMetrics
import io.github.zigansh1n.velikiymoguchiy.keyboard.InputKind
import io.github.zigansh1n.velikiymoguchiy.keyboard.KeyAction
import io.github.zigansh1n.velikiymoguchiy.keyboard.KeyFrame
import io.github.zigansh1n.velikiymoguchiy.keyboard.KeyboardGeometry
import io.github.zigansh1n.velikiymoguchiy.keyboard.KeyboardState
import io.github.zigansh1n.velikiymoguchiy.keyboard.LayoutLanguage
import io.github.zigansh1n.velikiymoguchiy.testing.TextFieldActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue

/**
 * Presses keys of our keyboard with injected touches, like a finger. The keys are drawn on one
 * canvas, so their places come from the same [KeyboardGeometry] the keyboard draws with, laid
 * over the on-screen bounds of the key surface.
 */
class KeyboardDriver(private val scenario: ActivityScenario<TextFieldActivity>) {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    val device: UiDevice = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())

    private var surface: Rect? = null
    private var frames: List<KeyFrame> = emptyList()

    fun fieldText(): String {
        var text = ""
        scenario.onActivity { text = it.field.text.toString() }
        return text
    }

    /** Waits for the keyboard under the focused field, tapping the field if it does not come up. */
    fun show() {
        assertTrue("text field", device.wait(Until.hasObject(By.clazz(EditText::class.java)), 10_000))
        if (!device.wait(Until.hasObject(By.res(KEY_SURFACE_TAG)), 5_000)) {
            device.findObject(By.clazz(EditText::class.java)).click()
        }
        val keys = device.wait(Until.findObject(By.res(KEY_SURFACE_TAG)), 15_000)
            ?: throw AssertionError("The keyboard did not appear under the text field")
        val bounds = keys.visibleBounds
        val configuration = context.resources.configuration
        val metrics = keySurfaceMetrics(
            Density(context),
            landscape = configuration.screenWidthDp > configuration.screenHeightDp,
            digitPad = false,
        )
        val rows = KeyboardState(LayoutLanguage.RUSSIAN).layout(InputKind.STANDARD)
        assertEquals(
            "key surface height",
            KeyboardGeometry.height(rows.size, metrics),
            bounds.height().toFloat(),
            3f,
        )
        surface = bounds
        frames = KeyboardGeometry.layout(rows, bounds.width().toFloat(), metrics)
    }

    fun tap(action: KeyAction) {
        val bounds = surface ?: throw IllegalStateException("show() first")
        val frame = frames.firstOrNull { matches(it.key.action, action) }
            ?: throw AssertionError("No key $action on the Russian letters page")
        val x = bounds.left + frame.centerX
        val y = bounds.top + (frame.top + frame.bottom) / 2
        assertTrue("tap at $x, $y", device.click(x.toInt(), y.toInt()))
    }

    /** Taps a key and waits for the field to change. */
    fun press(action: KeyAction) {
        val before = fieldText()
        tap(action)
        waitFor("the field to change after $action (was \"$before\")") { fieldText() != before }
    }

    /** Letters are matched without case: Shift changes labels, not places. */
    fun type(text: String) {
        for (char in text) press(if (char == ' ') KeyAction.Space else KeyAction.Text(char.toString()))
    }

    private fun matches(key: KeyAction, wanted: KeyAction): Boolean =
        if (key is KeyAction.Text && wanted is KeyAction.Text) {
            key.value.equals(wanted.value, ignoreCase = true)
        } else {
            key == wanted
        }
}
