package io.github.zigansh1n.velikiymoguchiy.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyboardGeometryTest {
    private val metrics = KeyboardGeometry.Metrics(rowHeight = 43f, rowGap = 11f, topPadding = 0f, bottomPadding = 0f)
    private val width = 402f

    @Test
    fun russianRowsFillTheWidth() {
        val frames = KeyboardGeometry.layout(KeyboardState(LayoutLanguage.RUSSIAN).layout(InputKind.STANDARD), width, metrics)
        val top = frames.filter { it.row == 0 }
        assertEquals(KeyMetrics.SIDE_MARGIN, top.first().left, 0.01f)
        assertEquals(width - KeyMetrics.SIDE_MARGIN, top.last().right, 0.01f)
        val third = frames.filter { it.row == 2 }
        assertEquals(top.first().width, third.first().width, 0.01f)
    }

    @Test
    fun englishShiftPinnedAndMiddleCentered() {
        val frames = KeyboardGeometry.layout(KeyboardState(LayoutLanguage.ENGLISH).layout(InputKind.STANDARD), width, metrics)
        val third = frames.filter { it.row == 2 }
        assertEquals(KeyMetrics.SIDE_MARGIN, third.first().left, 0.01f)
        assertEquals(width - KeyMetrics.SIDE_MARGIN, third.last().right, 0.01f)
        val z = third[1]
        val m = third[7]
        assertEquals(width / 2, (z.left + m.right) / 2, 0.01f)
        val second = frames.filter { it.row == 1 }
        assertEquals(width / 2, (second.first().left + second.last().right) / 2, 0.01f)
    }

    @Test
    fun spaceTakesTheRestOfTheBottomRow() {
        val frames = KeyboardGeometry.layout(KeyboardState(LayoutLanguage.RUSSIAN).layout(InputKind.STANDARD), width, metrics)
        val bottom = frames.filter { it.row == 3 }
        assertEquals(width - KeyMetrics.SIDE_MARGIN, bottom.last().right, 0.01f)
        val space = bottom.first { it.key.action == KeyAction.Space }
        assertTrue(space.width > 120f)
    }

    @Test
    fun touchesInGapsLandOnTheNearestKey() {
        val frames = KeyboardGeometry.layout(KeyboardState(LayoutLanguage.RUSSIAN).layout(InputKind.STANDARD), width, metrics)
        val first = frames[0]
        val second = frames[1]
        val gapX = (first.right + second.left) / 2 - 0.5f
        assertEquals(KeyAction.Text("й"), KeyboardGeometry.hit(frames, gapX, 10f)?.key?.action)
        assertEquals(KeyAction.Text("ф"), KeyboardGeometry.hit(frames, first.centerX, 43f + 6f)?.key?.action)
        assertEquals(KeyAction.Text("й"), KeyboardGeometry.hit(frames, 0f, -20f)?.key?.action)
        assertEquals(KeyAction.Page, KeyboardGeometry.hit(frames, 0f, 1000f)?.key?.action)
    }

    @Test
    fun popupStaysOnScreen() {
        val frames = KeyboardGeometry.layout(KeyboardState(LayoutLanguage.ENGLISH).layout(InputKind.STANDARD), width, metrics)
        val p = frames.first { it.key.action == KeyAction.Text("p") }
        val left = alternatesPopupLeft(p, 6, 34f, width)
        assertTrue(left + 6 * 34f <= width)
        val a = frames.first { it.key.action == KeyAction.Text("a") }
        assertEquals(a.left, alternatesPopupLeft(a, 3, 34f, width), 0.01f)
    }
}
