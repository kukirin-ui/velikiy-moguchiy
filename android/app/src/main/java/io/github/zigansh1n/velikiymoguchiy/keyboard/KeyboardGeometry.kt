package io.github.zigansh1n.velikiymoguchiy.keyboard

import kotlin.math.abs

/** A key placed on the surface, in pixels. */
data class KeyFrame(
    val key: LayoutKey,
    val row: Int,
    val left: Float,
    val top: Float,
    val right: Float,
    val bottom: Float,
) {
    val width: Float get() = right - left
    val height: Float get() = bottom - top
    val centerX: Float get() = (left + right) / 2
}

/** Places layout rows on a surface of a given width, scaling Apple's point metrics to it. */
object KeyboardGeometry {
    data class Metrics(val rowHeight: Float, val rowGap: Float, val topPadding: Float, val bottomPadding: Float)

    fun height(rows: Int, metrics: Metrics): Float =
        if (rows == 0) 0f else metrics.topPadding + rows * metrics.rowHeight + (rows - 1) * metrics.rowGap + metrics.bottomPadding

    fun layout(rows: List<LayoutRow>, width: Float, metrics: Metrics): List<KeyFrame> {
        if (rows.isEmpty() || width <= 0f) return emptyList()
        val scale = width / KeyMetrics.REFERENCE_WIDTH
        val margin = KeyMetrics.SIDE_MARGIN * scale
        val gap = KeyMetrics.KEY_GAP * scale
        val inner = width - 2 * margin
        val columns = rows.first().keys.size.coerceAtLeast(1)
        val letterWidth = (inner - (columns - 1) * gap) / columns

        val frames = ArrayList<KeyFrame>()
        rows.forEachIndexed { rowIndex, row ->
            val top = metrics.topPadding + rowIndex * (metrics.rowHeight + metrics.rowGap)
            val bottom = top + metrics.rowHeight
            val lefts = when (row.arrangement) {
                RowArrangement.FILL -> fillRow(row, inner, gap, scale)
                RowArrangement.CENTERED -> centeredRow(row, inner, gap, scale, letterWidth)
            }
            row.keys.forEachIndexed { i, key ->
                val (left, keyWidth) = lefts[i]
                frames += KeyFrame(key, rowIndex, margin + left, top, margin + left + keyWidth, bottom)
            }
        }
        return frames
    }

    private fun fillRow(row: LayoutRow, inner: Float, gap: Float, scale: Float): List<Pair<Float, Float>> {
        val fixed = row.keys.sumOf { (it.fixedPoints ?: 0f).toDouble() }.toFloat() * scale
        val flexible = row.keys.count { it.fixedPoints == null }
        val rest = inner - fixed - (row.keys.size - 1) * gap
        val flexWidth = if (flexible > 0) maxOf(rest / flexible, 0f) else 0f
        var x = 0f
        return row.keys.map { key ->
            val w = key.fixedPoints?.let { it * scale } ?: flexWidth
            (x to w).also { x += w + gap }
        }
    }

    private fun centeredRow(row: LayoutRow, inner: Float, gap: Float, scale: Float, letterWidth: Float): List<Pair<Float, Float>> {
        val widths = row.keys.map { key -> key.fixedPoints?.let { it * scale } ?: letterWidth }
        val total = widths.sum() + (widths.size - 1) * gap
        val pinned = row.keys.size > 2 &&
            row.keys.first().style == KeyStyle.SYSTEM && row.keys.last().style == KeyStyle.SYSTEM &&
            total < inner
        if (!pinned) {
            var x = (inner - total) / 2
            return widths.map { w -> (x to w).also { x += w + gap } }
        }
        // Shift and delete stay at the edges; the keys between them are centered in the rest.
        val middle = widths.subList(1, widths.size - 1)
        val middleTotal = middle.sum() + (middle.size - 1) * gap
        val start = widths.first()
        val end = inner - widths.last()
        var x = start + (end - start - middleTotal) / 2
        val result = ArrayList<Pair<Float, Float>>()
        result += 0f to widths.first()
        middle.forEach { w -> result += x to w; x += w + gap }
        result += end to widths.last()
        return result
    }

    /**
     * The key for a touch: the row whose band (gaps split halfway) holds y, then the nearest key in
     * it, so touches in a gap still land on a key. Blank keys never receive touches.
     */
    fun hit(frames: List<KeyFrame>, x: Float, y: Float): KeyFrame? {
        if (frames.isEmpty()) return null
        val rows = frames.groupBy { it.row }.toSortedMap()
        val bands = rows.values.map { it.first().top to it.first().bottom }
        var rowIndex = bands.lastIndex
        for (i in 0 until bands.lastIndex) {
            val boundary = (bands[i].second + bands[i + 1].first) / 2
            if (y < boundary) {
                rowIndex = i
                break
            }
        }
        val row = rows.values.elementAt(rowIndex).filter { it.key.action != KeyAction.Blank }
        return row.minByOrNull { frame ->
            when {
                x < frame.left -> frame.left - x
                x > frame.right -> x - frame.right
                else -> 0f
            } + abs(x - frame.centerX) * 0.001f
        }
    }
}

/** Where the variants popup of a held key goes: from the key rightwards, or leftwards near the right edge. */
fun alternatesPopupLeft(frame: KeyFrame, count: Int, cellWidth: Float, surfaceWidth: Float): Float {
    val width = count * cellWidth
    val left = if (frame.left + width <= surfaceWidth) frame.left else frame.right - width
    return left.coerceIn(0f, maxOf(surfaceWidth - width, 0f))
}
