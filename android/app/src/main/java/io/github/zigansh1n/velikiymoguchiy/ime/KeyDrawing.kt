package io.github.zigansh1n.velikiymoguchiy.ime

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.graphics.drawscope.Stroke
import io.github.zigansh1n.velikiymoguchiy.keyboard.ReturnKind

/** Colors close to the iOS 26 keyboard, light and dark. */
data class KeyboardColors(
    val background: Color,
    val inputKey: Color,
    val systemKey: Color,
    val pressedKey: Color,
    val shadow: Color,
    val label: Color,
    val secondaryLabel: Color,
    val accent: Color,
    val onAccent: Color,
    val popup: Color,
    val divider: Color,
    val error: Color,
) {
    companion object {
        val Light = KeyboardColors(
            background = Color(0xFFD1D4DA),
            inputKey = Color(0xFFFFFFFF),
            systemKey = Color(0xFFABB1BB),
            pressedKey = Color(0xFFFFFFFF),
            shadow = Color(0x40000000),
            label = Color(0xFF000000),
            secondaryLabel = Color(0xFF6B6F76),
            accent = Color(0xFF007AFF),
            onAccent = Color(0xFFFFFFFF),
            popup = Color(0xFFFFFFFF),
            divider = Color(0x33000000),
            error = Color(0xFFC62828),
        )
        val Dark = KeyboardColors(
            background = Color(0xFF2B2B2D),
            inputKey = Color(0xFF6C6C6E),
            systemKey = Color(0xFF464648),
            pressedKey = Color(0xFF8E8E90),
            shadow = Color(0x66000000),
            label = Color(0xFFFFFFFF),
            secondaryLabel = Color(0xFFB0B0B4),
            accent = Color(0xFF0A84FF),
            onAccent = Color(0xFFFFFFFF),
            popup = Color(0xFF6C6C6E),
            divider = Color(0x33FFFFFF),
            error = Color(0xFFFF8A80),
        )
    }
}

enum class ShiftLook { OFF, ON, LOCKED }

/** Line icons drawn into a square of side [size] centered at [center]. */
object KeyIcons {
    private fun stroke(size: Float) = Stroke(width = size * 0.085f, cap = StrokeCap.Round, join = StrokeJoin.Round)

    fun shift(scope: DrawScope, center: Offset, size: Float, color: Color, look: ShiftLook) {
        val s = size / 2
        val path = Path().apply {
            moveTo(center.x, center.y - s * 0.9f)
            lineTo(center.x + s * 0.85f, center.y + s * 0.05f)
            lineTo(center.x + s * 0.4f, center.y + s * 0.05f)
            lineTo(center.x + s * 0.4f, center.y + s * 0.6f)
            lineTo(center.x - s * 0.4f, center.y + s * 0.6f)
            lineTo(center.x - s * 0.4f, center.y + s * 0.05f)
            lineTo(center.x - s * 0.85f, center.y + s * 0.05f)
            close()
        }
        scope.drawPath(path, color, style = if (look == ShiftLook.OFF) stroke(size) else Fill)
        if (look == ShiftLook.LOCKED) {
            scope.drawLine(color, Offset(center.x - s * 0.4f, center.y + s * 0.85f), Offset(center.x + s * 0.4f, center.y + s * 0.85f), size * 0.1f, StrokeCap.Round)
        }
    }

    fun backspace(scope: DrawScope, center: Offset, size: Float, color: Color) {
        val w = size * 0.55f
        val h = size * 0.38f
        val path = Path().apply {
            moveTo(center.x - w, center.y)
            lineTo(center.x - w * 0.45f, center.y - h)
            lineTo(center.x + w, center.y - h)
            lineTo(center.x + w, center.y + h)
            lineTo(center.x - w * 0.45f, center.y + h)
            close()
        }
        scope.drawPath(path, color, style = stroke(size))
        val c = Offset(center.x + w * 0.25f, center.y)
        val d = h * 0.45f
        scope.drawLine(color, c + Offset(-d, -d), c + Offset(d, d), size * 0.08f, StrokeCap.Round)
        scope.drawLine(color, c + Offset(-d, d), c + Offset(d, -d), size * 0.08f, StrokeCap.Round)
    }

    fun globe(scope: DrawScope, center: Offset, size: Float, color: Color) {
        val r = size * 0.42f
        val style = stroke(size * 0.8f)
        scope.drawCircle(color, r, center, style = style)
        scope.drawOval(color, Offset(center.x - r * 0.45f, center.y - r), Size(r * 0.9f, r * 2), style = style)
        scope.drawLine(color, Offset(center.x - r, center.y), Offset(center.x + r, center.y), style.width)
        scope.drawLine(color, Offset(center.x, center.y - r), Offset(center.x, center.y + r), style.width)
    }

    fun microphone(scope: DrawScope, center: Offset, size: Float, color: Color) {
        val w = size * 0.2f
        val top = center.y - size * 0.45f
        val bottom = center.y + size * 0.08f
        scope.drawRoundRect(
            color,
            topLeft = Offset(center.x - w, top),
            size = Size(w * 2, bottom - top),
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(w, w),
        )
        val arc = size * 0.33f
        scope.drawArc(
            color, 0f, 180f, false,
            topLeft = Offset(center.x - arc, center.y - arc * 0.75f),
            size = Size(arc * 2, arc * 1.75f),
            style = stroke(size),
        )
        scope.drawLine(color, Offset(center.x, center.y + arc), Offset(center.x, center.y + size * 0.48f), size * 0.085f, StrokeCap.Round)
    }

    fun returnKey(scope: DrawScope, center: Offset, size: Float, color: Color, kind: ReturnKind) {
        val s = size / 2
        val style = stroke(size)
        val path = Path()
        when (kind) {
            ReturnKind.NEWLINE -> {
                path.moveTo(center.x + s * 0.7f, center.y - s * 0.6f)
                path.lineTo(center.x + s * 0.7f, center.y + s * 0.2f)
                path.lineTo(center.x - s * 0.7f, center.y + s * 0.2f)
                path.moveTo(center.x - s * 0.3f, center.y - s * 0.2f)
                path.lineTo(center.x - s * 0.7f, center.y + s * 0.2f)
                path.lineTo(center.x - s * 0.3f, center.y + s * 0.6f)
            }
            ReturnKind.SEARCH -> {
                scope.drawCircle(color, s * 0.48f, Offset(center.x - s * 0.15f, center.y - s * 0.15f), style = style)
                path.moveTo(center.x + s * 0.2f, center.y + s * 0.2f)
                path.lineTo(center.x + s * 0.7f, center.y + s * 0.7f)
            }
            ReturnKind.GO, ReturnKind.NEXT -> {
                path.moveTo(center.x - s * 0.7f, center.y)
                path.lineTo(center.x + s * 0.7f, center.y)
                path.moveTo(center.x + s * 0.2f, center.y - s * 0.5f)
                path.lineTo(center.x + s * 0.7f, center.y)
                path.lineTo(center.x + s * 0.2f, center.y + s * 0.5f)
            }
            ReturnKind.PREVIOUS -> {
                path.moveTo(center.x + s * 0.7f, center.y)
                path.lineTo(center.x - s * 0.7f, center.y)
                path.moveTo(center.x - s * 0.2f, center.y - s * 0.5f)
                path.lineTo(center.x - s * 0.7f, center.y)
                path.lineTo(center.x - s * 0.2f, center.y + s * 0.5f)
            }
            ReturnKind.SEND -> {
                path.moveTo(center.x, center.y + s * 0.7f)
                path.lineTo(center.x, center.y - s * 0.7f)
                path.moveTo(center.x - s * 0.5f, center.y - s * 0.2f)
                path.lineTo(center.x, center.y - s * 0.7f)
                path.lineTo(center.x + s * 0.5f, center.y - s * 0.2f)
            }
            ReturnKind.DONE -> {
                path.moveTo(center.x - s * 0.65f, center.y)
                path.lineTo(center.x - s * 0.15f, center.y + s * 0.5f)
                path.lineTo(center.x + s * 0.7f, center.y - s * 0.5f)
            }
        }
        scope.drawPath(path, color, style = style)
    }
}
