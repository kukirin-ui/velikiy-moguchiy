package io.github.zigansh1n.velikiymoguchiy.dictation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TranscriptFormatterTest {
    @Test
    fun cleansModelWrappers() {
        assertEquals("Привет.", TranscriptFormatter.cleaned("  «Привет.»  "))
        assertEquals("«a» и «b»", TranscriptFormatter.cleaned("«a» и «b»"))
        assertEquals("Hi", TranscriptFormatter.cleaned("Transcript: \"Hi\""))
        assertEquals("text", TranscriptFormatter.cleaned("```\ntext\n```"))
    }

    @Test
    fun spaceBeforeInsertedText() {
        assertEquals(" Как дела?", TranscriptFormatter.textForInsertion("Как дела?", "Привет."))
        assertEquals("Как дела?", TranscriptFormatter.textForInsertion("Как дела?", "Привет. "))
        assertEquals(", да", TranscriptFormatter.textForInsertion(", да", "ну"))
        assertEquals("да", TranscriptFormatter.textForInsertion("да", "("))
        assertEquals("да", TranscriptFormatter.textForInsertion("да", null))
    }

    @Test
    fun silence() {
        assertTrue(TranscriptFormatter.isSilent(" ... "))
        assertFalse(TranscriptFormatter.isSilent("да"))
    }

    @Test
    fun speechLevel() {
        val silence = ByteArray(Pcm16.CHUNK_BYTES)
        assertFalse(Pcm16.containsLikelySpeech(silence))
        val loud = ByteArray(Pcm16.CHUNK_BYTES) { if (it % 2 == 1) 0x20 else 0 }
        assertTrue(Pcm16.containsLikelySpeech(loud))
    }
}
