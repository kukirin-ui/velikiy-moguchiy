package io.github.zigansh1n.velikiymoguchiy.ime

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.input.pointer.changedToDownIgnoreConsumed
import androidx.compose.ui.input.pointer.changedToUpIgnoreConsumed
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.zigansh1n.velikiymoguchiy.dictation.DictationProvider
import io.github.zigansh1n.velikiymoguchiy.dictation.DictationState
import io.github.zigansh1n.velikiymoguchiy.keyboard.Capitalization
import io.github.zigansh1n.velikiymoguchiy.keyboard.KeyAction
import io.github.zigansh1n.velikiymoguchiy.keyboard.KeyFrame
import io.github.zigansh1n.velikiymoguchiy.keyboard.KeyStyle
import io.github.zigansh1n.velikiymoguchiy.keyboard.KeyTouchTracker
import io.github.zigansh1n.velikiymoguchiy.keyboard.KeyboardGeometry
import io.github.zigansh1n.velikiymoguchiy.keyboard.KeyboardPage
import io.github.zigansh1n.velikiymoguchiy.keyboard.ReturnKind
import io.github.zigansh1n.velikiymoguchiy.keyboard.TouchOutput
import io.github.zigansh1n.velikiymoguchiy.keyboard.alternatesPopupLeft
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private const val LONG_PRESS_MILLIS = 400L
private val STRIP_HEIGHT = 44.dp

@Composable
fun KeyboardScreen(model: KeyboardModel, dictation: DictationState, actions: KeyboardActions) {
    val colors = if (isSystemInDarkTheme()) KeyboardColors.Dark else KeyboardColors.Light
    val showStrip = model.profile.allowsSuggestions || dictation != DictationState.Idle || model.pendingText != null
    Column(
        Modifier
            .fillMaxWidth()
            .background(colors.background)
            .navigationBarsPadding(),
    ) {
        if (showStrip) TopStrip(model, dictation, actions, colors)
        KeySurface(model, actions, colors, dimmed = dictation is DictationState.Listening || dictation is DictationState.Transcribing)
    }
}

@Composable
private fun TopStrip(model: KeyboardModel, dictation: DictationState, actions: KeyboardActions, colors: KeyboardColors) {
    Box(
        Modifier
            .fillMaxWidth()
            .height(STRIP_HEIGHT)
            .padding(horizontal = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        val pending = model.pendingText
        when {
            dictation is DictationState.Listening -> DictationStrip(
                text = dictation.preview.ifEmpty {
                    if (dictation.provider == DictationProvider.SYSTEM) "Слушаю (распознавание Android)…" else "Слушаю…"
                },
                level = dictation.level,
                colors = colors,
                actions = actions,
                showDone = true,
            )
            dictation is DictationState.Transcribing -> DictationStrip(
                text = "Распознаю… " + dictation.preview,
                level = 0f,
                colors = colors,
                actions = actions,
                showDone = false,
            )
            dictation is DictationState.Failed -> Row(verticalAlignment = Alignment.CenterVertically) {
                BasicText(
                    dictation.message,
                    Modifier.weight(1f),
                    style = TextStyle(color = colors.error, fontSize = 13.sp),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                if (dictation.needsSettings) StripButton("Настройки", colors) { actions.onOpenSettings() }
                StripButton("✕", colors) { actions.onDismissError() }
            }
            pending != null -> Row(verticalAlignment = Alignment.CenterVertically) {
                StripButton("Вставить", colors, accent = true) { actions.onInsertPending() }
                BasicText(
                    pending,
                    Modifier
                        .weight(1f)
                        .padding(horizontal = 8.dp),
                    style = TextStyle(color = colors.label, fontSize = 14.sp),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                StripButton("✕", colors) { actions.onDiscardPending() }
            }
            else -> SuggestionRow(model, actions, colors)
        }
    }
}

@Composable
private fun DictationStrip(text: String, level: Float, colors: KeyboardColors, actions: KeyboardActions, showDone: Boolean) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        StripButton("✕", colors) { actions.onDictationCancel() }
        Box(
            Modifier
                .padding(horizontal = 8.dp)
                .size(12.dp)
                .scale(0.6f + level * 0.8f)
                .clip(CircleShape)
                .background(colors.error),
        )
        BasicText(
            // The newest words matter: show the end of a long preview.
            if (text.length > 80) "…" + text.takeLast(80) else text,
            Modifier.weight(1f),
            style = TextStyle(color = colors.label, fontSize = 14.sp),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (showDone) StripButton("Готово", colors, accent = true) { actions.onDictationDone() }
    }
}

@Composable
private fun StripButton(title: String, colors: KeyboardColors, accent: Boolean = false, onClick: () -> Unit) {
    Box(
        Modifier
            .padding(horizontal = 2.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(if (accent) colors.accent else colors.systemKey)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 7.dp),
    ) {
        BasicText(title, style = TextStyle(color = if (accent) colors.onAccent else colors.label, fontSize = 14.sp))
    }
}

@Composable
private fun SuggestionRow(model: KeyboardModel, actions: KeyboardActions, colors: KeyboardColors) {
    val suggestions = model.suggestions
    Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
        for (index in 0 until 3) {
            if (index > 0) {
                Box(
                    Modifier
                        .width(1.dp)
                        .height(22.dp)
                        .background(colors.divider),
                )
            }
            val suggestion = suggestions.getOrNull(index)
            Box(
                Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .padding(vertical = 5.dp, horizontal = 3.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (suggestion?.isAutocorrection == true) colors.inputKey else colors.background)
                    .then(if (suggestion != null) Modifier.clickable { actions.onSuggestion(suggestion) } else Modifier),
                contentAlignment = Alignment.Center,
            ) {
                if (suggestion != null) {
                    BasicText(
                        suggestion.display,
                        style = TextStyle(color = colors.label, fontSize = 16.sp, textAlign = TextAlign.Center),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun KeySurface(model: KeyboardModel, actions: KeyboardActions, colors: KeyboardColors, dimmed: Boolean) {
    val density = LocalDensity.current
    val landscape = LocalConfiguration.current.screenWidthDp > LocalConfiguration.current.screenHeightDp
    val digitPad = model.profile.kind.isDigitPad
    val metrics = keySurfaceMetrics(density, landscape, digitPad)
    val rows = model.rows
    val height = with(density) { KeyboardGeometry.height(rows.size, metrics).toDp() }
    val textMeasurer = rememberTextMeasurer(cacheSize = 64)
    val currentActions by rememberUpdatedState(actions)
    val scope = rememberCoroutineScope()

    BoxWithConstraints(
        Modifier
            .fillMaxWidth()
            .height(height)
            // The keys are drawn, not views: the emulator tests find the surface by this tag.
            .semantics { testTagsAsResourceId = true }
            .testTag(KEY_SURFACE_TAG),
    ) {
        val width = constraints.maxWidth.toFloat()
        val frames = remember(rows, width, metrics) { KeyboardGeometry.layout(rows, width, metrics) }
        val currentFrames by rememberUpdatedState(frames)
        var touchVersion by remember { mutableIntStateOf(0) }
        val cellWidth = with(density) { 34.dp.toPx() }
        val cursorStep = with(density) { 12.dp.toPx() }
        val tracker = remember { KeyTouchTracker(alternatesFor = { currentActions.alternates(it) }, cursorStepPx = cursorStep) }
        val longPressJobs = remember { HashMap<Long, Job>() }

        fun dispatch(outputs: List<TouchOutput>) {
            for (output in outputs) {
                when (output) {
                    is TouchOutput.Commit -> currentActions.onKey(output.action)
                    TouchOutput.StartDeleteRepeat -> currentActions.onDeleteStart()
                    TouchOutput.StopDeleteRepeat -> currentActions.onDeleteStop()
                    is TouchOutput.MoveCursor -> currentActions.onMoveCursor(output.steps)
                    is TouchOutput.LongPress -> currentActions.onLongPress(output.action)
                }
            }
        }

        Canvas(
            Modifier
                .fillMaxSize()
                .pointerInput(width) {
                    try {
                        awaitPointerEventScope {
                            while (true) {
                                val event = awaitPointerEvent()
                                for (change in event.changes) {
                                    val id = change.id.value
                                    val x = change.position.x
                                    val y = change.position.y
                                    when {
                                        change.changedToDownIgnoreConsumed() -> {
                                            val frame = KeyboardGeometry.hit(currentFrames, x, y) ?: continue
                                            currentActions.onKeyDown(frame.key)
                                            dispatch(tracker.down(id, frame, x))
                                            longPressJobs[id] = scope.launch {
                                                delay(LONG_PRESS_MILLIS)
                                                dispatch(
                                                    tracker.longPress(id) { f, count ->
                                                        alternatesPopupLeft(f, count, cellWidth, width) to cellWidth
                                                    },
                                                )
                                                touchVersion++
                                            }
                                        }
                                        change.changedToUpIgnoreConsumed() -> {
                                            longPressJobs.remove(id)?.cancel()
                                            dispatch(tracker.up(id))
                                        }
                                        change.positionChanged() -> {
                                            val before = tracker.active[id]?.frame
                                            dispatch(tracker.move(id, KeyboardGeometry.hit(currentFrames, x, y), x))
                                            if (tracker.active[id]?.frame != before) longPressJobs.remove(id)?.cancel()
                                        }
                                    }
                                    change.consume()
                                }
                                touchVersion++
                            }
                        }
                    } finally {
                        longPressJobs.values.forEach { it.cancel() }
                        longPressJobs.clear()
                        dispatch(tracker.cancelAll())
                    }
                },
        ) {
            // Reading the counter redraws the surface after every touch event.
            check(touchVersion >= 0)
            val pressed = tracker.active.values
            val pressedFrames = pressed.map { it.frame }.toSet()
            val corner = CornerRadius(7.dp.toPx())
            val shadowOffset = 1.dp.toPx()
            val alpha = if (dimmed) 0.45f else 1f
            for (frame in frames) {
                if (frame.key.action == KeyAction.Blank) continue
                val isPressed = frame in pressedFrames
                val style = keyStyle(frame, model)
                val fill = when {
                    isPressed && frame.key.style == KeyStyle.SYSTEM -> colors.inputKey
                    isPressed && digitPad -> colors.systemKey
                    style == KeyLook.ACCENT -> colors.accent
                    style == KeyLook.ACTIVE -> colors.inputKey
                    frame.key.style == KeyStyle.SYSTEM -> colors.systemKey
                    else -> colors.inputKey
                }
                drawRoundRect(colors.shadow, Offset(frame.left, frame.top + shadowOffset), Size(frame.width, frame.height), corner, alpha = alpha)
                drawRoundRect(fill, Offset(frame.left, frame.top), Size(frame.width, frame.height), corner, alpha = alpha)
                drawKeyLabel(frame, model, colors, textMeasurer, style, alpha)
            }
            for (touch in pressed) {
                val frame = touch.frame
                val action = frame.key.action
                when {
                    touch.alternates.isNotEmpty() -> drawAlternates(touch, colors, textMeasurer)
                    action is KeyAction.Text && frame.key.style == KeyStyle.INPUT && !digitPad && !touch.done ->
                        drawPreview(frame, action.value, colors, textMeasurer)
                }
            }
        }
    }
}

internal const val KEY_SURFACE_TAG = "keyboard_keys"

/** Row sizes of the key surface in pixels. */
internal fun keySurfaceMetrics(density: Density, landscape: Boolean, digitPad: Boolean): KeyboardGeometry.Metrics {
    val rowHeight: Dp = when {
        landscape -> 36.dp
        digitPad -> 50.dp
        else -> 46.dp
    }
    val rowGap: Dp = if (digitPad) 6.dp else if (landscape) 7.dp else 11.dp
    return with(density) {
        KeyboardGeometry.Metrics(rowHeight.toPx(), rowGap.toPx(), topPadding = 6.dp.toPx(), bottomPadding = 4.dp.toPx())
    }
}

private enum class KeyLook { NORMAL, ACTIVE, ACCENT }

private fun keyStyle(frame: KeyFrame, model: KeyboardModel): KeyLook = when (frame.key.action) {
    KeyAction.Shift -> if (model.page == KeyboardPage.LETTERS && model.capitalization != Capitalization.LOWERCASE) KeyLook.ACTIVE else KeyLook.NORMAL
    KeyAction.Return -> if (model.profile.returnKind != ReturnKind.NEWLINE) KeyLook.ACCENT else KeyLook.NORMAL
    else -> KeyLook.NORMAL
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawKeyLabel(
    frame: KeyFrame,
    model: KeyboardModel,
    colors: KeyboardColors,
    measurer: androidx.compose.ui.text.TextMeasurer,
    look: KeyLook,
    alpha: Float,
) {
    val center = Offset(frame.centerX, (frame.top + frame.bottom) / 2)
    val icon = minOf(frame.height * 0.5f, frame.width * 0.6f)
    val labelColor = (if (look == KeyLook.ACCENT) colors.onAccent else colors.label).copy(alpha = alpha)
    fun text(value: String, sizeSp: Float, color: androidx.compose.ui.graphics.Color = labelColor, dy: Float = 0f) {
        val layout = measurer.measure(value, TextStyle(color = color, fontSize = sizeSp.sp))
        drawText(layout, topLeft = Offset(center.x - layout.size.width / 2f, center.y - layout.size.height / 2f + dy))
    }
    when (val action = frame.key.action) {
        is KeyAction.Text -> {
            val letter = action.value.length == 1 && action.value[0].isLetter()
            val size = when {
                frame.key.subtitle != null || model.profile.kind.isDigitPad -> 24f
                action.value.length > 1 -> 16f
                letter -> 22f
                else -> 21f
            }
            val subtitle = frame.key.subtitle
            if (subtitle != null) {
                text(action.value, size, dy = -frame.height * 0.1f)
                text(subtitle, 9f, colors.secondaryLabel.copy(alpha = alpha), dy = frame.height * 0.28f)
            } else {
                text(action.value, size, dy = if (letter) -frame.height * 0.03f else 0f)
            }
        }
        KeyAction.Shift -> when (model.page) {
            KeyboardPage.LETTERS -> KeyIcons.shift(
                this, center, icon, labelColor,
                when (model.capitalization) {
                    Capitalization.LOWERCASE -> ShiftLook.OFF
                    Capitalization.SHIFTED -> ShiftLook.ON
                    Capitalization.CAPS_LOCK -> ShiftLook.LOCKED
                },
            )
            KeyboardPage.NUMBERS -> text("#+=", 16f)
            KeyboardPage.SYMBOLS -> text("123", 16f)
        }
        KeyAction.Backspace -> KeyIcons.backspace(this, center, icon, labelColor)
        KeyAction.Page -> text(if (model.page == KeyboardPage.LETTERS) "123" else model.language.pageToggleTitle, 16f)
        KeyAction.Language -> KeyIcons.globe(this, center, icon, labelColor)
        KeyAction.Microphone -> KeyIcons.microphone(this, center, icon, labelColor)
        KeyAction.Space -> if (!model.profile.kind.isDigitPad) text(model.language.spaceTitle, 14f, colors.secondaryLabel.copy(alpha = alpha)) else text("␣", 18f)
        KeyAction.Return -> KeyIcons.returnKey(this, center, icon * 0.9f, labelColor, model.profile.returnKind)
        KeyAction.Blank -> Unit
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawPreview(
    frame: KeyFrame,
    value: String,
    colors: KeyboardColors,
    measurer: androidx.compose.ui.text.TextMeasurer,
) {
    val width = frame.width + 12.dp.toPx()
    val height = frame.height * 1.05f
    val left = (frame.centerX - width / 2).coerceIn(0f, size.width - width)
    val top = frame.top - height - 4.dp.toPx()
    drawRoundRect(colors.shadow, Offset(left, top + 1.dp.toPx()), Size(width, height), CornerRadius(9.dp.toPx()))
    drawRoundRect(colors.popup, Offset(left, top), Size(width, height), CornerRadius(9.dp.toPx()))
    val layout = measurer.measure(value, TextStyle(color = colors.label, fontSize = 30.sp))
    drawText(layout, topLeft = Offset(left + (width - layout.size.width) / 2, top + (height - layout.size.height) / 2))
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawAlternates(
    touch: KeyTouchTracker.Touch,
    colors: KeyboardColors,
    measurer: androidx.compose.ui.text.TextMeasurer,
) {
    val frame = touch.frame
    val cell = touch.alternateWidth
    val height = frame.height * 1.05f
    val top = frame.top - height - 4.dp.toPx()
    val width = cell * touch.alternates.size
    drawRoundRect(colors.shadow, Offset(touch.popupLeft, top + 1.dp.toPx()), Size(width, height), CornerRadius(9.dp.toPx()))
    drawRoundRect(colors.popup, Offset(touch.popupLeft, top), Size(width, height), CornerRadius(9.dp.toPx()))
    touch.alternates.forEachIndexed { index, value ->
        val left = touch.popupLeft + index * cell
        val selected = index == touch.selected
        if (selected) {
            drawRoundRect(colors.accent, Offset(left + 2.dp.toPx(), top + 4.dp.toPx()), Size(cell - 4.dp.toPx(), height - 8.dp.toPx()), CornerRadius(6.dp.toPx()))
        }
        val layout = measurer.measure(
            value,
            TextStyle(color = if (selected) colors.onAccent else colors.label, fontSize = 22.sp, fontWeight = FontWeight.Normal),
        )
        drawText(layout, topLeft = Offset(left + (cell - layout.size.width) / 2, top + (height - layout.size.height) / 2))
    }
}
