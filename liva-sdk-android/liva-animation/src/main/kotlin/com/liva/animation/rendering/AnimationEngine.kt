package com.liva.animation.rendering

import android.graphics.Bitmap
import android.graphics.PointF
import android.os.SystemClock
import android.util.Log
import com.liva.animation.models.DecodedFrame
import com.liva.animation.models.OverlaySection
import com.liva.animation.logging.SessionLogger
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

private const val TAG = "AnimationEngine"

/**
 * Animation playback mode.
 */
enum class AnimationMode(val frameRate: Double) {
    IDLE(10.0),      // 10 fps for idle animations
    TALKING(30.0),   // 30 fps for lip sync
    TRANSITION(30.0); // Transition between animations

    val frameIntervalMs: Long
        get() = (1000.0 / frameRate).toLong()
}

/**
 * Frame ready for rendering.
 */
data class RenderFrame(
    val baseImage: Bitmap?,
    val overlayImage: Bitmap?,
    val overlayPosition: PointF,
    val timestamp: Long
)

/**
 * Animation chunk for queued playback.
 */
data class QueuedAnimationChunk(
    val chunkIndex: Int,
    val frames: List<DecodedFrame>,
    val overlayPosition: PointF,
    val animationName: String,
    var isReady: Boolean = false
)

/**
 * Manages animation frame timing, overlay sections, and audio-video sync.
 * Implements iOS-style buffer readiness, jitter prevention, and time-based advancement.
 */
internal class AnimationEngine {

    companion object {
        // Reduced from 30 to 2: decode-gated advancement in getNextFrame() prevents the
        // frame counter from advancing past undecoded frames, so a large buffer isn't needed.
        // 2-frame buffer gives near-instant section starts while decode-gate provides safety.
        // Lower value = shorter inter-chunk gaps = smoother transitions between chunks.
        const val MIN_FRAMES_BEFORE_START = 2
        const val TARGET_FPS = 30.0
        const val FRAME_INTERVAL_MS = 1000.0 / TARGET_FPS  // 33.33ms
    }

    // MARK: - Properties

    var mode: AnimationMode = AnimationMode.IDLE
        private set

    var currentAnimationName: String = ""
        private set

    // Session logging
    private var sessionId: String? = null
    private var totalRenderedFrames = 0

    // FPS tracking (iOS-style windowed average)
    private var fpsLastUpdateTime: Long = 0
    private var animationFrameCount: Int = 0
    private var currentFPS: Double = 0.0
    private val FPS_UPDATE_INTERVAL_MS = 500L  // Update FPS every 0.5 seconds

    // Sync tracking - track actual base frame being rendered
    private var currentRenderedBaseFrameIndex: Int = 0

    // Frame decoder reference for decode-readiness checks
    private var frameDecoder: FrameDecoder? = null

    // ═══════════════════════════════════════════════════════════════════════════
    // NEW: Overlay Section State Tracking (matches iOS)
    // ═══════════════════════════════════════════════════════════════════════════

    // Queued overlay sections waiting to play
    private val overlayQueue = mutableListOf<OverlaySection>()
    private val overlayQueueLock = ReentrantLock()

    // Currently playing overlay section
    private var currentOverlaySection: OverlaySection? = null

    // Jitter fix: Hold last frame while waiting for next section buffer
    private var holdingLastFrame = false
    private var lastHeldFrame: DecodedFrame? = null

    // Previous frame for skip-draw-on-wait
    private var previousRenderFrame: RenderFrame? = null

    // Time-based frame advancement
    private var overlayStartTime: Long = 0
    private var lastAdvanceTime: Long = 0
    private var frameAccumulator = 0.0

    // ═══════════════════════════════════════════════════════════════════════════
    // Legacy frame queue (kept for compatibility, will migrate to overlay sections)
    // ═══════════════════════════════════════════════════════════════════════════

    private val frameQueue = mutableListOf<DecodedFrame>()
    private val queueLock = ReentrantLock()

    private val chunkQueue = mutableListOf<QueuedAnimationChunk>()
    private val chunkLock = ReentrantLock()

    private var currentFrameIndex = 0
    private var lastFrameTime = 0L
    private var isPlaying = false

    private var baseFrame: Bitmap? = null
    private var baseFrameManager: BaseFrameManager? = null
    private var overlayPosition = PointF(0f, 0f)

    // MARK: - Callbacks

    var onModeChange: ((AnimationMode) -> Unit)? = null
    var onChunkComplete: ((Int) -> Unit)? = null
    var onAnimationComplete: (() -> Unit)? = null

    // Audio-video sync callback (triggers audio playback when first frame renders)
    var onStartAudioForChunk: ((chunkIndex: Int, audioData: ByteArray) -> Unit)? = null

    // All chunks complete callback (like iOS animationEngineDidFinishAllChunks)
    var onAllChunksComplete: (() -> Unit)? = null

    // Audio duration query — returns pre-decoded PCM duration in ms for a given chunk.
    // Wired by LIVAClient to AudioPlayer.getChunkDurationMs().
    var getAudioDurationForChunk: ((Int) -> Long)? = null

    // Audio elapsed query — returns ms since AudioTrack started playing this chunk.
    // More accurate than wall-clock from trigger time (accounts for pre-decode delay).
    // Wired by LIVAClient to AudioPlayer.getChunkElapsedMs().
    var getAudioElapsedForChunk: ((Int) -> Long)? = null

    // MARK: - Message Lifecycle State

    // Tracks whether a message is actively being processed (audio chunks arriving)
    // Prevents premature idle transition when overlay queue empties between chunks
    private var messageActive = false

    // Set to true when audio_end event arrives (no more chunks coming)
    private var audioEndReceived = false

    // Next expected chunk index (for ordering - prevents chunk 3 playing before chunk 2)
    private var nextExpectedChunkIndex = 0

    // MARK: - Audio Sync State

    // Audio data queued per chunk (waiting for animation sync)
    private val pendingAudioChunks = mutableMapOf<Int, ByteArray>()
    private val audioChunkLock = ReentrantLock()

    // Track which chunks have already started audio (prevent duplicate playback)
    private val audioStartedForChunk = mutableSetOf<Int>()

    // Gap tracking between chunks
    private var lastSectionCompleteTime: Long = 0
    private var skipDrawCount: Int = 0
    private var messageStartTime: Long = 0
    private var totalChunksPlayed: Int = 0

    // SKIP_DRAW timeout (matches iOS maxConsecutiveSkipDraws = 15)
    // After 15 consecutive skips for the same frame (~500ms at 30fps),
    // force-advance past it to prevent infinite freeze on stuck frames.
    private val MAX_CONSECUTIVE_SKIP_DRAWS = 15
    private var consecutiveSkipDrawCount = 0
    private var lastSkipDrawFrame = -1

    // MARK: - Configuration

    var minimumBufferFrames: Int = MIN_FRAMES_BEFORE_START
    var loopIdleAnimations: Boolean = true

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Set frame decoder for decode-readiness checks.
     */
    fun setFrameDecoder(decoder: FrameDecoder) {
        this.frameDecoder = decoder
    }

    /**
     * Set session ID for logging
     */
    fun setSessionId(sessionId: String) {
        this.sessionId = sessionId
        Log.d(TAG, "Session ID set for frame logging: $sessionId")
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Audio Queue Management
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Queue audio data for a chunk (don't play immediately - wait for animation sync)
     * Audio will start when first overlay frame of this chunk renders.
     */
    fun queueAudioForChunk(chunkIndex: Int, audioData: ByteArray) {
        audioChunkLock.withLock {
            pendingAudioChunks[chunkIndex] = audioData
            Log.d(TAG, "Queued audio for chunk $chunkIndex (${audioData.size} bytes) - waiting for animation sync")
        }
    }

    /**
     * Clear all queued audio (called when new message starts)
     */
    fun clearAudioQueue() {
        audioChunkLock.withLock {
            pendingAudioChunks.clear()
            audioStartedForChunk.clear()
            Log.d(TAG, "Cleared audio queue and started-chunk tracking")
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Message Lifecycle
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Mark the start of a new message (called when chunk 0 audio arrives).
     * Prevents premature idle transitions while chunks are still incoming.
     */
    fun startNewMessage() {
        messageActive = true
        audioEndReceived = false
        nextExpectedChunkIndex = 0
        messageStartTime = SystemClock.elapsedRealtime()
        totalChunksPlayed = 0
        lastSectionCompleteTime = 0
        Log.d(TAG, "📨 Message started")
    }

    /**
     * Mark that audio_end has been received (no more chunks coming from backend).
     * If the engine has already finished all queued sections, transition to idle now.
     */
    fun markAudioEndReceived() {
        audioEndReceived = true
        Log.d(TAG, "📭 audio_end received - will idle when all sections complete")

        // If no section is playing and queue is empty, idle now
        if (currentOverlaySection == null) {
            val queueEmpty = overlayQueueLock.withLock { overlayQueue.isEmpty() }
            if (queueEmpty) {
                Log.d(TAG, "🎉 No pending sections after audio_end - transitioning to idle")
                messageActive = false
                transitionToIdle()
                onAllChunksComplete?.invoke()
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - NEW: Overlay Section Management (iOS-style)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Enqueue an overlay section for playback.
     * Matches iOS enqueueOverlaySet().
     */
    fun enqueueOverlaySection(section: OverlaySection) {
        overlayQueueLock.withLock {
            overlayQueue.add(section)
            overlayQueue.sortBy { it.chunkIndex }
            Log.d(TAG, "Enqueued overlay section: chunk=${section.chunkIndex}, frames=${section.frames.size}")
        }

        // If no section is currently playing, try to start the next one
        // This handles both initial start AND resuming after waiting between chunks
        if (currentOverlaySection == null) {
            tryStartNextSection()
        }
    }

    /**
     * Check if overlay section buffer is ready (30+ frames decoded).
     * Matches iOS isBufferReady().
     */
    private fun isBufferReady(section: OverlaySection): Boolean {
        val decoder = frameDecoder ?: return true  // If no decoder, assume ready

        val requiredFrames = minOf(MIN_FRAMES_BEFORE_START, section.totalFrames)
        val keys = section.frames.take(requiredFrames).mapNotNull { it.overlayId }

        return decoder.areFirstFramesReady(keys, requiredFrames)
    }

    /**
     * Try to start the next queued overlay section.
     */
    private fun tryStartNextSection() {
        val nextSection = overlayQueueLock.withLock {
            overlayQueue.firstOrNull()
        } ?: return

        // Only start if this is the expected next chunk (preserve order)
        if (messageActive && nextSection.chunkIndex > nextExpectedChunkIndex) {
            Log.d(TAG, "⏳ Chunk ${nextSection.chunkIndex} queued but waiting for chunk $nextExpectedChunkIndex first")
            return
        }

        // Check buffer readiness
        if (!isBufferReady(nextSection)) {
            Log.d(TAG, "⏳ Waiting for buffer: chunk=${nextSection.chunkIndex}, need $MIN_FRAMES_BEFORE_START frames")
            return
        }

        // Remove from queue and set as current
        overlayQueueLock.withLock {
            overlayQueue.removeFirstOrNull()
        }

        // Initialize playback state
        nextSection.playing = true
        nextSection.currentDrawingFrame = 0
        nextSection.startTime = SystemClock.elapsedRealtime()
        nextSection.done = false
        nextSection.holdingLastFrame = false

        currentOverlaySection = nextSection
        currentAnimationName = nextSection.animationName
        overlayPosition = PointF(nextSection.zoneTopLeft.first.toFloat(), nextSection.zoneTopLeft.second.toFloat())

        // Reset time-based advancement
        overlayStartTime = SystemClock.elapsedRealtime()
        lastAdvanceTime = overlayStartTime
        frameAccumulator = 0.0

        // Switch to talking mode
        setMode(AnimationMode.TALKING)

        val gapMs = if (lastSectionCompleteTime > 0) SystemClock.elapsedRealtime() - lastSectionCompleteTime else 0
        Log.d(TAG, "▶️ Started overlay section: chunk=${nextSection.chunkIndex}, frames=${nextSection.frames.size}, " +
                "baseAnim=${nextSection.animationName}, gapFromPrev=${gapMs}ms")
    }

    /**
     * Check if we should hold the last frame (jitter fix).
     * Prevents blank frame between chunks.
     */
    private fun shouldHoldLastFrame(): Boolean {
        val section = currentOverlaySection ?: return false

        // At or past last frame?
        if (section.currentDrawingFrame >= section.frames.size - 1) {
            // Check if next section exists and is buffered
            val nextSection = overlayQueueLock.withLock {
                overlayQueue.firstOrNull()
            }

            if (nextSection != null && !isBufferReady(nextSection)) {
                section.holdingLastFrame = true
                Log.d(TAG, "⏸️ Holding last frame - waiting for chunk ${nextSection.chunkIndex} buffer")
                return true
            }
        }

        return false
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Frame Retrieval
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Get the next frame for rendering.
     * Implements skip-draw-on-wait, buffer readiness, and time-based advancement.
     */
    fun getNextFrame(): RenderFrame? {
        val currentTime = SystemClock.elapsedRealtime()

        // Handle idle mode
        if (mode == AnimationMode.IDLE) {
            val idleFrame = getIdleFrame(currentTime)
            previousRenderFrame = idleFrame
            return idleFrame
        }

        // TALKING mode - use overlay sections
        val section = currentOverlaySection

        if (section == null) {
            // No active section - try to start one
            tryStartNextSection()
            return previousRenderFrame ?: getIdleFrame(currentTime)
        }

        // Trigger audio BEFORE frame advancement — if we wait until after,
        // the advancement loop may increment past frame 0 and the check never fires
        if (!section.audioStarted) {
            section.audioStarted = true
            triggerAudioForChunk(section.chunkIndex)
        }

        // AUDIO-PACED FRAME ADVANCEMENT
        // Instead of advancing one frame every 33ms (time-based), advance to the frame
        // that matches the current audio playback position. This ensures overlay and audio
        // stay in sync even when decode-gate slows frame rendering (e.g., emulator decode
        // at 50ms/frame stretching 27 frames from 900ms to 1400ms while audio plays at real speed).

        // Poll for audio duration — pre-decode may not be complete at trigger time (emulator
        // can take 600ms-3000ms for MP3→PCM). Re-query each render cycle until available.
        if (section.audioDurationMs == 0L && section.audioTriggerTime != null) {
            val freshDuration = getAudioDurationForChunk?.invoke(section.chunkIndex) ?: 0L
            if (freshDuration > 0) {
                section.audioDurationMs = freshDuration
                Log.d(TAG, "🎵 Late audio duration for chunk ${section.chunkIndex}: ${freshDuration}ms")
            }
        }

        val audioDuration = section.audioDurationMs
        // Query actual AudioPlayer elapsed (0 until AudioTrack starts writing PCM)
        val playerElapsed = if (audioDuration > 0) {
            getAudioElapsedForChunk?.invoke(section.chunkIndex) ?: 0L
        } else 0L

        if (playerElapsed > 0 && audioDuration > 0 && !section.done) {
            // AUDIO-PACED MODE: AudioTrack is actively playing — sync frames to audio position.
            // This is the primary sync path. playerElapsed is measured from the actual moment
            // AudioTrack starts writing PCM, so it's accurate regardless of pre-decode delay.
            val audioProgress = (playerElapsed.toDouble() / audioDuration).coerceIn(0.0, 1.0)
            val targetFrame = (audioProgress * section.totalFrames).toInt()
                .coerceIn(0, section.totalFrames - 1)

            if (targetFrame > section.currentDrawingFrame) {
                // Audio is ahead — advance toward target frame.
                // Find highest decoded frame up to targetFrame (respects decode-gate).
                var bestFrame = section.currentDrawingFrame
                for (i in (section.currentDrawingFrame + 1)..targetFrame) {
                    val key = section.frames.getOrNull(i)?.overlayId
                    if (key == null || frameDecoder?.isImageDecoded(key) != false) {
                        bestFrame = i
                    } else {
                        break
                    }
                }

                if (bestFrame > section.currentDrawingFrame) {
                    val skipped = bestFrame - section.currentDrawingFrame - 1
                    if (skipped > 0) {
                        Log.d(TAG, "⏩ Audio-paced skip: ${section.currentDrawingFrame}→$bestFrame (target=$targetFrame, skipped=$skipped, audio=${playerElapsed}ms/${audioDuration}ms)")
                    }
                    section.currentDrawingFrame = bestFrame
                }
            }
            // targetFrame <= currentDrawingFrame: hold (time-based ran ahead of audio)

            // Section complete when audio finishes playing
            if (playerElapsed >= audioDuration) {
                section.currentDrawingFrame = section.totalFrames - 1
                section.done = true
                onSectionComplete(section)
            }
        } else if (!section.done) {
            if (audioDuration > 0) {
                // Audio duration known but AudioTrack not yet started (playerElapsed == 0).
                // HOLD at current frame — don't advance until audio plays so overlay and audio
                // start together in sync. On real devices this hold is <50ms (imperceptible).
                // Audio-paced path will take over when playerElapsed > 0.
            } else {
                // TIME-BASED FALLBACK: No audio info at all (edge case / pre-decode not done).
                // Advance at 30fps with decode-gate and jitter hold.
                val deltaTime = currentTime - lastAdvanceTime
                lastAdvanceTime = currentTime
                frameAccumulator += deltaTime

                if (frameAccumulator >= FRAME_INTERVAL_MS) {
                    if (frameAccumulator > FRAME_INTERVAL_MS * 2) {
                        frameAccumulator = FRAME_INTERVAL_MS * 2
                    }
                    frameAccumulator -= FRAME_INTERVAL_MS

                    if (shouldHoldLastFrame()) {
                        frameAccumulator = 0.0
                    } else {
                        val nextIdx = section.currentDrawingFrame + 1
                        if (nextIdx < section.frames.size) {
                            val nextKey = section.frames[nextIdx].overlayId
                            if (nextKey != null && frameDecoder?.isImageDecoded(nextKey) == false) {
                                frameAccumulator = 0.0  // decode-gate
                            } else {
                                section.currentDrawingFrame++
                            }
                        }

                        if (section.currentDrawingFrame >= section.frames.size) {
                            section.done = true
                            onSectionComplete(section)
                        }
                    }
                }
            }
        }

        // Get current frame
        val frameIndex = minOf(section.currentDrawingFrame, section.frames.size - 1)
        val currentFrame = section.frames.getOrNull(frameIndex)

        if (currentFrame == null) {
            return previousRenderFrame ?: getIdleFrame(currentTime)
        }

        // SKIP-DRAW-ON-WAIT: If overlay not decoded, hold previous frame
        // With SKIP_DRAW timeout (matches iOS maxConsecutiveSkipDraws):
        // After MAX_CONSECUTIVE_SKIP_DRAWS for the same frame, force-advance past it.
        val cacheKey = currentFrame.overlayId
        if (cacheKey != null && frameDecoder?.isImageDecoded(cacheKey) == false) {
            // Track consecutive skips for same frame
            if (section.currentDrawingFrame == lastSkipDrawFrame) {
                consecutiveSkipDrawCount++
            } else {
                consecutiveSkipDrawCount = 1
                lastSkipDrawFrame = section.currentDrawingFrame
            }

            if (consecutiveSkipDrawCount >= MAX_CONSECUTIVE_SKIP_DRAWS) {
                // TIMEOUT: Force-advance past stuck frame to prevent infinite freeze
                Log.w(TAG, "⚠️ SKIP_DRAW TIMEOUT: Force-advancing past stuck frame chunk=${section.chunkIndex} seq=${section.currentDrawingFrame} key=$cacheKey after $MAX_CONSECUTIVE_SKIP_DRAWS consecutive skips")
                consecutiveSkipDrawCount = 0
                lastSkipDrawFrame = -1
                // Don't return — fall through to render (with possibly missing overlay)
            } else {
                skipDrawCount++
                if (skipDrawCount == 1 || skipDrawCount % 10 == 0) {
                    Log.d(TAG, "⏸️ Skip-draw #$skipDrawCount ($consecutiveSkipDrawCount/$MAX_CONSECUTIVE_SKIP_DRAWS): overlay not decoded, chunk=${section.chunkIndex}, frame=${section.currentDrawingFrame}, key=$cacheKey")
                }
                return previousRenderFrame ?: getIdleFrame(currentTime)
            }
        }
        if (skipDrawCount > 0) {
            Log.d(TAG, "⏸️ Skip-draw ended after $skipDrawCount skips, resuming chunk=${section.chunkIndex} frame=${section.currentDrawingFrame}")
            skipDrawCount = 0
        }
        // Reset skip-draw timeout on successful render
        consecutiveSkipDrawCount = 0
        lastSkipDrawFrame = -1

        // Get base frame synced with overlay
        val baseImage = getBaseFrameForOverlay(currentFrame)

        // Audio already triggered before frame advancement (see above)

        // Build render frame — fetch FRESH bitmap from FrameDecoder cache.
        // The DecodedFrame.image may be a 1x1 placeholder if the frame wasn't decoded
        // when processChunkReady() built the OverlaySection. The actual bitmap is
        // decoded asynchronously and stored in the FrameDecoder cache (HashMap, no eviction).
        val overlayBitmap = currentFrame.overlayId?.let { key ->
            frameDecoder?.getImage(key)
        } ?: currentFrame.image
        val overlayOk = !overlayBitmap.isRecycled
        val baseOk = baseImage != null && !baseImage.isRecycled

        if (!overlayOk) {
            Log.e(TAG, "RECYCLED overlay at chunk=${section.chunkIndex} frame=${section.currentDrawingFrame} key=${currentFrame.overlayId}")
            return previousRenderFrame ?: getIdleFrame(currentTime)
        }
        if (!baseOk) {
            Log.e(TAG, "RECYCLED/null base at chunk=${section.chunkIndex} frame=${section.currentDrawingFrame} anim=${currentFrame.animationName}")
        }

        // Use section-level zoneTopLeft for overlay position (matches iOS and web).
        // Per-frame coordinates are always (0,0) because backend deletes them
        // (stream_handler.py removes per-frame 'coordinates' field, only sends
        // chunk-level zone_top_left in receive_audio metadata).
        val sectionPos = currentOverlaySection?.let {
            PointF(it.zoneTopLeft.first.toFloat(), it.zoneTopLeft.second.toFloat())
        } ?: PointF(0f, 0f)

        val renderFrame = RenderFrame(
            baseImage = baseImage,
            overlayImage = overlayBitmap,
            overlayPosition = sectionPos,
            timestamp = currentTime
        )

        previousRenderFrame = renderFrame

        // Log frame
        logRenderedFrame(section, currentFrame)

        return renderFrame
    }

    /**
     * Get base frame that syncs with the current overlay.
     * Uses matchedSpriteFrameNumber for proper lip sync.
     */
    private fun getBaseFrameForOverlay(overlay: DecodedFrame): Bitmap? {
        val manager = baseFrameManager ?: return baseFrame

        // Get base animation frames
        val animName = overlay.animationName.ifEmpty { currentAnimationName }
        val baseFrames = manager.getAnimationFrames(animName)

        if (baseFrames.isEmpty()) {
            // Fallback to idle
            currentRenderedBaseFrameIndex = 0
            return manager.getCurrentIdleFrame() ?: baseFrame
        }

        // Use matchedSpriteFrameNumber to sync - TRACK THIS FOR SYNC STATUS
        val baseFrameIndex = overlay.matchedSpriteFrameNumber % baseFrames.size
        currentRenderedBaseFrameIndex = baseFrameIndex

        return baseFrames.getOrNull(baseFrameIndex) ?: manager.getCurrentIdleFrame() ?: baseFrame
    }

    /**
     * Handle overlay section completion.
     */
    private fun onSectionComplete(section: OverlaySection) {
        val elapsed = SystemClock.elapsedRealtime() - (section.startTime ?: SystemClock.elapsedRealtime())
        val renderedFrames = section.currentDrawingFrame + 1
        val actualFps = if (elapsed > 0) (renderedFrames * 1000.0 / elapsed) else 0.0
        val audioInfo = if (section.audioDurationMs > 0) "audioDur=${section.audioDurationMs}ms" else "no-audio-pacing"
        Log.d(TAG, "✅ Section complete: chunk=${section.chunkIndex}, " +
                "rendered=$renderedFrames/${section.frames.size}, elapsed=${elapsed}ms, fps=${String.format("%.1f", actualFps)}, " +
                "$audioInfo, baseAnim=${section.animationName}")
        lastSectionCompleteTime = SystemClock.elapsedRealtime()
        totalChunksPlayed++
        nextExpectedChunkIndex = section.chunkIndex + 1
        onChunkComplete?.invoke(section.chunkIndex)

        // Clean up audio data for completed chunk
        audioChunkLock.withLock {
            pendingAudioChunks.remove(section.chunkIndex)
        }

        // Try to start next section
        val hasNext = overlayQueueLock.withLock { overlayQueue.isNotEmpty() }

        if (hasNext) {
            currentOverlaySection = null
            tryStartNextSection()
        } else if (messageActive && !audioEndReceived) {
            // More chunks expected but not yet received/decoded - hold last frame
            // Do NOT transition to idle or clear audio queue
            Log.d(TAG, "⏳ Queue empty but message active - holding last frame, waiting for next chunk")
            currentOverlaySection = null
            // Stay in TALKING mode so we keep rendering at 30fps
            // and can immediately start next section when it arrives
        } else {
            // All chunks truly complete (audio_end received or no active message)
            val totalMs = SystemClock.elapsedRealtime() - messageStartTime
            Log.d(TAG, "🎉 Message complete: ${totalChunksPlayed} chunks in ${totalMs}ms (${String.format("%.1f", totalMs / 1000.0)}s)")
            currentOverlaySection = null
            messageActive = false
            transitionToIdle()
            onAllChunksComplete?.invoke()
        }
    }

    /**
     * Trigger audio playback for a chunk.
     * Audio is triggered when the first overlay frame renders to ensure sync.
     */
    private fun triggerAudioForChunk(chunkIndex: Int) {
        if (audioStartedForChunk.contains(chunkIndex)) {
            return
        }

        val audioData = audioChunkLock.withLock {
            pendingAudioChunks[chunkIndex]
        }

        if (audioData != null) {
            audioStartedForChunk.add(chunkIndex)

            // Record audio timing for audio-paced frame advancement
            val audioDurationMs = getAudioDurationForChunk?.invoke(chunkIndex) ?: 0L
            currentOverlaySection?.let { section ->
                section.audioTriggerTime = SystemClock.elapsedRealtime()
                section.audioDurationMs = audioDurationMs
            }

            val overlayDecoded = currentOverlaySection?.let { section ->
                val frame = section.frames.getOrNull(0)
                frame?.overlayId?.let { frameDecoder?.isImageDecoded(it) } ?: true
            } ?: false
            onStartAudioForChunk?.invoke(chunkIndex, audioData)
            Log.d(TAG, "🔊 Audio triggered for chunk $chunkIndex (overlay_decoded=$overlayDecoded, mode=$mode, audioDuration=${audioDurationMs}ms)")
        }
    }

    /**
     * Log rendered frame to session logger.
     * Calculates sync status like iOS: compares backend's matchedSpriteFrameNumber % baseFrameCount
     * with the actual base frame being rendered.
     */
    private fun logRenderedFrame(section: OverlaySection, frame: DecodedFrame) {
        if (sessionId == null) {
            Log.w(TAG, "Cannot log frame - sessionId is null")
            return
        }

        totalRenderedFrames++
        animationFrameCount++

        // FPS tracking (iOS-style windowed average)
        val currentTime = SystemClock.elapsedRealtime()
        val fpsDelta = currentTime - fpsLastUpdateTime
        if (fpsDelta >= FPS_UPDATE_INTERVAL_MS) {
            if (animationFrameCount > 0) {
                currentFPS = (animationFrameCount * 1000.0) / fpsDelta
            }
            animationFrameCount = 0
            fpsLastUpdateTime = currentTime
        }

        // Calculate sync status like iOS:
        // isInSync = (matchedSpriteFrameNumber % baseFrameCount) == actualRenderedBaseFrameIndex
        val manager = baseFrameManager
        val animName = frame.animationName.ifEmpty { currentAnimationName }
        val baseFrameCount = manager?.getAnimationFrames(animName)?.size ?: 1
        val expectedBaseFrame = frame.matchedSpriteFrameNumber % maxOf(baseFrameCount, 1)
        val isInSync = expectedBaseFrame == currentRenderedBaseFrameIndex

        val syncStatus = if (isInSync) "SYNC" else "DESYNC"

        // Log debug info for desync
        if (!isInSync) {
            Log.w(TAG, "DESYNC detected: expected=$expectedBaseFrame, actual=$currentRenderedBaseFrameIndex, " +
                    "sprite=${frame.matchedSpriteFrameNumber}, baseCount=$baseFrameCount, anim=$animName")
        }

        SessionLogger.getInstance().logFrame(
            chunk = section.chunkIndex,
            seq = frame.sequenceIndex,
            anim = frame.animationName,
            baseFrame = currentRenderedBaseFrameIndex,
            overlayKey = frame.overlayId ?: "unknown",
            syncStatus = syncStatus,
            fps = currentFPS,
            sprite = frame.matchedSpriteFrameNumber,
            char = frame.char,
            buffer = "${section.frames.size - section.currentDrawingFrame}/${section.totalFrames}",
            nextChunk = overlayQueueLock.withLock { overlayQueue.firstOrNull()?.let { "${it.frames.size}" } ?: "none" }
        )
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Idle Frame Management
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Get frame for idle animation from base frame manager.
     */
    private fun getIdleFrame(timestamp: Long): RenderFrame {
        val manager = baseFrameManager
        if (manager == null) {
            return RenderFrame(
                baseImage = baseFrame,
                overlayImage = null,
                overlayPosition = PointF(0f, 0f),
                timestamp = timestamp
            )
        }

        val idleFrame = manager.advanceFrame()
        val frameToUse = idleFrame ?: manager.getCurrentIdleFrame() ?: baseFrame

        return RenderFrame(
            baseImage = frameToUse,
            overlayImage = null,
            overlayPosition = PointF(0f, 0f),
            timestamp = timestamp
        )
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Legacy Frame Queue (for backward compatibility)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Enqueue decoded frames for playback (legacy method).
     */
    fun enqueueFrames(frames: List<DecodedFrame>, chunkIndex: Int) {
        queueLock.withLock {
            frameQueue.addAll(frames)
            frameQueue.sortBy { it.sequenceIndex }

            if (frameQueue.size >= minimumBufferFrames && !isPlaying) {
                isPlaying = true
                setMode(AnimationMode.TALKING)
            }
        }
    }

    /**
     * Add a chunk to the queue (legacy method).
     */
    fun enqueueChunk(chunk: QueuedAnimationChunk) {
        chunkLock.withLock {
            chunkQueue.add(chunk)
            chunkQueue.sortBy { it.chunkIndex }
        }
    }

    /**
     * Mark a chunk as ready (legacy method).
     */
    fun markChunkReady(chunkIndex: Int) {
        chunkLock.withLock {
            chunkQueue.find { it.chunkIndex == chunkIndex }?.isReady = true
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - State Management
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Set animation mode.
     */
    fun setMode(newMode: AnimationMode) {
        if (mode != newMode) {
            val prevMode = mode
            mode = newMode
            onModeChange?.invoke(newMode)
            Log.d(TAG, "Mode: $prevMode → $newMode")

            // Reset FPS tracking when switching to TALKING
            if (newMode == AnimationMode.TALKING) {
                fpsLastUpdateTime = SystemClock.elapsedRealtime()
                animationFrameCount = 0
                currentFPS = 0.0  // Will be calculated from actual frames
            }
        }
    }

    /**
     * Set overlay position (legacy).
     */
    fun setOverlayPosition(position: PointF) {
        overlayPosition = position
    }

    /**
     * Set base frame (legacy).
     */
    fun setBaseFrame(frame: Bitmap?) {
        baseFrame = frame
    }

    /**
     * Set base frame manager for idle animations.
     */
    fun setBaseFrameManager(manager: BaseFrameManager?) {
        baseFrameManager = manager
    }

    /**
     * Transition to idle and clear all state.
     * Implements iOS forceIdleNow() behavior.
     */
    fun transitionToIdle() {
        // Clear overlay sections
        overlayQueueLock.withLock {
            overlayQueue.clear()
        }
        currentOverlaySection = null

        // Clear legacy frame queue
        queueLock.withLock {
            frameQueue.clear()
            currentFrameIndex = 0
        }
        chunkLock.withLock {
            chunkQueue.clear()
        }

        // Clear audio state
        clearAudioQueue()

        // Reset message lifecycle
        messageActive = false
        audioEndReceived = false
        nextExpectedChunkIndex = 0

        // Reset state
        holdingLastFrame = false
        lastHeldFrame = null
        previousRenderFrame = null
        isPlaying = false

        // Reset SKIP_DRAW timeout
        consecutiveSkipDrawCount = 0
        lastSkipDrawFrame = -1

        // Switch to idle
        baseFrameManager?.switchAnimation("idle_1_s_idle_1_e", 0)
        setMode(AnimationMode.IDLE)

        Log.d(TAG, "💤 Transitioned to idle - all state cleared")
    }

    /**
     * Force immediate transition to idle (matches iOS forceIdleNow).
     */
    fun forceIdleNow() {
        Log.d(TAG, "🔄 forceIdleNow - clearing all caches and state")
        transitionToIdle()
        frameDecoder?.clearAllOverlays()
    }

    /**
     * Clear all queued frames.
     */
    fun clearQueue() {
        overlayQueueLock.withLock {
            overlayQueue.clear()
        }
        currentOverlaySection = null

        queueLock.withLock {
            frameQueue.clear()
            currentFrameIndex = 0
        }
        chunkLock.withLock {
            chunkQueue.clear()
        }
        isPlaying = false
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Buffer Status
    // ═══════════════════════════════════════════════════════════════════════════

    val hasBufferedFrames: Boolean
        get() {
            val section = currentOverlaySection
            if (section != null) {
                return isBufferReady(section)
            }
            return queueLock.withLock { frameQueue.size >= minimumBufferFrames }
        }

    val queuedFrameCount: Int
        get() {
            val section = currentOverlaySection
            if (section != null) {
                return section.frames.size - section.currentDrawingFrame
            }
            return queueLock.withLock { frameQueue.size }
        }

    val pendingChunkCount: Int
        get() = overlayQueueLock.withLock { overlayQueue.size } + chunkLock.withLock { chunkQueue.size }

    val playbackProgress: Float
        get() {
            val section = currentOverlaySection ?: return 0f
            if (section.frames.isEmpty()) return 0f
            return section.currentDrawingFrame.toFloat() / section.frames.size
        }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Playback Control
    // ═══════════════════════════════════════════════════════════════════════════

    fun play() {
        isPlaying = true
    }

    fun pause() {
        isPlaying = false
    }

    fun reset() {
        queueLock.withLock {
            currentFrameIndex = 0
        }
        lastFrameTime = 0
    }

    val isCurrentlyPlaying: Boolean
        get() = isPlaying || currentOverlaySection != null
}
