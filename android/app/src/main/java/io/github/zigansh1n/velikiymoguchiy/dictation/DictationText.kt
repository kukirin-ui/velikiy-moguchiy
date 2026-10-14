package io.github.zigansh1n.velikiymoguchiy.dictation

/** Language of a dictation: the active layout decides it. */
enum class DictationLanguage(val code: String, val localeTag: String) {
    RUSSIAN("ru", "ru-RU"),
    ENGLISH("en", "en-US"),
}

object TranscriptFormatter {
    fun cleaned(raw: String): String {
        var value = raw.trim()
        if (value.startsWith("```") && value.endsWith("```") && value.length >= 6) {
            value = value.substring(3, value.length - 3).trim()
        }
        for (prefix in listOf("Transcript:", "Transcription:")) {
            if (value.startsWith(prefix)) value = value.removePrefix(prefix).trim()
        }
        if (value.length >= 2 && value.first() == '"' && value.last() == '"') {
            value = value.substring(1, value.length - 1)
        }
        // The prompt example is written in guillemets; some answers echo them.
        if (value.length >= 2 && value.first() == '«' && value.last() == '»') {
            val inner = value.substring(1, value.length - 1)
            if ('«' !in inner && '»' !in inner) value = inner
        }
        return value.trim()
    }

    /** A space in front of the text when it would otherwise stick to the previous word. */
    fun textForInsertion(transcript: String, contextBefore: String?): String {
        val text = cleaned(transcript)
        val last = contextBefore?.lastOrNull() ?: return text
        val first = text.firstOrNull() ?: return text
        if (last.isWhitespace() || last in "([{—–-/" || first in ".,!?;:)]}") return text
        return " $text"
    }

    /** No speech at all: empty, whitespace or punctuation only. */
    fun isSilent(text: String): Boolean = text.none { it.isLetterOrDigit() }
}

object Pcm16 {
    const val SAMPLE_RATE = 16_000

    /** 100 ms of 16 kHz mono PCM16. */
    const val CHUNK_BYTES = SAMPLE_RATE / 10 * 2

    /** Level in dBFS of little-endian PCM16. */
    fun decibels(data: ByteArray, length: Int = data.size): Double {
        val samples = length / 2
        if (samples == 0) return -120.0
        var sum = 0.0
        for (i in 0 until samples) {
            val sample = ((data[2 * i].toInt() and 0xFF) or (data[2 * i + 1].toInt() shl 8)).toShort() / 32767.0
            sum += sample * sample
        }
        return 20 * kotlin.math.log10(maxOf(kotlin.math.sqrt(sum / samples), 1e-6))
    }

    /** The same -52 dB floor as the iOS app: quieter chunks count as silence. */
    fun containsLikelySpeech(data: ByteArray, length: Int = data.size): Boolean = decibels(data, length) > -52.0
}
