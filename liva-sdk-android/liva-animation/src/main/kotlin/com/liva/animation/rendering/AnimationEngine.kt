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
        // Match iOS/Web buffer requirements
        const val MIN_FRAMES_BEFORE_START = 30
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

    // MARK: - Audio Sync State

    // Audio data queued per chunk (waiting for animation sync)
    private val pendingAudioChunks = mutableMapOf<Int, ByteArray>()
    private val audioChunkLock = ReentrantLock()

    // Track which chunks have already started audio (prevent duplicate playback)
    private val audioStartedForChunk = mutableSetOf<Int>()

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

        // If not currently playing, try to start
        if (currentOverlaySection == null && mode != AnimationMode.TALKING) {
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

        Log.d(TAG, "▶️ Started overlay section: chunk=${nextSection.chunkIndex}, frames=${nextSection.frames.size}")
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

        // Time-based frame advancement
        val deltaTime = currentTime - lastAdvanceTime
        lastAdvanceTime = currentTime
        frameAccumulator += deltaTime

        // Advance frames based on accumulated time
        while (frameAccumulator >= FRAME_INTERVAL_MS && !section.done) {
            frameAccumulator -= FRAME_INTERVAL_MS

            // Check jitter fix - hold last frame if next chunk not ready
            if (shouldHoldLastFrame()) {
                frameAccumulator = 0.0
                break
            }

            section.currentDrawingFrame++

            // Check if section complete
            if (section.currentDrawingFrame >= section.frames.size) {
                section.done = true
                onSectionComplete(section)
                break
            }
        }

        // Get current frame
        val frameIndex = minOf(section.currentDrawingFrame, section.frames.size - 1)
        val currentFrame = section.frames.getOrNull(frameIndex)

        if (currentFrame == null) {
            return previousRenderFrame ?: getIdleFrame(currentTime)
        }

        // SKIP-DRAW-ON-WAIT: If overlay not decoded, hold previous frame
        val cacheKey = currentFrame.overlayId
        if (cacheKey != null && frameDecoder?.isImageDecoded(cacheKey) == false) {
            Log.d(TAG, "⏸️ Skip-draw: overlay not decoded, key=$cacheKey")
            return previousRenderFrame ?: getIdleFrame(currentTime)
        }

        // Get base frame synced with overlay
        val baseImage = getBaseFrameForOverlay(currentFrame)

        // Trigger audio on first frame
        if (section.currentDrawingFrame == 0 && !section.audioStarted) {
            section.audioStarted = true
            triggerAudioForChunk(section.chunkIndex)
        }

        // Build render frame
        val renderFrame = RenderFrame(
            baseImage = baseImage,
            overlayImage = currentFrame.image,
            overlayPosition = PointF(currentFrame.coordinates.left, currentFrame.coordinates.top),
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
        Log.d(TAG, "✅ Section complete: chunk=${section.chunkIndex}")
        onChunkComplete?.invoke(section.chunkIndex)

        // Try to start next section
        val hasNext = overlayQueueLock.withLock { overlayQueue.isNotEmpty() }

        if (hasNext) {
            currentOverlaySection = null
            tryStartNextSection()
        } else {
            // All chunks complete - transition to idle
            Log.d(TAG, "🎉 All overlay chunks complete - transitioning to idle")
            currentOverlaySection = null
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
            onStartAudioForChunk?.invoke(chunkIndex, audioData)
            Log.d(TAG, "🔊 Started audio for chunk $chunkIndex - IN SYNC with first overlay frame")
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
            mode = newMode
            onModeChange?.invoke(newMode)
            Log.d(TAG, "Mode changed to: $newMode")

            // Reset FPS tracking when switching to TALKING
            if (newMode == AnimationMode.TALKING) {
                fpsLastUpdateTime = SystemClock.elapsedRealtime()
                animationFrameCount = 0
                currentFPS = 30.0  // Start with target FPS
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

        // Reset state
        holdingLastFrame = false
        lastHeldFrame = null
        previousRenderFrame = null
        isPlaying = false

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
