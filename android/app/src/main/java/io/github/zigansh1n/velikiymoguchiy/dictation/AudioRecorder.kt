package io.github.zigansh1n.velikiymoguchiy.dictation

import android.Manifest
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import androidx.annotation.RequiresPermission

/** Records 16 kHz mono PCM16 in 100 ms chunks on its own thread. */
class AudioRecorder(
    private val onChunk: (ByteArray) -> Unit,
    /** 0..1, about ten times a second. */
    private val onLevel: (Float) -> Unit,
) {
    private var record: AudioRecord? = null
    private var thread: Thread? = null
    @Volatile private var running = false

    @RequiresPermission(Manifest.permission.RECORD_AUDIO)
    fun start() {
        val minimum = AudioRecord.getMinBufferSize(Pcm16.SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minimum <= 0) throw DictationException.Microphone("телефон не записывает 16 кГц.")
        val record = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                Pcm16.SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minimum, Pcm16.CHUNK_BYTES * 4),
            )
        } catch (error: SecurityException) {
            throw DictationException.NoPermission()
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            throw DictationException.Microphone("его занимает другое приложение.")
        }
        record.startRecording()
        if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            record.release()
            throw DictationException.Microphone("запись не началась.")
        }
        this.record = record
        running = true
        thread = Thread({ loop(record) }, "dictation-audio").apply { start() }
    }

    private fun loop(record: AudioRecord) {
        while (running) {
            val chunk = ByteArray(Pcm16.CHUNK_BYTES)
            var filled = 0
            while (running && filled < chunk.size) {
                val read = record.read(chunk, filled, chunk.size - filled)
                if (read <= 0) {
                    running = false
                    break
                }
                filled += read
            }
            if (filled == 0) break
            val data = if (filled == chunk.size) chunk else chunk.copyOf(filled)
            onChunk(data)
            // -60 dB and below is silence, 0 dB is the loudest.
            onLevel(((Pcm16.decibels(data) + 60) / 60).toFloat().coerceIn(0f, 1f))
        }
    }

    fun stop() {
        running = false
        val record = record ?: return
        this.record = null
        // stop() makes a pending read() return, so the thread delivers its last chunk and ends.
        runCatching { record.stop() }
        thread?.join(500)
        thread = null
        record.release()
    }
}
