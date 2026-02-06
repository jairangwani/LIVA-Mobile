package com.liva.animation.core

import android.content.Context
import android.graphics.PointF
import android.os.Handler
import android.os.Looper
import android.graphics.BitmapFactory
import com.liva.animation.audio.AudioPlayer
import com.liva.animation.models.DecodedFrame
import com.liva.animation.models.OverlaySection
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

    // Raw frame metadata per chunk (for building OverlaySections before all bitmaps decode)
    private val currentChunkFrameData = mutableMapOf<Int, MutableList<com.liva.animation.models.FrameData>>()

    // Track chunks that have received audio but not yet been enqueued to engine
    // Used to gate audio_end/play_base_animation until all chunks are processed
    private val pendingChunkIndices = mutableSetOf<Int>()
    private var audioEndPending = false

    // 1x1 transparent placeholder for frames not yet decoded (skip-draw handles rendering)
    private val placeholderBitmap: android.graphics.Bitmap by lazy {
        android.graphics.Bitmap.createBitmap(1, 1, android.graphics.Bitmap.Config.ARGB_8888)
    }

    // MARK: - Base Frame Loading State

    private var isBaseFramesLoaded: Boolean = false
    private var pendingConnect: Boolean = false
    private var isBackgroundLoadingStarted: Boolean = false

    // Manifest data for cache version comparison
    private var manifestAnimations: Map<String, ManifestAnimationInfo> = emptyMap()
    private var manifestReceived: Boolean = false

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

        // Connect frame decoder to animation engine for decode-readiness checks
        frameDecoder?.let { decoder ->
            animationEngine?.setFrameDecoder(decoder)
        }

        setupAnimationEngineCallbacks()
        setupAudioPlayerCallbacks()
        setupBaseFrameManagerCallbacks()

        // Check cache existence (lightweight, no frame loading)
        checkCacheExistence()
    }

    /**
     * Attach a canvas view for rendering.
     * @param view The canvas view to render to
     */
    fun attachView(view: LIVACanvasView) {
        this.canvasView = view
        view.animationEngine = animationEngine
        view.diagnosticMode = true  // Enable flicker diagnosis logging

        // INSTANT DISPLAY: Load idle frame 0 from cache synchronously
        // This gives the user something to see before the socket even connects.
        if (baseFrameManager?.hasCachedAnimation("idle_1_s_idle_1_e") == true) {
            val frame0 = baseFrameManager?.loadSingleFrame("idle_1_s_idle_1_e", 0)
            if (frame0 != null) {
                android.util.Log.d(TAG, "Instant display: loaded idle frame 0 from cache (${frame0.width}x${frame0.height})")
                // Use registerAnimation + setFrame directly (not addFrame) to avoid
                // triggering onFirstIdleFrameReady callback and disk re-caching
                baseFrameManager?.registerAnimation("idle_1_s_idle_1_e", 1)
                baseFrameManager?.setFrameDirect("idle_1_s_idle_1_e", 0, frame0)
                animationEngine?.setBaseFrameManager(baseFrameManager)
                canvasView?.setBaseFrameManager(baseFrameManager)
                canvasView?.startRenderLoop()
                isBaseFramesLoaded = true
            }
        }
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
     * Get list of loaded animation names.
     * Include in POST /messages as readyAnimations so backend selects correct animations.
     */
    fun getLoadedAnimations(): List<String> {
        return baseFrameManager?.getLoadedAnimationNames() ?: emptyList()
    }

    /**
     * Prepare for a new message by forcing idle and clearing all caches.
     * MUST be called BEFORE sending POST to /messages (matches Web/iOS behavior).
     * Without this, old animation state can interfere with new response.
     */
    fun prepareForNewMessage() {
        // Stop any currently playing audio
        audioPlayer?.stop()

        // Clear pending frame state
        synchronized(currentChunkFrames) {
            currentChunkFrames.clear()
        }
        pendingOverlayPositions.clear()
        synchronized(batchLock) {
            pendingBatchCount.clear()
            currentChunkFrameData.clear()
            pendingChunkIndices.clear()
            audioEndPending = false
        }

        // Force idle and clear all caches
        animationEngine?.forceIdleNow()

        android.util.Log.d(TAG, "🔄 prepareForNewMessage - forced idle before POST")
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
    /**
     * Request base animations with progressive loading strategy.
     * Priority 1: Idle animation (unlocks UI fast)
     * Priority 2: Remaining animations (background loading)
     */
    private fun requestBaseAnimations() {
        // Reset background loading flag so it re-triggers on this connection
        isBackgroundLoadingStarted = false

        // STARTUP OPTIMIZATION: Request idle first for fast startup
        android.util.Log.d(TAG, "🚀 STARTUP: Requesting idle animation first for fast UI unlock")
        socketManager?.requestBaseAnimation("idle_1_s_idle_1_e")

        // Remaining animations will load in background after idle completes
        // (triggered by onAnimationComplete callback)
    }

    /**
     * Load remaining animations in background (called after idle loads)
     */
    private fun loadRemainingAnimationsInBackground() {
        // Prevent duplicate triggers
        if (isBackgroundLoadingStarted) {
            android.util.Log.d(TAG, "Background loading already started, skipping")
            return
        }
        isBackgroundLoadingStarted = true

        val remainingAnimations = ANIMATION_LOAD_ORDER.filterNot {
            it == "idle_1_s_idle_1_e"
        }

        android.util.Log.d(TAG, "🚀 STARTUP: Loading ${remainingAnimations.size} remaining animations in background")

        // Load animations with small delays to avoid overwhelming server
        scope.launch(Dispatchers.IO) {
            remainingAnimations.forEach { animationName ->
                socketManager?.requestBaseAnimation(animationName)
                delay(50) // Small delay between requests
            }
        }
    }

    @Deprecated("Use progressive loading instead")
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

            // Request manifest for cache validation (replaces direct animation requests)
            val agentId = configuration?.agentId
            if (agentId != null) {
                android.util.Log.d(TAG, "Requesting animations manifest for cache validation")
                socketManager?.requestAnimationsManifest(agentId)

                // Fallback: if manifest doesn't arrive in 5s, use old direct-request flow
                scope.launch {
                    kotlinx.coroutines.delay(5000)
                    if (!manifestReceived) {
                        android.util.Log.w(TAG, "Manifest timeout - falling back to direct animation request")
                        requestBaseAnimations()
                    }
                }
            } else {
                // No agent ID - fall back to direct request
                requestBaseAnimations()
            }
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

        socket.onAnimationsManifest = { animations ->
            handleAnimationsManifest(animations)
        }
    }

    // MARK: - Event Handlers

    private fun handleAudioReceived(audioChunk: com.liva.animation.models.AudioChunk) {
        // NOTE: forceIdleNow() is now called BEFORE POST via prepareForNewMessage()
        // (matches Web/iOS timing). We keep a lightweight safety check here for chunk 0
        // in case prepareForNewMessage() wasn't called (e.g., curl-based testing).
        if (audioChunk.chunkIndex == 0) {
            if (animationEngine?.mode != AnimationMode.IDLE) {
                android.util.Log.w(TAG, "⚠️ Chunk 0 arrived but not in IDLE - prepareForNewMessage() may not have been called. Forcing idle now.")
                audioPlayer?.stop()
                synchronized(currentChunkFrames) { currentChunkFrames.clear() }
                pendingOverlayPositions.clear()
                synchronized(batchLock) {
                    pendingBatchCount.clear()
                    currentChunkFrameData.clear()
                }
                animationEngine?.forceIdleNow()
            }

            // Start new message lifecycle - blocks premature idle transitions
            animationEngine?.startNewMessage()
            audioPlayer?.markMessageActive()

            // Log event
            SessionLogger.getInstance().logEvent("NEW_MESSAGE", mapOf(
                "chunk" to 0
            ))
        }

        // Update state to animating
        if (state == LIVAState.Connected) {
            state = LIVAState.Animating
        }

        // Track this chunk as pending (not yet enqueued to engine)
        synchronized(batchLock) {
            pendingChunkIndices.add(audioChunk.chunkIndex)
        }

        // AUDIO-VIDEO SYNC: Queue audio in animation engine (don't play immediately)
        // Audio will start when first overlay frame renders
        animationEngine?.queueAudioForChunk(audioChunk.chunkIndex, audioChunk.audioData)

        // Pre-decode MP3 → PCM immediately on decode thread (runs in background)
        // By the time animation triggers playback, PCM will be ready — zero decode latency
        audioPlayer?.preDecodeAudio(audioChunk.audioData, audioChunk.chunkIndex)
        android.util.Log.d(TAG, "Queued audio for chunk ${audioChunk.chunkIndex} - pre-decoding + waiting for animation sync")

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

        // Store raw frame metadata immediately (for early section building)
        // and increment pending batch count
        synchronized(batchLock) {
            if (currentChunkFrameData[chunkIndex] == null) {
                currentChunkFrameData[chunkIndex] = mutableListOf()
            }
            currentChunkFrameData[chunkIndex]!!.addAll(frames)
            pendingBatchCount[chunkIndex] = (pendingBatchCount[chunkIndex] ?: 0) + 1
        }

        // Decode in background - populates FrameDecoder's imageCache + decodedKeys.
        // The OverlaySection is built on chunk_images_ready from metadata; the engine's
        // skip-draw + decode-check gate playback until bitmaps are actually ready.
        scope.launch(Dispatchers.Default) {
            // Decode in sub-batches of 15 with yields to avoid blocking
            val BATCH_SIZE = 15
            for (i in frames.indices step BATCH_SIZE) {
                val batchEnd = minOf(i + BATCH_SIZE, frames.size)
                val batch = frames.subList(i, batchEnd)

                frameDecoder?.decodeBatch(
                    frameBatch.copy(frames = batch)
                )

                // Yield to other coroutines
                if (batchEnd < frames.size) delay(0)
            }

            // Decrement pending count
            withContext(Dispatchers.Main) {
                onBatchComplete(chunkIndex)
            }
        }
    }

    private fun onBatchComplete(chunkIndex: Int) {
        synchronized(batchLock) {
            val count = pendingBatchCount[chunkIndex] ?: 0
            if (count > 1) {
                pendingBatchCount[chunkIndex] = count - 1
            } else {
                pendingBatchCount.remove(chunkIndex)
                android.util.Log.d(TAG, "All batches decoded for chunk $chunkIndex (cache populated)")
            }
        }
        // No deferred processing needed - sections are created immediately on chunk_images_ready.
        // Background decode populates FrameDecoder cache; engine's skip-draw gates playback.
    }

    private fun handleChunkReady(chunkIndex: Int, totalSent: Int) {
        // STREAMING DECODE: Create section immediately - don't wait for all batches to finish.
        // The engine's decode-check in the advancement loop + skip-draw gates playback
        // until bitmaps are actually decoded in the FrameDecoder cache.
        processChunkReady(chunkIndex, totalSent)
    }

    private fun processChunkReady(chunkIndex: Int, totalSent: Int) {
        // STREAMING DECODE: Build OverlaySection from raw frame metadata.
        // Use decoded bitmap from FrameDecoder cache where available, placeholder otherwise.
        // The engine's decode-check prevents advancing past undecoded frames.
        val frameDataList: List<com.liva.animation.models.FrameData> = synchronized(batchLock) {
            currentChunkFrameData[chunkIndex]?.toList() ?: emptyList()
        }

        if (frameDataList.isEmpty()) {
            android.util.Log.w(TAG, "No frame data for chunk $chunkIndex - cannot build OverlaySection")
            return
        }

        // Get overlay position (chunk-level fallback)
        val overlayPosition = pendingOverlayPositions[chunkIndex] ?: PointF(0f, 0f)
        val zoneTopLeft = Pair(overlayPosition.x.toInt(), overlayPosition.y.toInt())

        // Build DecodedFrames from metadata + cache
        val sortedData = frameDataList.sortedBy { it.sequenceIndex }
        val animationName = sortedData.firstOrNull()?.animationName ?: ""

        var decodedCount = 0
        val frames = sortedData.map { fd ->
            val cacheKey = generateCacheKey(fd, chunkIndex)
            val cachedBitmap = frameDecoder?.getImage(cacheKey)
            if (cachedBitmap != null) decodedCount++

            DecodedFrame(
                image = cachedBitmap ?: placeholderBitmap,
                sequenceIndex = fd.sequenceIndex,
                animationName = fd.animationName,
                coordinates = parseFrameCoordinates(fd.coordinates, fd.zoneTopLeft),
                matchedSpriteFrameNumber = fd.matchedSpriteFrameNumber,
                overlayId = cacheKey,
                sheetFilename = fd.sheetFilename,
                char = fd.char,
                sectionIndex = fd.sectionIndex,
                originalFrameIndex = fd.frameIndex
            )
        }

        val overlaySection = OverlaySection(
            frames = frames,
            chunkIndex = chunkIndex,
            sectionIndex = 0,
            animationName = animationName,
            zoneTopLeft = zoneTopLeft,
            totalFrames = frames.size
        )

        // Enqueue to animation engine
        animationEngine?.enqueueOverlaySection(overlaySection)

        android.util.Log.d(TAG, "✅ Built OverlaySection: chunk=$chunkIndex, " +
            "frames=${frames.size}, decoded=$decodedCount/${frames.size}, anim=$animationName")

        // Log event
        SessionLogger.getInstance().logEvent("CHUNK_READY", mapOf(
            "chunk" to chunkIndex,
            "frames" to frames.size,
            "decoded" to decodedCount,
            "animation" to animationName
        ))

        // Clean up stored metadata and frame data
        synchronized(batchLock) {
            currentChunkFrameData.remove(chunkIndex)
        }
        synchronized(currentChunkFrames) {
            currentChunkFrames.remove(chunkIndex)
        }
        pendingOverlayPositions.remove(chunkIndex)

        // Remove from pending and check if we should deliver deferred audio_end
        val shouldDeliverAudioEnd = synchronized(batchLock) {
            pendingChunkIndices.remove(chunkIndex)
            audioEndPending && pendingChunkIndices.isEmpty()
        }

        if (shouldDeliverAudioEnd) {
            android.util.Log.d(TAG, "📭 All pending chunks enqueued - delivering deferred audio_end")
            animationEngine?.markAudioEndReceived()
            // Don't markMessageComplete here — audio may still be decoding/playing.
            // AudioPlayer will be stopped by onAllChunksComplete when engine finishes.
        }
    }

    /** Generate cache key matching FrameDecoder's key generation logic. */
    private fun generateCacheKey(fd: com.liva.animation.models.FrameData, chunkIndex: Int): String {
        return fd.overlayId
            ?: if (fd.animationName.isNotEmpty() && fd.sheetFilename.isNotEmpty()) {
                "${fd.animationName}/${fd.spriteIndexFolder}/${fd.sheetFilename}"
            } else {
                "frame_${chunkIndex}_${fd.sequenceIndex}"
            }
    }

    /** Parse coordinates from backend format (matches FrameDecoder.parseCoordinates). */
    private fun parseFrameCoordinates(coords: List<Float>?, zoneTopLeft: List<Int>?): android.graphics.RectF {
        if (coords != null && coords.size >= 4) {
            return android.graphics.RectF(coords[0], coords[1], coords[0] + coords[2], coords[1] + coords[3])
        }
        if (zoneTopLeft != null && zoneTopLeft.size >= 2) {
            val x = zoneTopLeft[0].toFloat()
            val y = zoneTopLeft[1].toFloat()
            return android.graphics.RectF(x, y, x + 300f, y + 300f)
        }
        return android.graphics.RectF()
    }

    private fun handleAudioEnd() {
        // Audio streaming is complete - no more chunks coming from backend.
        // If chunks are still being decoded, defer the signal until all are enqueued.
        val hasPending = synchronized(batchLock) {
            if (pendingChunkIndices.isNotEmpty()) {
                audioEndPending = true
                true
            } else {
                false
            }
        }

        if (hasPending) {
            android.util.Log.d(TAG, "📭 audio_end received but chunks still pending - deferring")
        } else {
            android.util.Log.d(TAG, "📭 audio_end received - all chunks enqueued, marking end")
            animationEngine?.markAudioEndReceived()
            // Don't markMessageComplete here — audio may still be decoding/playing.
        }
    }

    private fun handlePlayBaseAnimation(animationName: String) {
        // Backend sends play_base_animation when message processing is complete.
        // Same gating logic as audio_end.
        val hasPending = synchronized(batchLock) {
            if (pendingChunkIndices.isNotEmpty()) {
                audioEndPending = true
                true
            } else {
                false
            }
        }

        if (hasPending) {
            android.util.Log.d(TAG, "📭 play_base_animation received but chunks still pending - deferring")
        } else {
            android.util.Log.d(TAG, "📭 play_base_animation received - all chunks enqueued, marking end")
            animationEngine?.markAudioEndReceived()
            // Don't markMessageComplete here — audio may still be decoding/playing.
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

        // Save manifest version for cache validation on next startup
        val version = manifestAnimations[animationName]?.version
        if (version != null) {
            baseFrameManager?.saveVersion(animationName, version)
        }

        if (animationName == "idle_1_s_idle_1_e") {
            if (!isBaseFramesLoaded) {
                isBaseFramesLoaded = true
                notifyIdleReady()
            }

            // If not using manifest flow, fall back to old background loading
            if (!manifestReceived) {
                android.util.Log.d(TAG, "STARTUP: Idle complete (no manifest) - starting background loading...")
                loadRemainingAnimationsInBackground()
            }
        }
    }

    /**
     * Handle animations manifest from backend.
     * Compares manifest versions with cached versions and selectively loads from cache or server.
     */
    private fun handleAnimationsManifest(animations: Map<String, ManifestAnimationInfo>) {
        manifestReceived = true
        manifestAnimations = animations
        isBackgroundLoadingStarted = true  // Prevent old background loading path

        android.util.Log.d(TAG, "Received manifest: ${animations.size} animations")

        // Build prioritized list
        val animationNamesSet = animations.keys
        val orderedAnimations = mutableListOf<String>()
        for (name in ANIMATION_LOAD_ORDER) {
            if (animationNamesSet.contains(name)) {
                orderedAnimations.add(name)
            }
        }
        // Add any extras from manifest not in ANIMATION_LOAD_ORDER
        for (name in animations.keys.sorted()) {
            if (!orderedAnimations.contains(name)) {
                orderedAnimations.add(name)
            }
        }

        // Categorize: cache-valid vs needs-download
        val cacheValid = mutableListOf<String>()
        val needsDownload = mutableListOf<String>()

        for (name in orderedAnimations) {
            val manifestInfo = animations[name] ?: continue
            val cachedVersion = baseFrameManager?.getCachedVersion(name)
            val hasCached = baseFrameManager?.hasCachedAnimation(name) == true

            if (hasCached && cachedVersion == manifestInfo.version) {
                cacheValid.add(name)
            } else {
                needsDownload.add(name)
                if (hasCached && cachedVersion != manifestInfo.version) {
                    android.util.Log.d(TAG, "Version mismatch for $name: cached=$cachedVersion, manifest=${manifestInfo.version}")
                }
            }
        }

        android.util.Log.d(TAG, "Cache validation: ${cacheValid.size} from cache, ${needsDownload.size} need download")

        // Load cache-valid animations from disk and request stale/missing from server
        scope.launch(Dispatchers.IO) {
            val idleName = "idle_1_s_idle_1_e"

            // Load idle first if in cache (highest priority)
            if (cacheValid.contains(idleName)) {
                android.util.Log.d(TAG, "Loading $idleName from cache...")
                val success = baseFrameManager?.loadFromCache(idleName) ?: false
                if (success) {
                    withContext(Dispatchers.Main) {
                        if (!isBaseFramesLoaded) {
                            isBaseFramesLoaded = true
                            notifyIdleReady()
                        }
                    }
                    android.util.Log.d(TAG, "Loaded $idleName from cache")
                } else {
                    // Cache corrupted - download instead
                    android.util.Log.w(TAG, "Cache load failed for $idleName, will download")
                    needsDownload.add(0, idleName)
                    cacheValid.remove(idleName)
                }
            }

            // Load remaining cache-valid animations
            for (name in cacheValid) {
                if (name == idleName) continue
                val success = baseFrameManager?.loadFromCache(name) ?: false
                if (success) {
                    android.util.Log.d(TAG, "Loaded $name from cache")
                } else {
                    android.util.Log.w(TAG, "Cache load failed for $name, will download")
                    socketManager?.requestBaseAnimation(name)
                }
                delay(10) // Yield to avoid blocking
            }

            // Request stale/missing animations from server
            if (needsDownload.isNotEmpty()) {
                android.util.Log.d(TAG, "Requesting ${needsDownload.size} animations from server: $needsDownload")
            }
            for (name in needsDownload) {
                socketManager?.requestBaseAnimation(name)
                delay(50)
            }

            val cacheCount = cacheValid.size
            val downloadCount = needsDownload.size
            android.util.Log.d(TAG, "Startup: loaded $cacheCount from cache, requesting $downloadCount from server")
        }
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

    private fun checkCacheExistence() {
        // Lightweight check only - no frame loading.
        // Actual loading happens after manifest validation in handleAnimationsManifest().
        for (animationName in ANIMATION_LOAD_ORDER) {
            if (baseFrameManager?.hasCachedAnimation(animationName) == true) {
                if (animationName == "idle_1_s_idle_1_e") {
                    android.util.Log.d(TAG, "Cache check: idle animation found in cache")
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

        // All chunks complete - message fully played
        animationEngine?.onAllChunksComplete = {
            android.util.Log.d(TAG, "🏁 All chunks complete - message fully played")
            audioPlayer?.markMessageComplete()  // Let playback loop exit naturally after current chunk
            if (state == LIVAState.Animating) {
                state = LIVAState.Connected
            }
        }

        // AUDIO-VIDEO SYNC: Trigger audio playback when first frame renders
        animationEngine?.onStartAudioForChunk = { chunkIndex, audioData ->
            audioPlayer?.queueAudio(audioData, chunkIndex)
            android.util.Log.d(TAG, "🔊 Queued audio to player for chunk $chunkIndex")
        }

        // AUDIO-PACED SYNC: Provide audio duration and elapsed time for frame pacing
        animationEngine?.getAudioDurationForChunk = { chunkIndex ->
            audioPlayer?.getChunkDurationMs(chunkIndex) ?: 0L
        }
        animationEngine?.getAudioElapsedForChunk = { chunkIndex ->
            audioPlayer?.getChunkElapsedMs(chunkIndex) ?: 0L
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
            // All audio complete - engine handles idle transition via onAllChunksComplete
            android.util.Log.d(TAG, "Audio playback complete")
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
