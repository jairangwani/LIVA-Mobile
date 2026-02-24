// @know entity SocketManager_Android
package com.liva.animation.core

import android.util.Log
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import com.liva.animation.models.*
import io.socket.client.IO
import io.socket.client.Socket
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import kotlin.math.min
import kotlin.math.pow

/**
 * Manages Socket.IO connection to AnnaOS-API backend.
 */
internal class LIVASocketManager(
    private val configuration: LIVAConfiguration
) {
    companion object {
        private const val TAG = "LIVASocketManager"
        private const val MAX_RECONNECT_ATTEMPTS = 10
        private const val MAX_RECONNECT_DELAY_SECONDS = 30.0
    }

    // MARK: - Properties

    private var socket: Socket? = null
    private val gson = Gson()

    private var reconnectAttempts = 0
    private var isManualDisconnect = false
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    // MARK: - Callbacks

    var onConnect: (() -> Unit)? = null
    var onDisconnect: ((String) -> Unit)? = null
    var onError: ((Exception) -> Unit)? = null
    var onAudioReceived: ((AudioChunk) -> Unit)? = null
    var onFrameBatchReceived: ((FrameBatch) -> Unit)? = null
    var onChunkReady: ((chunkIndex: Int, totalSent: Int) -> Unit)? = null
    var onAudioEnd: (() -> Unit)? = null
    var onPlayBaseAnimation: ((animationName: String) -> Unit)? = null

    // Base frame callbacks
    var onAnimationTotalFrames: ((animationName: String, totalFrames: Int) -> Unit)? = null
    var onBaseFrameReceived: ((animationName: String, frameIndex: Int, imageData: ByteArray) -> Unit)? = null
    var onAnimationFramesComplete: ((animationName: String) -> Unit)? = null

    // Manifest callback
    var onAnimationsManifest: ((animations: Map<String, ManifestAnimationInfo>) -> Unit)? = null

    // MARK: - Connection State

    val isConnected: Boolean
        get() = socket?.connected() == true

    // MARK: - Connection

    /**
     * Connect to the backend server.
     */
    fun connect() {
        isManualDisconnect = false

        try {
            val options = IO.Options().apply {
                forceNew = true
                reconnection = false // We handle reconnection manually
                // Use websocket for better compatibility with room-based emissions
                transports = arrayOf("websocket")
                query = "user_id=${configuration.userId}" +
                        "&agent_id=${configuration.agentId}" +
                        "&instance_id=${configuration.instanceId}" +
                        "&userResolution=${configuration.resolution}"
            }

            socket = IO.socket(URI.create(configuration.serverUrl), options)
            setupEventHandlers()
            socket?.connect()

        } catch (e: Exception) {
            Log.e(TAG, "Connection error: ${e.message}")
            onError?.invoke(LIVAError.ConnectionFailed(e.message ?: "Unknown error"))
        }
    }

    /**
     * Disconnect from the server.
     */
    fun disconnect() {
        isManualDisconnect = true
        socket?.disconnect()
        socket?.off()
        socket = null
        reconnectAttempts = 0
        scope.cancel()
    }

    /**
     * Request base animation frames from the server.
     * The backend won't send frames until this is called.
     */
    fun requestBaseAnimation(animationType: String) {
        Log.d(TAG, "Requesting base animation: $animationType")
        val data = JSONObject().apply {
            put("agentId", configuration.agentId)
            put("animationType", animationType)
        }
        socket?.emit("request_specific_base_animation", data)
    }

    /**
     * Request the animations manifest for cache validation.
     * Backend responds with animation names, frame counts, and version hashes.
     */
    fun requestAnimationsManifest(agentId: String) {
        Log.d(TAG, "Requesting animations manifest for agent: $agentId")
        val data = JSONObject().apply {
            put("agentId", agentId)
        }
        socket?.emit("request_base_animations_manifest", data)
    }

    // MARK: - Event Handlers

    private fun setupEventHandlers() {
        val sock = socket ?: return

        // DEBUG: Log ALL incoming events to diagnose which ones are being received
        sock.onAnyIncoming { args ->
            val eventName = args.firstOrNull()?.toString() ?: "unknown"
            Log.d(TAG, ">>> INCOMING EVENT: $eventName (total args: ${args.size})")
        }

        // Connection events
        sock.on(Socket.EVENT_CONNECT) {
            Log.d(TAG, "Connected to server")
            reconnectAttempts = 0
            scope.launch(Dispatchers.Main) {
                onConnect?.invoke()
            }
        }

        sock.on(Socket.EVENT_DISCONNECT) { args ->
            val reason = args.firstOrNull()?.toString() ?: "unknown"
            Log.d(TAG, "Disconnected: $reason")

            scope.launch(Dispatchers.Main) {
                onDisconnect?.invoke(reason)
            }

            if (!isManualDisconnect) {
                scheduleReconnect()
            }
        }

        sock.on(Socket.EVENT_CONNECT_ERROR) { args ->
            val error = args.firstOrNull()?.toString() ?: "Unknown error"
            Log.e(TAG, "Connection error: $error")
            // Log cause chain for debugging (the real error is often in the cause)
            (args.firstOrNull() as? Exception)?.cause?.let { cause ->
                Log.e(TAG, "Connection error cause: ${cause.message}")
            }
            scope.launch(Dispatchers.Main) {
                onError?.invoke(LIVAError.ConnectionFailed(error))
            }
        }

        // Audio event
        sock.on("receive_audio") { args ->
            handleAudioEvent(args)
        }

        // Frame batch event
        sock.on("receive_frame_images_batch") { args ->
            handleFrameBatchEvent(args)
        }

        // Chunk ready event
        sock.on("chunk_images_ready") { args ->
            handleChunkReadyEvent(args)
        }

        // Audio end event
        sock.on("audio_end") {
            scope.launch(Dispatchers.Main) {
                onAudioEnd?.invoke()
            }
        }

        // Play base animation events
        sock.on("play_base_animation") { args ->
            handlePlayAnimationEvent(args)
        }

        sock.on("play_animation") { args ->
            handlePlayAnimationEvent(args)
        }

        // Base frame events
        sock.on("animation_total_frames") { args ->
            handleAnimationTotalFramesEvent(args)
        }

        sock.on("receive_base_frame") { args ->
            handleBaseFrameEvent(args)
        }

        sock.on("animation_frames_complete") { args ->
            handleAnimationFramesCompleteEvent(args)
        }

        // Manifest event (for cache validation)
        sock.on("base_animations_manifest") { args ->
            handleAnimationsManifestEvent(args)
        }
    }

    // MARK: - Event Parsing

    private fun handleAudioEvent(args: Array<Any>) {
        try {
            val data = args.firstOrNull() as? JSONObject ?: run {
                Log.w(TAG, "receive_audio: No data in args")
                return
            }

            val chunkIndex = data.optInt("chunk_index", -1)
            Log.d(TAG, ">>> receive_audio event: chunk_index=$chunkIndex")

            val audioBase64 = data.optString("audio_data", "")
            if (audioBase64.isEmpty()) {
                Log.w(TAG, "receive_audio: Empty audio_data for chunk $chunkIndex")
                return
            }

            val audioData = android.util.Base64.decode(audioBase64, android.util.Base64.DEFAULT)
            val masterChunkIndex = data.optInt("master_chunk_index", 0)
            val totalFrameImages = data.optInt("total_frame_images", 0)
            val timestamp = data.optString("timestamp", "")

            // Parse animation frames chunk
            val animationFramesChunk = mutableListOf<AnimationFrameChunk>()
            val framesArray = data.optJSONArray("animationFramesChunk")
            if (framesArray != null) {
                for (i in 0 until framesArray.length()) {
                    val frameObj = framesArray.getJSONObject(i)
                    val animationName = frameObj.optString("animation_name", "")
                    val zoneArray = frameObj.optJSONArray("zone_top_left")
                    val zoneX = zoneArray?.optInt(0, 0) ?: 0
                    val zoneY = zoneArray?.optInt(1, 0) ?: 0
                    val masterFramePlayAt = frameObj.optInt("master_frame_play_at", 0)
                    val mode = frameObj.optString("mode", "talking")

                    animationFramesChunk.add(
                        AnimationFrameChunk(
                            animationName = animationName,
                            zoneTopLeft = Pair(zoneX, zoneY),
                            masterFramePlayAt = masterFramePlayAt,
                            mode = mode
                        )
                    )
                }
            }

            val audioChunk = AudioChunk(
                audioData = audioData,
                chunkIndex = chunkIndex,
                animationMetadata = animationFramesChunk.firstOrNull()?.let {
                    AnimationMetadata(
                        animationName = it.animationName,
                        zoneTopLeft = it.zoneTopLeft,
                        masterFramePlayAt = it.masterFramePlayAt,
                        mode = it.mode
                    )
                }
            )

            scope.launch(Dispatchers.Main) {
                onAudioReceived?.invoke(audioChunk)
            }

        } catch (e: Exception) {
            Log.e(TAG, "Error parsing audio event: ${e.message}")
        }
    }

    private fun handleFrameBatchEvent(args: Array<Any>) {
        try {
            Log.d(TAG, ">>> receive_frame_images_batch event received!")
            val data = args.firstOrNull() as? JSONObject ?: run {
                Log.w(TAG, "receive_frame_images_batch: No data in args")
                return
            }

            // Log frame batch summary
            val debugFramesArray = data.optJSONArray("frames")
            Log.d(TAG, "Frame batch: chunk=${data.optInt("chunk_index")}, frames=${debugFramesArray?.length()}")

            val chunkIndex = data.optInt("chunk_index", 0)
            val batchIndex = data.optInt("batch_index", 0)
            val batchStartIndex = data.optInt("batch_start_index", 0)
            val batchSize = data.optInt("batch_size", 0)
            val totalBatches = data.optInt("total_batches", 1)
            val emissionTimestamp = data.optLong("emission_timestamp", 0)

            val frames = mutableListOf<FrameData>()
            val framesArray = data.optJSONArray("frames")
            if (framesArray != null) {
                for (i in 0 until framesArray.length()) {
                    val frameObj = framesArray.getJSONObject(i)

                    // Parse coordinates array [x, y, width, height]
                    val coordsArray = frameObj.optJSONArray("coordinates")
                    val coordinates: List<Float>? = if (coordsArray != null && coordsArray.length() >= 4) {
                        (0 until coordsArray.length()).map { coordsArray.optDouble(it, 0.0).toFloat() }
                    } else {
                        null
                    }

                    // Parse zone_top_left array (chunk-level fallback)
                    val zoneArray = frameObj.optJSONArray("zone_top_left")
                    val zoneTopLeft: List<Int>? = if (zoneArray != null && zoneArray.length() >= 2) {
                        (0 until zoneArray.length()).map { zoneArray.optInt(it, 0) }
                    } else {
                        null
                    }

                    // Handle image_data which may come as String (base64) or byte[] (binary)
                    // Socket.IO sends binary data which we can use directly (more efficient!)
                    val imageDataValue = frameObj.opt("image_data")
                    val imageBytes: ByteArray?
                    val imageDataString: String

                    when (imageDataValue) {
                        is ByteArray -> {
                            // Binary data received - use directly (skips base64 encode/decode)
                            imageBytes = imageDataValue
                            imageDataString = ""
                            if (i == 0) Log.d(TAG, "Frame 0: Binary data received (${imageDataValue.size} bytes)")
                        }
                        is String -> {
                            // Base64 string received
                            imageBytes = null
                            imageDataString = imageDataValue
                            if (i == 0) Log.d(TAG, "Frame 0: Base64 string received (${imageDataValue.length} chars)")
                        }
                        else -> {
                            Log.w(TAG, "Frame $i: Unexpected image_data type: ${imageDataValue?.javaClass?.name}")
                            imageBytes = null
                            imageDataString = ""
                        }
                    }

                    val frame = FrameData(
                        imageData = imageDataString,
                        imageBytes = imageBytes,
                        imageMime = frameObj.optString("image_mime", "image/webp"),
                        spriteIndexFolder = frameObj.optInt("sprite_index_folder", 0),
                        sheetFilename = frameObj.optString("sheet_filename", ""),
                        animationName = frameObj.optString("animation_name", ""),
                        sequenceIndex = frameObj.optInt("sequence_index", 0),
                        sectionIndex = frameObj.optInt("section_index", 0),
                        frameIndex = frameObj.optInt("frame_index", 0),
                        matchedSpriteFrameNumber = frameObj.optInt("matched_sprite_frame_number", 0),
                        char = frameObj.optString("char", ""),
                        // NEW: Parse overlay_id and coordinates for iOS-style rendering
                        overlayId = frameObj.optString("overlay_id", null),
                        coordinates = coordinates,
                        zoneTopLeft = zoneTopLeft
                    )
                    frames.add(frame)
                }
            }

            val batch = FrameBatch(
                frames = frames,
                chunkIndex = chunkIndex,
                batchIndex = batchIndex,
                totalBatches = totalBatches
            )

            scope.launch(Dispatchers.Main) {
                onFrameBatchReceived?.invoke(batch)
            }

        } catch (e: Exception) {
            Log.e(TAG, "Error parsing frame batch: ${e.message}")
        }
    }

    private fun handleChunkReadyEvent(args: Array<Any>) {
        try {
            val data = args.firstOrNull() as? JSONObject ?: return

            val chunkIndex = data.optInt("chunk_index", 0)
            val totalImagesSent = data.optInt("total_images_sent", 0)

            scope.launch(Dispatchers.Main) {
                onChunkReady?.invoke(chunkIndex, totalImagesSent)
            }

        } catch (e: Exception) {
            Log.e(TAG, "Error parsing chunk ready: ${e.message}")
        }
    }

    private fun handleAnimationsManifestEvent(args: Array<Any>) {
        try {
            val data = args.firstOrNull() as? JSONObject ?: return

            if (data.has("error")) {
                Log.e(TAG, "Manifest error: ${data.optString("error")}")
                return
            }

            val animationsObj = data.optJSONObject("animations") ?: return
            val animations = mutableMapOf<String, ManifestAnimationInfo>()

            val keys = animationsObj.keys()
            while (keys.hasNext()) {
                val name = keys.next() as String
                val animObj = animationsObj.optJSONObject(name) ?: continue
                animations[name] = ManifestAnimationInfo(
                    frames = animObj.optInt("frames", 0),
                    version = animObj.optString("version", "")
                )
            }

            Log.d(TAG, "Received animations manifest: ${animations.size} animations")

            scope.launch(Dispatchers.Main) {
                onAnimationsManifest?.invoke(animations)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error parsing animations manifest: ${e.message}")
        }
    }

    private fun handlePlayAnimationEvent(args: Array<Any>) {
        try {
            val data = args.firstOrNull() as? JSONObject ?: return
            val animationName = data.optString("animation_name", "")

            if (animationName.isNotEmpty()) {
                scope.launch(Dispatchers.Main) {
                    onPlayBaseAnimation?.invoke(animationName)
                }
            }

        } catch (e: Exception) {
            Log.e(TAG, "Error parsing play animation: ${e.message}")
        }
    }

    private fun handleAnimationTotalFramesEvent(args: Array<Any>) {
        try {
            val data = args.firstOrNull() as? JSONObject ?: return
            // Backend sends 'animation_type', not 'animation_name'
            val animationType = data.optString("animation_type", "")
            val totalFrames = data.optInt("total_frames", 0)

            Log.d(TAG, "animation_total_frames received: type=$animationType, frames=$totalFrames")

            if (animationType.isNotEmpty() && totalFrames > 0) {
                scope.launch(Dispatchers.Main) {
                    onAnimationTotalFrames?.invoke(animationType, totalFrames)
                }
            }

        } catch (e: Exception) {
            Log.e(TAG, "Error parsing animation total frames: ${e.message}")
        }
    }

    private fun handleBaseFrameEvent(args: Array<Any>) {
        try {
            val data = args.firstOrNull() as? JSONObject ?: return
            // Backend sends 'animation_type', not 'animation_name'
            val animationType = data.optString("animation_type", "")
            val frameIndex = data.optInt("frame_index", -1)

            // Backend nests image data under frame_data.data
            val frameData = data.optJSONObject("frame_data")
            var imageData = frameData?.optString("data", "") ?: ""

            if (animationType.isEmpty() || frameIndex < 0 || imageData.isEmpty()) {
                Log.w(TAG, "receive_base_frame: missing data - type=$animationType, idx=$frameIndex, hasImage=${imageData.isNotEmpty()}")
                return
            }

            Log.d(TAG, "receive_base_frame: type=$animationType, idx=$frameIndex, dataLen=${imageData.length}")

            // Remove data URL prefix if present
            val base64Prefix = "base64,"
            val prefixIndex = imageData.indexOf(base64Prefix)
            if (prefixIndex >= 0) {
                imageData = imageData.substring(prefixIndex + base64Prefix.length)
            }

            val decodedData = android.util.Base64.decode(imageData, android.util.Base64.DEFAULT)

            scope.launch(Dispatchers.Main) {
                onBaseFrameReceived?.invoke(animationType, frameIndex, decodedData)
            }

        } catch (e: Exception) {
            Log.e(TAG, "Error parsing base frame: ${e.message}")
        }
    }

    private fun handleAnimationFramesCompleteEvent(args: Array<Any>) {
        try {
            val data = args.firstOrNull() as? JSONObject ?: return
            // Backend sends 'animation_type', not 'animation_name'
            val animationType = data.optString("animation_type", "")
            val totalFrames = data.optInt("total_frames", 0)

            Log.d(TAG, "animation_frames_complete: type=$animationType, total=$totalFrames")

            if (animationType.isNotEmpty()) {
                scope.launch(Dispatchers.Main) {
                    onAnimationFramesComplete?.invoke(animationType)
                }
            }

        } catch (e: Exception) {
            Log.e(TAG, "Error parsing animation frames complete: ${e.message}")
        }
    }

    // MARK: - Reconnection

    private fun scheduleReconnect() {
        if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
            scope.launch(Dispatchers.Main) {
                onError?.invoke(LIVAError.ConnectionFailed("Max reconnection attempts reached"))
            }
            return
        }

        val delay = min(2.0.pow(reconnectAttempts.toDouble()), MAX_RECONNECT_DELAY_SECONDS)
        reconnectAttempts++

        scope.launch {
            delay((delay * 1000).toLong())
            if (!isManualDisconnect) {
                connect()
            }
        }
    }
}

/**
 * Animation frame chunk metadata.
 */
data class AnimationFrameChunk(
    val animationName: String,
    val zoneTopLeft: Pair<Int, Int>,
    val masterFramePlayAt: Int,
    val mode: String
)

/**
 * Animation info from backend manifest (for cache validation).
 */
data class ManifestAnimationInfo(
    val frames: Int,
    val version: String
)
