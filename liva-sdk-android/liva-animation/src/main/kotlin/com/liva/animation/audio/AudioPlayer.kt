package com.liva.animation.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import kotlinx.coroutines.*
import kotlinx.coroutines.DelicateCoroutinesApi
import kotlinx.coroutines.newSingleThreadContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Queued audio chunk for playback — stores pre-decoded PCM data.
 */
data class QueuedAudioChunk(
    val pcmData: ByteArray,
    val chunkIndex: Int
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false
        other as QueuedAudioChunk
        return chunkIndex == other.chunkIndex && pcmData.contentEquals(other.pcmData)
    }

    override fun hashCode(): Int {
        return 31 * pcmData.contentHashCode() + chunkIndex
    }
}

/**
 * High-performance audio player for streaming MP3 chunks.
 *
 * Two-phase pipeline:
 * 1. preDecodeAudio() — called when receive_audio arrives, decodes MP3→PCM on decode thread
 * 2. queueAudio() — called when animation triggers, moves pre-decoded PCM to playback queue
 *
 * This eliminates audio gaps caused by decode latency (2-5s on emulator, ~50ms on real device).
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

    // Dedicated thread for audio playback (avoids IO thread pool starvation from frame decoding)
    @OptIn(DelicateCoroutinesApi::class)
    private val audioDispatcher = newSingleThreadContext("LIVAAudioThread")
    // Dedicated thread for MP3 decode (single thread to avoid CPU contention with frame decoding)
    @OptIn(DelicateCoroutinesApi::class)
    private val decodeDispatcher = newSingleThreadContext("LIVADecodeThread")
    private var scope = CoroutineScope(audioDispatcher + SupervisorJob())
    private val pcmQueue = ConcurrentLinkedQueue<QueuedAudioChunk>()

    // Pre-decoded PCM cache: chunkIndex → PCM bytes (decoded ahead of playback trigger)
    private val preDecodedPcm = ConcurrentHashMap<Int, ByteArray>()
    // Chunks currently being decoded (to avoid duplicate decode jobs)
    private val decodingChunks = ConcurrentHashMap.newKeySet<Int>()

    // Audio duration per chunk (computed from PCM size after pre-decode)
    private val preDecodedDurations = ConcurrentHashMap<Int, Long>()
    // Per-chunk playback start time (for elapsed tracking)
    private val chunkPlayStartTimes = ConcurrentHashMap<Int, Long>()

    private var audioTrack: AudioTrack? = null
    private val isPlaying = AtomicBoolean(false)
    private val isPaused = AtomicBoolean(false)
    private val currentChunkIndex = AtomicInteger(-1)
    private val messageActive = AtomicBoolean(false)

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

    // MARK: - Pre-decode (Phase 1)

    /**
     * Pre-decode MP3 to PCM on the decode thread. Called when receive_audio arrives,
     * well before animation triggers playback. The decoded PCM is cached in memory.
     */
    fun preDecodeAudio(audioData: ByteArray, chunkIndex: Int) {
        if (preDecodedPcm.containsKey(chunkIndex) || !decodingChunks.add(chunkIndex)) {
            return // Already decoded or currently decoding
        }

        val queueTime = System.currentTimeMillis()
        Log.d(TAG, "Pre-decoding: chunk=$chunkIndex, mp3Size=${audioData.size}")

        // Ensure scope is active
        if (!scope.isActive) {
            scope = CoroutineScope(audioDispatcher + SupervisorJob())
        }

        scope.launch(decodeDispatcher) {
            val decodeStart = System.currentTimeMillis()
            val pcmData = decodeMp3ToPcm(audioData)
            val decodeMs = System.currentTimeMillis() - decodeStart
            decodingChunks.remove(chunkIndex)

            if (pcmData != null && pcmData.isNotEmpty()) {
                preDecodedPcm[chunkIndex] = pcmData
                // Compute audio duration from PCM size: bytes / (sampleRate * bytesPerSample)
                val durationMs = pcmData.size * 1000L / (SAMPLE_RATE * 2)
                preDecodedDurations[chunkIndex] = durationMs
                Log.d(TAG, "Pre-decoded: chunk=$chunkIndex, decode=${decodeMs}ms, " +
                        "mp3=${audioData.size}B, pcm=${pcmData.size}B, duration=${durationMs}ms")
            } else {
                Log.e(TAG, "Pre-decode failed: chunk=$chunkIndex, decode=${decodeMs}ms")
            }
        }
    }

    // MARK: - Queue for Playback (Phase 2)

    /**
     * Queue audio for playback. If pre-decoded PCM exists, enqueues immediately (0ms).
     * Otherwise falls back to decode-on-demand.
     */
    fun queueAudio(audioData: ByteArray, chunkIndex: Int) {
        val queueTime = System.currentTimeMillis()

        // Check if already pre-decoded
        val cachedPcm = preDecodedPcm.remove(chunkIndex)
        if (cachedPcm != null) {
            pcmQueue.offer(QueuedAudioChunk(cachedPcm, chunkIndex))
            Log.d(TAG, "Queued pre-decoded audio: chunk=$chunkIndex, pcm=${cachedPcm.size}B, queueDepth=${pcmQueue.size} (0ms)")

            if (!isPlaying.get() && !isPaused.get()) {
                startPlayback()
            }
            return
        }

        // Not pre-decoded yet — check if currently decoding
        if (decodingChunks.contains(chunkIndex)) {
            Log.d(TAG, "Waiting for pre-decode: chunk=$chunkIndex — polling until ready")

            // Ensure scope is active
            if (!scope.isActive) {
                scope = CoroutineScope(audioDispatcher + SupervisorJob())
            }

            // Poll until pre-decode completes (use Default to avoid blocking on decode thread)
            scope.launch(Dispatchers.Default) {
                var waitMs = 0L
                while (decodingChunks.contains(chunkIndex) && waitMs < 10000) {
                    delay(16)
                    waitMs += 16
                }
                val pcm = preDecodedPcm.remove(chunkIndex)
                if (pcm != null) {
                    pcmQueue.offer(QueuedAudioChunk(pcm, chunkIndex))
                    Log.d(TAG, "Queued after wait: chunk=$chunkIndex, waited=${waitMs}ms, pcm=${pcm.size}B")
                    if (!isPlaying.get() && !isPaused.get()) {
                        withContext(audioDispatcher) { startPlayback() }
                    }
                } else {
                    Log.e(TAG, "Pre-decode timed out or failed: chunk=$chunkIndex")
                }
            }
            return
        }

        // Fallback: decode on demand (shouldn't happen with proper pre-decode flow)
        Log.w(TAG, "No pre-decode for chunk=$chunkIndex — decoding on demand")
        if (!scope.isActive) {
            scope = CoroutineScope(audioDispatcher + SupervisorJob())
        }
        scope.launch(decodeDispatcher) {
            val decodeStart = System.currentTimeMillis()
            val pcmData = decodeMp3ToPcm(audioData)
            val decodeMs = System.currentTimeMillis() - decodeStart

            if (pcmData != null && pcmData.isNotEmpty()) {
                pcmQueue.offer(QueuedAudioChunk(pcmData, chunkIndex))
                Log.d(TAG, "Decoded on-demand: chunk=$chunkIndex, decode=${decodeMs}ms, pcm=${pcmData.size}B")
                if (!isPlaying.get() && !isPaused.get()) {
                    withContext(audioDispatcher) { startPlayback() }
                }
            }
        }
    }

    /**
     * Clear all queued audio and pre-decoded cache.
     */
    fun clearQueue() {
        pcmQueue.clear()
        preDecodedPcm.clear()
        decodingChunks.clear()
        preDecodedDurations.clear()
        chunkPlayStartTimes.clear()
        messageActive.set(false)
    }

    /**
     * Get the pre-computed audio duration for a chunk (from PCM size).
     * Returns 0 if chunk hasn't been pre-decoded yet.
     */
    fun getChunkDurationMs(chunkIndex: Int): Long = preDecodedDurations[chunkIndex] ?: 0L

    /**
     * Get elapsed playback time for a chunk (wall clock since playback started).
     * Returns 0 if chunk hasn't started playing yet.
     */
    fun getChunkElapsedMs(chunkIndex: Int): Long {
        val startTime = chunkPlayStartTimes[chunkIndex] ?: return 0L
        return System.currentTimeMillis() - startTime
    }

    /**
     * Mark that a message is active — keeps the playback loop alive between chunks.
     */
    fun markMessageActive() {
        messageActive.set(true)
    }

    /**
     * Mark that the message is complete — allows the playback loop to exit when queue empties.
     */
    fun markMessageComplete() {
        messageActive.set(false)
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

        // Reinitialize AudioTrack if needed (after stop())
        if (audioTrack?.state != AudioTrack.STATE_INITIALIZED) {
            Log.d(TAG, "AudioTrack not initialized, reinitializing")
            audioTrack?.release()
            initializeAudioTrack()
        }
        audioTrack?.play()

        // Ensure scope is active (may have been cancelled by previous error)
        if (!scope.isActive) {
            Log.d(TAG, "Scope was cancelled, creating new scope")
            scope = CoroutineScope(audioDispatcher + SupervisorJob())
        }

        Log.d(TAG, "Starting playback loop (scope.isActive=${scope.isActive})")

        scope.launch(audioDispatcher) {
            try {
                processAudioQueue()
            } catch (e: Exception) {
                Log.e(TAG, "processAudioQueue crashed: ${e.message}", e)
                isPlaying.set(false)
            }
        }
    }

    private suspend fun processAudioQueue() {
        Log.d(TAG, "processAudioQueue started on thread ${Thread.currentThread().name}")
        while (isPlaying.get()) {
            if (isPaused.get()) {
                delay(50)
                continue
            }

            val chunk = pcmQueue.poll()
            if (chunk == null) {
                // Queue empty — if message still active, keep waiting for next chunk
                if (messageActive.get()) {
                    delay(16) // Check frequently (~60Hz) for low-latency chunk pickup
                    continue
                }
                // Message complete and queue empty — done
                delay(50)
                if (pcmQueue.isEmpty() && !messageActive.get()) {
                    break
                }
                continue
            }

            // Play pre-decoded PCM — no decode latency
            Log.d(TAG, "Playing chunk ${chunk.chunkIndex} (pcm=${chunk.pcmData.size}B)...")
            playPcmChunk(chunk)
        }

        // Playback complete
        isPlaying.set(false)
        Log.d(TAG, "Playback loop ended")
        withContext(Dispatchers.Main) {
            onPlaybackComplete?.invoke()
        }
    }

    private suspend fun playPcmChunk(chunk: QueuedAudioChunk) {
        currentChunkIndex.set(chunk.chunkIndex)
        val chunkStartTime = System.currentTimeMillis()
        chunkPlayStartTimes[chunk.chunkIndex] = chunkStartTime

        withContext(Dispatchers.Main) {
            onChunkStart?.invoke(chunk.chunkIndex)
        }

        try {
            val pcmData = chunk.pcmData
            val writeStartTime = System.currentTimeMillis()
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
                    Log.e(TAG, "AudioTrack write error: $written for chunk ${chunk.chunkIndex}")
                    break
                }
            }
            val writeMs = System.currentTimeMillis() - writeStartTime
            val totalMs = System.currentTimeMillis() - chunkStartTime
            Log.d(TAG, "Chunk ${chunk.chunkIndex}: write=${writeMs}ms, total=${totalMs}ms, pcm=${pcmData.size}B")

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
        // Write MP3 data to temp file (MediaExtractor requires file/fd)
        val tempFile = File(cacheDir, "temp_audio_${Thread.currentThread().id}_${System.nanoTime()}.mp3")

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

            // Use ByteArrayOutputStream instead of mutableListOf<Byte> for performance
            val outputStream = ByteArrayOutputStream()
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
                        outputStream.write(chunk)
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

            outputStream.toByteArray()

        } catch (e: Exception) {
            Log.e(TAG, "Error decoding MP3 file: ${e.message}")
            null
        } finally {
            extractor.release()
        }
    }

    // MARK: - Status

    val queuedChunkCount: Int
        get() = pcmQueue.size

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
