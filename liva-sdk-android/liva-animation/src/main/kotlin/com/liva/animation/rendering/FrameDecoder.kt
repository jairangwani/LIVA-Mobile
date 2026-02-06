package com.liva.animation.rendering

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.RectF
import android.util.Base64
import com.liva.animation.models.DecodedFrame
import com.liva.animation.models.FrameBatch
import com.liva.animation.models.FrameData
import kotlinx.coroutines.*

/**
 * Content-addressed overlay image decoder and cache.
 *
 * Architecture: Simple HashMap (not LRU). Overlay images are keyed by content
 * (overlay_id like "talking_1_s_talking_1_e/42/J1_X2_M0.webp"), so the same
 * lip-sync sprite is stored once regardless of how many chunks use it.
 *
 * With J(6)×X(6)×M(6) = 216 max unique sprites per animation type, and typically
 * 2-3 animation types per message, the total unique count is bounded at ~100-200
 * entries (~36-72MB). No eviction needed during playback. clearAll() on new message.
 *
 * No chunk tracking, no LRU eviction, no shared-key protection needed.
 */
internal class FrameDecoder {

    // MARK: - Properties

    private val decodeScope = CoroutineScope(Dispatchers.Default + SupervisorJob())

    // Content-addressed cache: overlay_id → decoded Bitmap.
    // HashMap (not LRU) because all entries are needed until message ends.
    // Bounded by unique overlay count (~200 max), not frame count.
    private val imageCache = HashMap<String, Bitmap>()
    private val imageCacheLock = Any()

    // Track which images are fully decoded and ready to render.
    // Separate from imageCache because decode is async — an entry may be
    // in-flight (coroutine running) but not yet in imageCache.
    private val decodedKeys = mutableSetOf<String>()
    private val decodedKeysLock = Any()

    // Bitmap options for decode
    private val options = BitmapFactory.Options().apply {
        inMutable = true
        inPreferredConfig = Bitmap.Config.ARGB_8888
    }

    // MARK: - Single Frame Decoding

    /**
     * Decode a single frame synchronously.
     */
    fun decodeSync(base64String: String): Bitmap? {
        val cacheKey = base64String.take(100)
        synchronized(imageCacheLock) {
            imageCache[cacheKey]?.let { return it }
        }

        return try {
            val base64 = if (base64String.contains("base64,")) {
                base64String.substringAfter("base64,")
            } else {
                base64String
            }

            val bytes = Base64.decode(base64, Base64.DEFAULT)
            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)

            bitmap?.let {
                synchronized(imageCacheLock) { imageCache[cacheKey] = it }
            }

            bitmap
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Decode a single frame asynchronously.
     */
    suspend fun decode(base64String: String): Bitmap? = withContext(Dispatchers.Default) {
        decodeSync(base64String)
    }

    /**
     * Decode a frame with content-based cache key.
     */
    suspend fun decodeWithContentKey(
        base64String: String,
        overlayId: String?,
        animationName: String?,
        spriteNumber: Int?,
        sheetFilename: String?
    ): Pair<String, Bitmap?> = withContext(Dispatchers.Default) {
        val cacheKey = if (!overlayId.isNullOrEmpty()) {
            overlayId
        } else if (animationName != null && spriteNumber != null && sheetFilename != null) {
            "$animationName/$spriteNumber/$sheetFilename"
        } else {
            base64String.take(100)
        }

        // Check cache
        synchronized(imageCacheLock) {
            imageCache[cacheKey]?.let { return@withContext cacheKey to it }
        }

        // Decode
        val bitmap = try {
            val base64 = if (base64String.contains("base64,")) {
                base64String.substringAfter("base64,")
            } else {
                base64String
            }
            val bytes = Base64.decode(base64, Base64.DEFAULT)
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        } catch (e: Exception) {
            null
        }

        // Cache result and mark as decoded
        bitmap?.let {
            synchronized(imageCacheLock) { imageCache[cacheKey] = it }
            synchronized(decodedKeysLock) { decodedKeys.add(cacheKey) }
        }

        cacheKey to bitmap
    }

    // MARK: - Cache Queries

    /**
     * Check if an image is fully decoded and ready to render.
     */
    fun isImageDecoded(key: String): Boolean {
        return synchronized(decodedKeysLock) { decodedKeys.contains(key) }
    }

    /**
     * Check if image exists in cache.
     */
    fun hasImage(key: String): Boolean {
        return synchronized(imageCacheLock) { imageCache.containsKey(key) }
    }

    /**
     * Get cached image by key.
     */
    fun getImage(key: String): Bitmap? {
        return synchronized(imageCacheLock) { imageCache[key] }
    }

    /**
     * Check if first N frames are sequentially decoded and ready.
     */
    fun areFirstFramesReady(keys: List<String>, minimumCount: Int): Boolean {
        val checkCount = minOf(keys.size, minimumCount)
        var readyCount = 0

        for (i in 0 until checkCount) {
            val key = keys.getOrNull(i) ?: break
            if (isImageDecoded(key)) {
                readyCount++
            } else {
                break  // Must be sequential
            }
        }

        return readyCount >= minimumCount
    }

    // MARK: - Batch Decoding

    /**
     * Decode a batch of frames with full metadata preservation.
     */
    suspend fun decodeBatch(batch: FrameBatch): List<DecodedFrame> = withContext(Dispatchers.Default) {
        val decodedFrames = mutableListOf<DecodedFrame>()

        android.util.Log.d("FrameDecoder", "decodeBatch: chunk=${batch.chunkIndex}, frames=${batch.frames.size}")

        batch.frames.mapNotNull { frameData ->
            async {
                if (!frameData.hasImageData()) {
                    android.util.Log.w("FrameDecoder", "No imageData for seq=${frameData.sequenceIndex}")
                    return@async null
                }

                // Content-based cache key (same sprite = same key across all chunks)
                val cacheKey = frameData.overlayId
                    ?: if (frameData.animationName.isNotEmpty() && frameData.sheetFilename.isNotEmpty()) {
                        "${frameData.animationName}/${frameData.spriteIndexFolder}/${frameData.sheetFilename}"
                    } else {
                        "frame_${batch.chunkIndex}_${frameData.sequenceIndex}"
                    }

                // Check cache first (content dedup — same sprite already decoded = free)
                synchronized(imageCacheLock) { imageCache[cacheKey] }?.let { cached ->
                    // Still mark as decoded in case it was added by another path
                    synchronized(decodedKeysLock) { decodedKeys.add(cacheKey) }
                    return@async DecodedFrame(
                        image = cached,
                        sequenceIndex = frameData.sequenceIndex,
                        animationName = frameData.animationName,
                        coordinates = parseCoordinates(frameData.coordinates, frameData.zoneTopLeft),
                        matchedSpriteFrameNumber = frameData.matchedSpriteFrameNumber,
                        overlayId = cacheKey,
                        sheetFilename = frameData.sheetFilename,
                        char = frameData.char,
                        sectionIndex = frameData.sectionIndex,
                        originalFrameIndex = frameData.frameIndex
                    )
                }

                // Decode bitmap — prefer raw bytes (skips base64 decode)
                val bitmap = if (frameData.imageBytes != null) {
                    try {
                        BitmapFactory.decodeByteArray(frameData.imageBytes, 0, frameData.imageBytes.size, options)
                    } catch (e: Exception) {
                        android.util.Log.w("FrameDecoder", "Failed to decode bytes for seq=${frameData.sequenceIndex}: ${e.message}")
                        null
                    }
                } else {
                    try {
                        val base64 = if (frameData.imageData.contains("base64,")) {
                            frameData.imageData.substringAfter("base64,")
                        } else {
                            frameData.imageData
                        }
                        val bytes = Base64.decode(base64, Base64.DEFAULT)
                        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
                    } catch (e: Exception) {
                        android.util.Log.w("FrameDecoder", "Failed to decode base64 for seq=${frameData.sequenceIndex}: ${e.message}")
                        null
                    }
                }

                if (bitmap == null) {
                    android.util.Log.w("FrameDecoder", "Failed to decode bitmap for seq=${frameData.sequenceIndex}")
                    return@async null
                }

                // Store in cache + mark decoded
                synchronized(imageCacheLock) { imageCache[cacheKey] = bitmap }
                synchronized(decodedKeysLock) { decodedKeys.add(cacheKey) }

                DecodedFrame(
                    image = bitmap,
                    sequenceIndex = frameData.sequenceIndex,
                    animationName = frameData.animationName,
                    coordinates = parseCoordinates(frameData.coordinates, frameData.zoneTopLeft),
                    matchedSpriteFrameNumber = frameData.matchedSpriteFrameNumber,
                    overlayId = cacheKey,
                    sheetFilename = frameData.sheetFilename,
                    char = frameData.char,
                    sectionIndex = frameData.sectionIndex,
                    originalFrameIndex = frameData.frameIndex
                )
            }
        }.awaitAll().filterNotNull().let { frames ->
            decodedFrames.addAll(frames)
        }

        decodedFrames.sortedBy { it.sequenceIndex }
    }

    /**
     * Parse coordinates from backend format.
     */
    private fun parseCoordinates(coords: List<Float>?, zoneTopLeft: List<Int>?): RectF {
        if (coords != null && coords.size >= 4) {
            return RectF(coords[0], coords[1], coords[0] + coords[2], coords[1] + coords[3])
        }
        if (zoneTopLeft != null && zoneTopLeft.size >= 2) {
            val x = zoneTopLeft[0].toFloat()
            val y = zoneTopLeft[1].toFloat()
            return RectF(x, y, x + 300f, y + 300f)
        }
        return RectF()
    }

    // MARK: - Cache Management

    /**
     * Clear all overlays (called on new message via forceIdleNow).
     * This is the ONLY cleanup needed — no per-chunk eviction.
     */
    fun clearAllOverlays() {
        synchronized(imageCacheLock) { imageCache.clear() }
        synchronized(decodedKeysLock) { decodedKeys.clear() }
        android.util.Log.d("FrameDecoder", "Cleared all overlays: cache and decoded keys")
    }

    /**
     * Decode multiple batches.
     */
    suspend fun decodeBatches(
        batches: List<FrameBatch>,
        onProgress: ((completed: Int, total: Int) -> Unit)? = null
    ): List<DecodedFrame> = withContext(Dispatchers.Default) {
        val allFrames = mutableListOf<DecodedFrame>()
        var completed = 0

        batches.forEach { batch ->
            val frames = decodeBatch(batch)
            synchronized(allFrames) {
                allFrames.addAll(frames)
                completed++
            }
            withContext(Dispatchers.Main) {
                onProgress?.invoke(completed, batches.size)
            }
        }

        allFrames.sortedBy { it.sequenceIndex }
    }

    /**
     * Clear the image cache.
     */
    fun clearCache() {
        clearAllOverlays()
    }

    /**
     * Handle memory pressure.
     */
    fun onLowMemory() {
        clearAllOverlays()
    }

    /**
     * Cancel all pending operations.
     */
    fun cancel() {
        decodeScope.cancel()
    }
}
