package com.liva.animation.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import kotlinx.coroutines.*
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Queued audio chunk for playback.
 */
data class QueuedAudioChunk(
    val audioData: ByteArray,
    val chunkIndex: Int
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false
        other as QueuedAudioChunk
        return chunkIndex == other.chunkIndex && audioData.contentEquals(other.audioData)
    }

    override fun hashCode(): Int {
        return 31 * audioData.contentHashCode() + chunkIndex
    }
}

/**
 * High-performance audio player for streaming MP3 chunks.
 */
internal class AudioPlayer(
    private val cacheDir: File
) {
    companion object {
        private const val TAG = "LIVAAudioPlayer"
        private const val SAMPLE_RATE = 44100
        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_OUT_MONO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
    }

    // MARK: - Properties

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val audioQueue = ConcurrentLinkedQueue<QueuedAudioChunk>()

    private var audioTrack: AudioTrack? = null
    private val isPlaying = AtomicBoolean(false)
    private val isPaused = AtomicBoolean(false)
    private val currentChunkIndex = AtomicInteger(-1)

    // MARK: - Callbacks

    var onChunkStart: ((Int) -> Unit)? = null
    var onChunkComplete: ((Int) -> Unit)? = null
    var onPlaybackComplete: (() -> Unit)? = null
    var onError: ((Exception) -> Unit)? = null

    // MARK: - Initialization

    init {
        initializeAudioTrack()
    }

    private fun initializeAudioTrack() {
        val bufferSize = AudioTrack.getMinBufferSize(
            SAMPLE_RATE,
            CHANNEL_CONFIG,
            AUDIO_FORMAT
        )

        audioTrack = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AUDIO_FORMAT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(CHANNEL_CONFIG)
                    .build()
            )
            .setBufferSizeInBytes(bufferSize * 2)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
    }

    // MARK: - Queue Management

    /**
     * Queue audio data for playback.
     */
    fun queueAudio(audioData: ByteArray, chunkIndex: Int) {
        val chunk = QueuedAudioChunk(audioData, chunkIndex)
        audioQueue.offer(chunk)

        // Start playback if not already playing
        if (!isPlaying.get() && !isPaused.get()) {
            startPlayback()
        }
    }

    /**
     * Clear all queued audio.
     */
    fun clearQueue() {
        audioQueue.clear()
    }

    // MARK: - Playback Control

    /**
     * Start audio playback.
     */
    fun play() {
        if (isPaused.get()) {
            isPaused.set(false)
            audioTrack?.play()
        } else if (!isPlaying.get()) {
            startPlayback()
        }
    }

    /**
     * Pause playback.
     */
    fun pause() {
        isPaused.set(true)
        audioTrack?.pause()
    }

    /**
     * Stop playback and clear queue.
     */
    fun stop() {
        isPlaying.set(false)
        isPaused.set(false)
        audioTrack?.stop()
        audioTrack?.flush()
        clearQueue()
    }

    // MARK: - Internal Playback

    private fun startPlayback() {
        if (isPlaying.get()) return

        isPlaying.set(true)
        audioTrack?.play()

        scope.launch {
            processAudioQueue()
        }
    }

    private suspend fun processAudioQueue() {
        while (isPlaying.get()) {
            if (isPaused.get()) {
                delay(50)
                continue
            }

            val chunk = audioQueue.poll()
            if (chunk == null) {
                // No more chunks, wait a bit then check again
                delay(50)

                // If still no chunks after waiting, end playback
                if (audioQueue.isEmpty()) {
                    delay(100)
                    if (audioQueue.isEmpty()) {
                        break
                    }
                }
                continue
            }

            // Process this chunk
            playChunk(chunk)
        }

        // Playback complete
        isPlaying.set(false)
        withContext(Dispatchers.Main) {
            onPlaybackComplete?.invoke()
        }
    }

    private suspend fun playChunk(chunk: QueuedAudioChunk) {
        currentChunkIndex.set(chunk.chunkIndex)

        withContext(Dispatchers.Main) {
            onChunkStart?.invoke(chunk.chunkIndex)
        }

        try {
            // Decode MP3 to PCM
            val pcmData = decodeMp3ToPcm(chunk.audioData)

            if (pcmData != null && pcmData.isNotEmpty()) {
                // Write PCM data to AudioTrack
                var offset = 0
                while (offset < pcmData.size && isPlaying.get() && !isPaused.get()) {
                    val written = audioTrack?.write(
                        pcmData,
                        offset,
                        minOf(4096, pcmData.size - offset)
                    ) ?: 0

                    if (written > 0) {
                        offset += written
                    } else if (written < 0) {
                        Log.e(TAG, "AudioTrack write error: $written")
                        break
                    }
                }
            }

            withContext(Dispatchers.Main) {
                onChunkComplete?.invoke(chunk.chunkIndex)
            }

        } catch (e: Exception) {
            Log.e(TAG, "Error playing chunk ${chunk.chunkIndex}: ${e.message}")
            withContext(Dispatchers.Main) {
                onError?.invoke(e)
            }
        }
    }

    // MARK: - MP3 Decoding

    private fun decodeMp3ToPcm(mp3Data: ByteArray): ByteArray? {
        // Write MP3 data to temp file
        val tempFile = File(cacheDir, "temp_audio_${System.currentTimeMillis()}.mp3")

        return try {
            FileOutputStream(tempFile).use { fos ->
                fos.write(mp3Data)
            }

            decodeMp3File(tempFile)

        } catch (e: Exception) {
            Log.e(TAG, "Error decoding MP3: ${e.message}")
            null
        } finally {
            tempFile.delete()
        }
    }

    private fun decodeMp3File(file: File): ByteArray? {
        val extractor = MediaExtractor()

        return try {
            extractor.setDataSource(file.absolutePath)

            // Find audio track
            var audioTrackIndex = -1
            var format: MediaFormat? = null

            for (i in 0 until extractor.trackCount) {
                val trackFormat = extractor.getTrackFormat(i)
                val mime = trackFormat.getString(MediaFormat.KEY_MIME)
                if (mime?.startsWith("audio/") == true) {
                    audioTrackIndex = i
                    format = trackFormat
                    break
                }
            }

            if (audioTrackIndex < 0 || format == null) {
                Log.e(TAG, "No audio track found")
                return null
            }

            extractor.selectTrack(audioTrackIndex)

            // Create decoder
            val mime = format.getString(MediaFormat.KEY_MIME) ?: return null
            val codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            val outputData = mutableListOf<Byte>()
            val bufferInfo = MediaCodec.BufferInfo()
            var isEOS = false
            val timeoutUs = 10000L

            while (!isEOS) {
                // Feed input
                val inputBufferIndex = codec.dequeueInputBuffer(timeoutUs)
                if (inputBufferIndex >= 0) {
                    val inputBuffer = codec.getInputBuffer(inputBufferIndex)
                    inputBuffer?.let {
                        val sampleSize = extractor.readSampleData(it, 0)
                        if (sampleSize < 0) {
                            codec.queueInputBuffer(
                                inputBufferIndex,
                                0,
                                0,
                                0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM
                            )
                            isEOS = true
                        } else {
                            codec.queueInputBuffer(
                                inputBufferIndex,
                                0,
                                sampleSize,
                                extractor.sampleTime,
                                0
                            )
                            extractor.advance()
                        }
                    }
                }

                // Get output
                var outputBufferIndex = codec.dequeueOutputBuffer(bufferInfo, timeoutUs)
                while (outputBufferIndex >= 0) {
                    val outputBuffer = codec.getOutputBuffer(outputBufferIndex)
                    outputBuffer?.let {
                        val chunk = ByteArray(bufferInfo.size)
                        it.get(chunk)
                        outputData.addAll(chunk.toList())
                    }

                    codec.releaseOutputBuffer(outputBufferIndex, false)

                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        isEOS = true
                    }

                    outputBufferIndex = codec.dequeueOutputBuffer(bufferInfo, timeoutUs)
                }
            }

            codec.stop()
            codec.release()

            outputData.toByteArray()

        } catch (e: Exception) {
            Log.e(TAG, "Error decoding MP3 file: ${e.message}")
            null
        } finally {
            extractor.release()
        }
    }

    // MARK: - Status

    val queuedChunkCount: Int
        get() = audioQueue.size

    val isCurrentlyPlaying: Boolean
        get() = isPlaying.get()

    val currentPlayingChunk: Int
        get() = currentChunkIndex.get()

    // MARK: - Cleanup

    fun release() {
        stop()
        scope.cancel()
        audioTrack?.release()
        audioTrack = null
    }
}
