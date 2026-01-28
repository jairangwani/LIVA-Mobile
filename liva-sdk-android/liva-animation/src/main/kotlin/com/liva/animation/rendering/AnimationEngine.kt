package com.liva.animation.rendering

import android.graphics.Bitmap
import android.graphics.PointF
import android.util.Log
import com.liva.animation.models.DecodedFrame
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
 * Manages animation frame timing and queue.
 */
internal class AnimationEngine {

    // MARK: - Properties

    var mode: AnimationMode = AnimationMode.IDLE
        private set

    var currentAnimationName: String = ""
        private set

    // Session logging
    private var sessionId: String? = null
    private var totalRenderedFrames = 0
    private var currentChunkIndex = 0
    private var currentSequenceIndex = 0

    // Skip-frame-on-wait logic
    private var shouldSkipFrameAdvance = false
    private var lastRenderFrame: RenderFrame? = null

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

    private val bufferThreshold = 10

    // MARK: - Callbacks

    var onModeChange: ((AnimationMode) -> Unit)? = null
    var onChunkComplete: ((Int) -> Unit)? = null
    var onAnimationComplete: (() -> Unit)? = null

    // Audio-video sync callback (triggers audio playback when first frame renders)
    var onStartAudioForChunk: ((chunkIndex: Int, audioData: ByteArray) -> Unit)? = null

    // MARK: - Audio Sync State

    // Audio data queued per chunk (waiting for animation sync)
    private val pendingAudioChunks = mutableMapOf<Int, ByteArray>()
    private val audioChunkLock = ReentrantLock()

    // Track which chunks have already started audio (prevent duplicate playback)
    private val audioStartedForChunk = mutableSetOf<Int>()

    // MARK: - Configuration

    var minimumBufferFrames: Int = 10
    var loopIdleAnimations: Boolean = true

    /**
     * Set session ID for logging
     */
    fun setSessionId(sessionId: String) {
        this.sessionId = sessionId
        Log.d(TAG, "Session ID set for frame logging: $sessionId")
    }

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

    // MARK: - Frame Queue Management

    /**
     * Enqueue decoded frames for playback.
     */
    fun enqueueFrames(frames: List<DecodedFrame>, chunkIndex: Int) {
        queueLock.withLock {
            frameQueue.addAll(frames)
            frameQueue.sortBy { it.sequenceIndex }

            if (frameQueue.size >= bufferThreshold && !isPlaying) {
                isPlaying = true
                setMode(AnimationMode.TALKING)
            }
        }
    }

    /**
     * Add a chunk to the queue.
     */
    fun enqueueChunk(chunk: QueuedAnimationChunk) {
        chunkLock.withLock {
            chunkQueue.add(chunk)
            chunkQueue.sortBy { it.chunkIndex }
        }
    }

    /**
     * Mark a chunk as ready.
     */
    fun markChunkReady(chunkIndex: Int) {
        chunkLock.withLock {
            chunkQueue.find { it.chunkIndex == chunkIndex }?.isReady = true
        }
    }

    /**
     * Set the overlay position.
     */
    fun setOverlayPosition(position: PointF) {
        overlayPosition = position
    }

    /**
     * Set the base frame.
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
     * Set animation mode.
     */
    fun setMode(newMode: AnimationMode) {
        if (mode != newMode) {
            mode = newMode
            onModeChange?.invoke(newMode)
        }
    }

    /**
     * Clear all queued frames.
     */
    fun clearQueue() {
        queueLock.withLock {
            frameQueue.forEach { it.image.recycle() }
            frameQueue.clear()
            currentFrameIndex = 0
        }

        chunkLock.withLock {
            chunkQueue.clear()
        }

        isPlaying = false
    }

    /**
     * Transition to idle.
     * Implements simple iOS-style direct switching (no transition animations).
     */
    fun transitionToIdle() {
        queueLock.withLock {
            // Clear talking animation frames
            frameQueue.forEach { it.image.recycle() }
            frameQueue.clear()
            currentFrameIndex = 0
        }

        // Clear audio state
        clearAudioQueue()

        // Switch base frame manager back to idle animation
        baseFrameManager?.switchAnimation("idle_1_s_idle_1_e", 0)

        // Set mode to idle
        setMode(AnimationMode.IDLE)

        // Reset playing flag
        isPlaying = false

        Log.d(TAG, "💤 Transitioned to idle - frames cleared, audio stopped, base animation reset")
    }

    // MARK: - Frame Retrieval

    /**
     * Get the next frame for rendering.
     */
    fun getNextFrame(): RenderFrame? {
        val currentTime = System.currentTimeMillis()

        // Reset skip flag
        shouldSkipFrameAdvance = false

        if (currentTime - lastFrameTime < mode.frameIntervalMs) {
            return getCurrentRenderFrame(currentTime)
        }

        lastFrameTime = currentTime

        // Handle idle mode with base frame manager
        if (mode == AnimationMode.IDLE) {
            val idleFrame = getIdleFrame(currentTime)
            if (idleFrame.baseImage == null) {
                Log.w(TAG, "getNextFrame IDLE returning NULL baseImage!")
            }
            lastRenderFrame = idleFrame
            return idleFrame
        }

        // Get current base frame from manager
        val currentBaseFrame = baseFrameManager?.getCurrentIdleFrame() ?: baseFrame
        if (currentBaseFrame == null) {
            Log.w(TAG, "getNextFrame TALKING: currentBaseFrame is NULL (manager=${baseFrameManager != null}, baseFrame=${baseFrame != null})")
        }

        var overlayImage: Bitmap? = null

        queueLock.withLock {
            if (frameQueue.isNotEmpty()) {
                if (currentFrameIndex < frameQueue.size) {
                    overlayImage = frameQueue[currentFrameIndex].image

                    // AUDIO-VIDEO SYNC: Trigger audio when first overlay frame is about to render
                    if (currentFrameIndex == 0 && mode == AnimationMode.TALKING) {
                        triggerAudioForCurrentChunk()
                    }

                    currentFrameIndex++
                }

                if (currentFrameIndex >= frameQueue.size) {
                    if (mode == AnimationMode.TALKING) {
                        if (hasMoreChunks()) {
                            loadNextChunk()
                        } else {
                            currentFrameIndex = frameQueue.size - 1
                            overlayImage = frameQueue.lastOrNull()?.image
                        }
                    }
                }
            }
        }

        val renderFrame = RenderFrame(
            baseImage = currentBaseFrame,
            overlayImage = overlayImage,
            overlayPosition = overlayPosition,
            timestamp = currentTime
        )

        // Cache for skip-frame scenarios
        lastRenderFrame = renderFrame

        // Log rendered frame to session logger
        if (sessionId != null && overlayImage != null) {
            totalRenderedFrames++

            // Calculate FPS
            val deltaTime = currentTime - lastFrameTime
            val fps = if (deltaTime > 0) 1000.0 / deltaTime else 0.0

            SessionLogger.getInstance().logFrame(
                chunk = currentChunkIndex,
                seq = currentSequenceIndex,
                anim = currentAnimationName,
                baseFrame = 0,  // TODO: Get actual base frame index
                overlayKey = "overlay_${currentFrameIndex}",  // TODO: Get actual overlay key
                syncStatus = "SYNC",
                fps = fps
            )
        }

        return renderFrame
    }

    /**
     * Trigger audio playback for current chunk (if not already started).
     * Called when first overlay frame is about to render - ensures audio-video sync.
     */
    private fun triggerAudioForCurrentChunk() {
        // Check if audio already started for this chunk
        if (audioStartedForChunk.contains(currentChunkIndex)) {
            return
        }

        // Get queued audio data for this chunk
        val audioData = audioChunkLock.withLock {
            pendingAudioChunks[currentChunkIndex]
        }

        if (audioData != null) {
            // Mark as started
            audioStartedForChunk.add(currentChunkIndex)

            // Trigger callback to play audio (synchronized with first frame)
            onStartAudioForChunk?.invoke(currentChunkIndex, audioData)

            Log.d(TAG, "🔊 Started audio for chunk $currentChunkIndex - IN SYNC with first overlay frame")
        } else {
            Log.w(TAG, "No audio data queued for chunk $currentChunkIndex")
        }
    }

    /**
     * Get frame for idle animation from base frame manager.
     */
    private fun getIdleFrame(timestamp: Long): RenderFrame {
        val manager = baseFrameManager
        if (manager == null) {
            // Fallback to static base frame
            Log.w(TAG, "getIdleFrame: No baseFrameManager, using static baseFrame=${baseFrame != null}")
            return RenderFrame(
                baseImage = baseFrame,
                overlayImage = null,
                overlayPosition = PointF(0f, 0f),
                timestamp = timestamp
            )
        }

        // Advance and get next idle frame (10fps handled by mode.frameIntervalMs)
        val idleFrame = manager.advanceFrame()

        // Use the new frame, or fall back to current frame, or fall back to static baseFrame
        // This ensures we NEVER return null for the base image
        val frameToUse = idleFrame
            ?: manager.getCurrentIdleFrame()
            ?: baseFrame

        if (frameToUse == null) {
            Log.w(TAG, "getIdleFrame: ALL FALLBACKS FAILED! advanceFrame=${idleFrame != null}, getCurrentIdleFrame=${manager.getCurrentIdleFrame() != null}, baseFrame=${baseFrame != null}")
        }

        return RenderFrame(
            baseImage = frameToUse,
            overlayImage = null,
            overlayPosition = PointF(0f, 0f),
            timestamp = timestamp
        )
    }

    /**
     * Get current render frame without advancing (between frame intervals).
     * BUG FIX: Now properly uses baseFrameManager instead of just baseFrame.
     */
    private fun getCurrentRenderFrame(timestamp: Long): RenderFrame? {
        // Get base frame from manager (like getIdleFrame does) - FIXED BUG!
        val manager = baseFrameManager
        val currentBaseFrame = manager?.getCurrentIdleFrame() ?: baseFrame

        if (currentBaseFrame == null) {
            Log.w(TAG, "getCurrentRenderFrame: NULL baseFrame! manager=${manager != null}, baseFrame=${baseFrame != null}")
        }

        queueLock.withLock {
            val overlayImage = when {
                frameQueue.isEmpty() -> null
                currentFrameIndex < frameQueue.size -> frameQueue[currentFrameIndex].image
                frameQueue.isNotEmpty() -> frameQueue.last().image
                else -> null
            }

            return RenderFrame(
                baseImage = currentBaseFrame,
                overlayImage = overlayImage,
                overlayPosition = overlayPosition,
                timestamp = timestamp
            )
        }
    }

    // MARK: - Chunk Management

    private fun hasMoreChunks(): Boolean {
        chunkLock.withLock {
            return chunkQueue.isNotEmpty() && chunkQueue.first().isReady
        }
    }

    private fun loadNextChunk() {
        val nextChunk: QueuedAnimationChunk

        chunkLock.withLock {
            if (chunkQueue.isEmpty() || !chunkQueue.first().isReady) return
            nextChunk = chunkQueue.removeAt(0)
        }

        queueLock.withLock {
            val overlapFrames = minOf(5, frameQueue.size)
            if (overlapFrames > 0) {
                val keep = frameQueue.takeLast(overlapFrames)
                frameQueue.clear()
                frameQueue.addAll(keep)
                currentFrameIndex = 0
            } else {
                frameQueue.clear()
                currentFrameIndex = 0
            }

            frameQueue.addAll(nextChunk.frames)
            overlayPosition = nextChunk.overlayPosition
            currentAnimationName = nextChunk.animationName
        }

        onChunkComplete?.invoke(nextChunk.chunkIndex)
    }

    // MARK: - Buffer Status

    val hasBufferedFrames: Boolean
        get() = queueLock.withLock { frameQueue.size >= minimumBufferFrames }

    val queuedFrameCount: Int
        get() = queueLock.withLock { frameQueue.size }

    val pendingChunkCount: Int
        get() = chunkLock.withLock { chunkQueue.size }

    val playbackProgress: Float
        get() = queueLock.withLock {
            if (frameQueue.isEmpty()) 0f
            else currentFrameIndex.toFloat() / frameQueue.size
        }

    // MARK: - Playback Control

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
        get() = isPlaying
}
