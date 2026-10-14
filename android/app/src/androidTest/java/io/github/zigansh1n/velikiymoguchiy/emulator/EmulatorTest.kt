package io.github.zigansh1n.velikiymoguchiy.emulator

import android.Manifest
import android.content.ComponentName
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import androidx.test.ext.junit.rules.ActivityScenarioRule
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import io.github.zigansh1n.velikiymoguchiy.ime.KeyboardService
import io.github.zigansh1n.velikiymoguchiy.keyboard.LayoutLanguage
import io.github.zigansh1n.velikiymoguchiy.settings.AppSettings
import io.github.zigansh1n.velikiymoguchiy.testing.TextFieldActivity
import org.junit.Assert.assertEquals
import org.junit.BeforeClass
import org.junit.Rule
import org.junit.rules.RuleChain
import org.junit.rules.TestWatcher
import org.junit.runner.Description
import java.io.ByteArrayOutputStream

/**
 * A test on a real Android system: our keyboard is the selected input method, the microphone is
 * allowed, and [TextFieldActivity] shows one focused text field.
 */
abstract class EmulatorTest {
    private val activity = ActivityScenarioRule(TextFieldActivity::class.java)

    // The failure capture sits inside the activity rule, so the screenshot still shows the field.
    @get:Rule
    val rules: RuleChain = RuleChain
        .outerRule(GrantPermissionRule.grant(Manifest.permission.RECORD_AUDIO))
        .around(activity)
        .around(CaptureOnFailure())

    protected val keyboard by lazy { KeyboardDriver(activity.scenario) }

    companion object {
        val instrumentation get() = InstrumentationRegistry.getInstrumentation()
        val targetContext get() = instrumentation.targetContext

        @BeforeClass
        @JvmStatic
        fun selectKeyboard() {
            val device = UiDevice.getInstance(instrumentation)
            val component = ComponentName(targetContext, KeyboardService::class.java)
            val id = component.flattenToShortString()
            // Right after connectedDebugAndroidTest reinstalls the app the system may not list it yet.
            waitFor("$id among the input methods", timeoutMillis = 60_000) {
                device.executeShellCommand("ime list -a -s").lines().any { it.trim() == id }
            }
            device.executeShellCommand("settings put global hide_error_dialogs 1")
            // A dialog that is already up ("Pixel Launcher isn't responding") would cover the field.
            device.findObject(By.res("android", "aerr_wait"))?.click()
            device.executeShellCommand("ime enable $id")
            device.executeShellCommand("ime set $id")
            // An emulator with a hardware keyboard hides on-screen keyboards unless this is on.
            device.executeShellCommand("settings put secure show_ime_with_hard_keyboard 1")
            val current = Settings.Secure.getString(targetContext.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
            assertEquals(component, ComponentName.unflattenFromString(current.orEmpty()))
            AppSettings(targetContext).language = LayoutLanguage.RUSSIAN
        }
    }
}

/** Polls [condition] every 50 ms; fails with [what] after [timeoutMillis]. */
fun waitFor(what: String, timeoutMillis: Long = 5_000, condition: () -> Boolean) {
    val deadline = SystemClock.uptimeMillis() + timeoutMillis
    while (!condition()) {
        if (SystemClock.uptimeMillis() > deadline) throw AssertionError("Timed out after $timeoutMillis ms: $what")
        Thread.sleep(50)
    }
}

/** Saves a screenshot where the CI script pulls it from, and logs the window hierarchy. */
class CaptureOnFailure : TestWatcher() {
    override fun failed(e: Throwable?, description: Description) {
        val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        val name = "${description.testClass.simpleName}-${description.methodName}"
        runCatching {
            device.executeShellCommand("mkdir -p $SCREENSHOTS")
            device.executeShellCommand("screencap -p $SCREENSHOTS/$name.png")
        }
        runCatching {
            val xml = ByteArrayOutputStream().also { device.dumpWindowHierarchy(it) }.toString("UTF-8")
            xml.chunked(3_000).forEach { Log.e(TAG, "$name hierarchy: $it") }
        }
    }

    companion object {
        /** Shell-owned, so it outlives the uninstall at the end of connectedDebugAndroidTest. */
        const val SCREENSHOTS = "/data/local/tmp/vm-screenshots"
        const val TAG = "EmulatorTest"
    }
}
