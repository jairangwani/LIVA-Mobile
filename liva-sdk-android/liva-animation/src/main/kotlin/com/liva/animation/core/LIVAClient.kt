package com.liva.animation.core

import android.content.Context
import android.graphics.PointF
import android.os.Handler
import android.os.Looper
import android.graphics.BitmapFactory
import com.liva.animation.audio.AudioPlayer
import com.liva.animation.models.DecodedFrame
import com.liva.animation.rendering.AnimationEngine
import com.liva.animation.rendering.AnimationMode
import com.liva.animation.rendering.BaseFrameManager
import com.liva.animation.rendering.FrameDecoder
import com.liva.animation.rendering.LIVACanvasView
import com.liva.animation.rendering.QueuedAnimationChunk
import com.liva.animation.rendering.ANIMATION_LOAD_ORDER
import com.liva.animation.logging.SessionLogger
import kotlinx.coroutines.*

/**
 * Main client for LIVA Animation SDK.
 *
 * Usage:
 * ```kotlin
 * val config = LIVAConfiguration(
 *     serverUrl = "https://api.liva.com",
 *     userId = "user-123",
 *     agentId = "1"
 * )
 * LIVAClient.getInstance().initialize(context)
 * LIVAClient.getInstance().configure(config)
 * LIVAClient.getInstance().attachView(canvasView)
 * LIVAClient.getInstance().connect()
 * ```
 */
class LIVAClient private constructor() {

    companion object {
        private const val TAG = "LIVAClient"

        @Volatile
        private var instance: LIVAClient? = null

        fun getInstance(): LIVAClient {
            return instance ?: synchronized(this) {
                instance ?: LIVAClient().also { instance = it }
            }
        }
    }

    // MARK: - Properties

    /** Current configuration */
    var configuration: LIVAConfiguration? = null
        private set

    /** Current connection state */
    var state: LIVAState = LIVAState.Idle
        private set(value) {
            if (field != value) {
                field = value
                mainHandler.post { onStateChange?.invoke(value) }
            }
        }

    /** Whether the client is currently connected */
    val isConnected: Boolean
        get() = socketManager?.isConnected == true

    // MARK: - Callbacks

    /** Called when connection state changes */
    var onStateChange: ((LIVAState) -> Unit)? = null

    /** Called when an error occurs */
    var onError: ((LIVAError) -> Unit)? = null

    // MARK: - Components

    private val mainHandler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    private var context: Context? = null
    private var socketManager: LIVASocketManager? = null
    private var frameDecoder: FrameDecoder? = null
    private var animationEngine: AnimationEngine? = null
    private var audioPlayer: AudioPlayer? = null
    private var baseFrameManager: BaseFrameManager? = null
    private var canvasView: LIVACanvasView? = null

    // MARK: - State Tracking

    private val currentChunkFrames = mutableMapOf<Int, MutableList<DecodedFrame>>()
    private val pendingOverlayPositions = mutableMapOf<Int, PointF>()

    // Batch processing tracking
    private val pendingBatchCount = mutableMapOf<Int, Int>()
    private val batchLock = Any()

    // MARK: - Base Frame Loading State

    private var isBaseFramesLoaded: Boolean = false
    private var pendingConnect: Boolean = false

    // MARK: - Public Methods

    /**
     * Initialize the SDK with Android context.
     * Must be called before configure().
     * @param context Application or Activity context
     */
    fun initialize(context: Context) {
        this.context = context.applicationContext
    }

    /**
     * Configure the SDK with connection parameters.
     * @param config Configuration object
     */
    fun configure(config: LIVAConfiguration) {
        val ctx = context ?: throw IllegalStateException("Must call initialize() before configure()")

        this.configuration = config

        // Initialize components
        frameDecoder = FrameDecoder()
        animationEngine = AnimationEngine()
        audioPlayer = AudioPlayer(ctx.cacheDir)
        baseFrameManager = BaseFrameManager(ctx)

        setupAnimationEngineCallbacks()
        setupAudioPlayerCallbacks()
        setupBaseFrameManagerCallbacks()

        // Try to load base frames from cache
        loadBaseFramesFromCache()
    }

    /**
     * Attach a canvas view for rendering.
     * @param view The canvas view to render to
     */
    fun attachView(view: LIVACanvasView) {
        this.canvasView = view
        view.animationEngine = animationEngine
    }

    /**
     * Connect to the backend server.
     */
    fun connect() {
        val config = configuration ?: run {
            handleError(LIVAError.NotConfigured)
            return
        }

        state = LIVAState.Connecting

        // Create socket manager
        socketManager = LIVASocketManager(config)
        setupSocketCallbacks()
        socketManager?.connect()
    }

    /**
     * Disconnect from the server.
     */
    fun disconnect() {
        // End session logging
        SessionLogger.getInstance().endSession()

        canvasView?.stopRenderLoop()
        audioPlayer?.stop()
        animationEngine?.clearQueue()
        socketManager?.disconnect()
        socketManager = null
        state = LIVAState.Idle
    }

    // MARK: - Base Animation Loading

    private var currentAnimationLoadIndex = 0

    /**
     * Request base animations from server in sequence.
     * Starts with idle animation which unlocks the UI.
     */
    private fun requestBaseAnimations() {
        currentAnimationLoadIndex = 0
        requestNextAnimation()
    }

    private fun requestNextAnimation() {
        if (currentAnimationLoadIndex < ANIMATION_LOAD_ORDER.size) {
            val animationType = ANIMATION_LOAD_ORDER[currentAnimationLoadIndex]
            android.util.Log.d("LIVAClient", "Requesting animation: $animationType (${currentAnimationLoadIndex + 1}/${ANIMATION_LOAD_ORDER.size})")
            socketManager?.requestBaseAnimation(animationType)
        }
    }

    // MARK: - Socket Callbacks

    private fun setupSocketCallbacks() {
        val socket = socketManager ?: return

        socket.onConnect = {
            android.util.Log.d("LIVAClient", "🔥 SOCKET CONNECTED - onConnect callback START")
            state = LIVAState.Connected
            // DON'T start render loop here - wait for first idle frame to arrive
            // Render loop is started in onFirstIdleFrameReady callback to avoid
            // flickering (rendering null frames before any frame data arrives)

            android.util.Log.d("LIVAClient", "🔥 About to start session logging")
            // Start session logging
            val config = configuration
            android.util.Log.d(TAG, "About to start session logging, config=$config")
            if (config != null) {
                android.util.Log.d(TAG, "Config valid: serverUrl=${config.serverUrl}, userId=${config.userId}, agentId=${config.agentId}")
                val sessionLogger = SessionLogger.getInstance()
                android.util.Log.d(TAG, "Got SessionLogger instance")
                sessionLogger.configure(config.serverUrl)
                android.util.Log.d(TAG, "Configured SessionLogger with ${config.serverUrl}")
                val sessionId = sessionLogger.startSession(config.userId, config.agentId)
                android.util.Log.d(TAG, "startSession returned: $sessionId")
                if (sessionId != null) {
                    android.util.Log.d(TAG, "Session logging started: $sessionId")

                    // Pass session ID to animation engine for frame logging
                    animationEngine?.setSessionId(sessionId)
                    android.util.Log.d(TAG, "Set session ID on AnimationEngine")
                } else {
                    android.util.Log.w(TAG, "startSession returned null!")
                }
            } else {
                android.util.Log.w(TAG, "Configuration is null, cannot start session logging")
            }

            // Request base animation frames from server (backend won't send until requested)
            requestBaseAnimations()
        }

        socket.onDisconnect = { reason ->
            canvasView?.stopRenderLoop()
            if (state != LIVAState.Idle) {
                state = LIVAState.Error(LIVAError.SocketDisconnected)
            }
        }

        socket.onError = { error ->
            if (error is LIVAError) {
                handleError(error)
            } else {
                handleError(LIVAError.Unknown(error.message ?: "Unknown error"))
            }
        }

        socket.onAudioReceived = { audioChunk ->
            handleAudioReceived(audioChunk)
        }

        socket.onFrameBatchReceived = { frameBatch ->
            handleFrameBatchReceived(frameBatch)
        }

        socket.onChunkReady = { chunkIndex, totalSent ->
            handleChunkReady(chunkIndex, totalSent)
        }

        socket.onAudioEnd = {
            handleAudioEnd()
        }

        socket.onPlayBaseAnimation = { animationName ->
            handlePlayBaseAnimation(animationName)
        }

        // Base frame events
        socket.onAnimationTotalFrames = { animationName, totalFrames ->
            handleAnimationTotalFrames(animationName, totalFrames)
        }

        socket.onBaseFrameReceived = { animationName, frameIndex, data ->
            handleBaseFrameReceived(animationName, frameIndex, data)
        }

        socket.onAnimationFramesComplete = { animationName ->
            handleAnimationFramesComplete(animationName)
        }
    }

    // MARK: - Event Handlers

    private fun handleAudioReceived(audioChunk: com.liva.animation.models.AudioChunk) {
        // CRITICAL: Clear overlay cache on first chunk (new message response)
        if (audioChunk.chunkIndex == 0) {
            frameDecoder?.clearAllOverlays()
            animationEngine?.clearQueue()
            android.util.Log.d(TAG, "Cleared overlay cache for new message")

            // Log event
            SessionLogger.getInstance().logEvent("NEW_MESSAGE", mapOf(
                "chunk" to 0
            ))
        }

        // Update state to animating
        if (state == LIVAState.Connected) {
            state = LIVAState.Animating
        }

        // AUDIO-VIDEO SYNC: Queue audio in animation engine (don't play immediately)
        // Audio will start when first overlay frame renders
        animationEngine?.queueAudioForChunk(audioChunk.chunkIndex, audioChunk.audioData)
        android.util.Log.d(TAG, "Queued audio for chunk ${audioChunk.chunkIndex} - waiting for animation sync")

        // Store overlay position for this chunk
        audioChunk.animationMetadata?.let { metadata ->
            pendingOverlayPositions[audioChunk.chunkIndex] = PointF(
                metadata.zoneTopLeft.first.toFloat(),
                metadata.zoneTopLeft.second.toFloat()
            )
        }
    }

    private fun handleFrameBatchReceived(frameBatch: com.liva.animation.models.FrameBatch) {
        val chunkIndex = frameBatch.chunkIndex
        val frames = frameBatch.frames

        // Increment pending batch count IMMEDIATELY (track pending work)
        synchronized(batchLock) {
            pendingBatchCount[chunkIndex] = (pendingBatchCount[chunkIndex] ?: 0) + 1
        }

        // Process in background with batching and yields
        scope.launch(Dispatchers.Default) {
            // Process first frame immediately (unblock playback)
            if (frames.isNotEmpty()) {
                val firstFrameDecoded = frameDecoder?.decodeBatch(
                    frameBatch.copy(frames = listOf(frames[0]))
                ) ?: emptyList()

                if (firstFrameDecoded.isNotEmpty()) {
                    synchronized(currentChunkFrames) {
                        if (currentChunkFrames[chunkIndex] == null) {
                            currentChunkFrames[chunkIndex] = mutableListOf()
                        }
                        currentChunkFrames[chunkIndex]?.addAll(firstFrameDecoded)
                    }
                }
            }

            // Process remaining frames in batches of 15 with yields
            val BATCH_SIZE = 15
            for (i in 1 until frames.size step BATCH_SIZE) {
                val batchEnd = minOf(i + BATCH_SIZE, frames.size)
                val batch = frames.subList(i, batchEnd)

                // Decode batch
                val decodedBatch = frameDecoder?.decodeBatch(
                    frameBatch.copy(frames = batch)
                ) ?: emptyList()

                // Store results
                synchronized(currentChunkFrames) {
                    currentChunkFrames[chunkIndex]?.addAll(decodedBatch)
                }

                // Yield to event loop (prevent blocking)
                delay(0)
            }

            // Decrement pending count and check if all batches complete
            withContext(Dispatchers.Main) {
                onBatchComplete(chunkIndex)
            }
        }
    }

    private fun onBatchComplete(chunkIndex: Int) {
        val allBatchesComplete = synchronized(batchLock) {
            val count = pendingBatchCount[chunkIndex] ?: 0
            if (count > 1) {
                pendingBatchCount[chunkIndex] = count - 1
                false
            } else {
                pendingBatchCount.remove(chunkIndex)
                true
            }
        }

        if (allBatchesComplete) {
            android.util.Log.d(TAG, "All batches complete for chunk $chunkIndex")
            // Chunk ready processing can now proceed
        }
    }

    private fun handleChunkReady(chunkIndex: Int, totalSent: Int) {
        // Check if batches are still processing
        val hasPendingBatches = synchronized(batchLock) {
            pendingBatchCount.containsKey(chunkIndex)
        }

        if (hasPendingBatches) {
            android.util.Log.d(TAG, "Deferring chunk_ready for chunk $chunkIndex (batches still processing)")
            // onBatchComplete will not trigger chunk ready - we'll need to manually check
            // For now, just wait a bit and retry
            Handler(Looper.getMainLooper()).postDelayed({
                handleChunkReady(chunkIndex, totalSent)
            }, 100)
            return
        }

        // Get all frames for this chunk
        val frames: List<DecodedFrame>
        synchronized(currentChunkFrames) {
            frames = currentChunkFrames[chunkIndex]?.toList() ?: return
        }

        if (frames.isEmpty()) return

        // Get overlay position
        val overlayPosition = pendingOverlayPositions[chunkIndex] ?: PointF(0f, 0f)

        // Create animation chunk
        val animationChunk = QueuedAnimationChunk(
            chunkIndex = chunkIndex,
            frames = frames,
            overlayPosition = overlayPosition,
            animationName = frames.firstOrNull()?.animationName ?: "",
            isReady = true
        )

        // Queue for animation
        animationEngine?.enqueueChunk(animationChunk)

        // Also add frames directly for immediate playback
        animationEngine?.enqueueFrames(frames, chunkIndex)
        animationEngine?.setOverlayPosition(overlayPosition)

        // Clean up stored frames
        synchronized(currentChunkFrames) {
            currentChunkFrames.remove(chunkIndex)
        }
        pendingOverlayPositions.remove(chunkIndex)
    }

    private fun handleAudioEnd() {
        // Audio streaming is complete, animation will transition to idle
        // after current frames are played
        animationEngine?.onAnimationComplete = {
            if (state == LIVAState.Animating) {
                state = LIVAState.Connected
            }
            animationEngine?.transitionToIdle()
        }
    }

    private fun handlePlayBaseAnimation(animationName: String) {
        // Handle base/idle animation request
        animationEngine?.transitionToIdle()
        if (state == LIVAState.Animating) {
            state = LIVAState.Connected
        }
    }

    // MARK: - Base Frame Event Handlers

    private fun handleAnimationTotalFrames(animationName: String, totalFrames: Int) {
        android.util.Log.d("LIVAClient", "Animation registered: $animationName with $totalFrames frames")
        baseFrameManager?.registerAnimation(animationName, totalFrames)
    }

    private fun handleBaseFrameReceived(animationName: String, frameIndex: Int, data: ByteArray) {
        val bitmap = BitmapFactory.decodeByteArray(data, 0, data.size)
        if (bitmap == null) {
            android.util.Log.e("LIVAClient", "Failed to decode frame $frameIndex for $animationName")
            return
        }
        if (frameIndex == 0) {
            android.util.Log.d("LIVAClient", "Received first frame for $animationName (${bitmap.width}x${bitmap.height})")
        }
        baseFrameManager?.addFrame(bitmap, animationName, frameIndex)
    }

    private fun handleAnimationFramesComplete(animationName: String) {
        android.util.Log.d("LIVAClient", "Animation complete: $animationName")

        // Animation complete, check if idle is ready
        if (animationName == "idle_1_s_idle_1_e" && !isBaseFramesLoaded) {
            isBaseFramesLoaded = true
            notifyIdleReady()
        }

        // Request next animation in sequence
        currentAnimationLoadIndex++
        requestNextAnimation()
    }

    // MARK: - Base Frame Manager Callbacks

    private fun setupBaseFrameManagerCallbacks() {
        baseFrameManager?.onAnimationLoaded = { animationName ->
            // Animation fully loaded
        }

        baseFrameManager?.onLoadProgress = { animationName, progress ->
            // Update loading progress if UI wants to show it
        }

        baseFrameManager?.onFirstIdleFrameReady = {
            // First idle frame received - can start showing avatar
            android.util.Log.d("LIVAClient", "First idle frame ready - setting up rendering")
            animationEngine?.setBaseFrameManager(baseFrameManager)
            canvasView?.setBaseFrameManager(baseFrameManager)
            canvasView?.startRenderLoop()
        }
    }

    private fun loadBaseFramesFromCache() {
        // Try to load from disk cache
        for (animationName in ANIMATION_LOAD_ORDER) {
            if (baseFrameManager?.loadFromCache(animationName) == true) {
                if (animationName == "idle_1_s_idle_1_e") {
                    isBaseFramesLoaded = true
                }
            }
        }
    }

    private fun notifyIdleReady() {
        // Idle animation is fully loaded, animation can start
        animationEngine?.setBaseFrameManager(baseFrameManager)

        // If waiting to connect, proceed now
        if (pendingConnect) {
            pendingConnect = false
            // Continue with connection flow
        }
    }

    // MARK: - Animation Engine Callbacks

    private fun setupAnimationEngineCallbacks() {
        animationEngine?.onModeChange = { mode ->
            when (mode) {
                AnimationMode.TALKING -> {
                    if (state == LIVAState.Connected) {
                        state = LIVAState.Animating
                    }
                }
                AnimationMode.IDLE, AnimationMode.TRANSITION -> {
                    if (state == LIVAState.Animating) {
                        state = LIVAState.Connected
                    }
                }
            }
        }

        animationEngine?.onChunkComplete = { chunkIndex ->
            // Chunk animation complete - logging/tracking if needed
        }

        // AUDIO-VIDEO SYNC: Trigger audio playback when first frame renders
        animationEngine?.onStartAudioForChunk = { chunkIndex, audioData ->
            // Called by animation engine when first overlay frame is about to render
            // This ensures audio starts in perfect sync with animation
            audioPlayer?.queueAudio(audioData, chunkIndex)
            android.util.Log.d(TAG, "🔊 Playing audio for chunk $chunkIndex - synced with first overlay frame")
        }
    }

    // MARK: - Audio Player Callbacks

    private fun setupAudioPlayerCallbacks() {
        audioPlayer?.onChunkStart = { chunkIndex ->
            // Audio chunk started - sync with animation if needed
        }

        audioPlayer?.onChunkComplete = { chunkIndex ->
            // Audio chunk complete
        }

        audioPlayer?.onPlaybackComplete = {
            // All audio complete
            animationEngine?.transitionToIdle()
            if (state == LIVAState.Animating) {
                state = LIVAState.Connected
            }
        }
    }

    // MARK: - Error Handling

    private fun handleError(error: LIVAError) {
        state = LIVAState.Error(error)
        mainHandler.post {
            onError?.invoke(error)
        }
    }

    // MARK: - Memory Management

    /**
     * Call this when the system reports low memory.
     */
    fun onLowMemory() {
        frameDecoder?.onLowMemory()
        animationEngine?.clearQueue()
    }

    // MARK: - Debug Info

    /** Debug description of current state */
    val debugDescription: String
        get() = """
            LIVAClient:
              State: $state
              Connected: $isConnected
              Animation queue: ${animationEngine?.queuedFrameCount ?: 0} frames
              Audio queue: ${audioPlayer?.queuedChunkCount ?: 0} chunks
        """.trimIndent()

    // MARK: - Cleanup

    /**
     * Release all resources.
     */
    fun release() {
        disconnect()
        scope.cancel()
        frameDecoder?.cancel()
        audioPlayer?.release()
        baseFrameManager?.release()
        instance = null
    }
}
