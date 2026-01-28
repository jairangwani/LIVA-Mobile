package com.liva.animation.rendering

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.RectF
import android.util.Base64
import android.util.LruCache
import com.liva.animation.models.DecodedFrame
import com.liva.animation.models.FrameBatch
import com.liva.animation.models.FrameData
import kotlinx.coroutines.*

/**
 * High-performance frame decoder for base64 images.
 */
internal class FrameDecoder {

    companion object {
        private const val CACHE_SIZE_MB = 50
    }

    // MARK: - Properties

    private val decodeScope = CoroutineScope(Dispatchers.Default + SupervisorJob())

    // LRU cache for decoded bitmaps
    private val imageCache: LruCache<String, Bitmap> = object : LruCache<String, Bitmap>(
        CACHE_SIZE_MB * 1024 * 1024
    ) {
        override fun sizeOf(key: String, bitmap: Bitmap): Int {
            return bitmap.byteCount
        }
    }

    // Track which images are fully decoded (not just cached)
    private val decodedKeys = mutableSetOf<String>()
    private val decodedKeysLock = Any()

    // Bitmap options for reuse
    private val options = BitmapFactory.Options().apply {
        inMutable = true
        inPreferredConfig = Bitmap.Config.ARGB_8888
    }

    // MARK: - Single Frame Decoding

    /**
     * Decode a single frame synchronously.
     */
    fun decodeSync(base64String: String): Bitmap? {
        // Check cache
        val cacheKey = base64String.take(100)
        imageCache.get(cacheKey)?.let { return it }

        return try {
            // Remove data URL prefix if present
            val base64 = if (base64String.contains("base64,")) {
                base64String.substringAfter("base64,")
            } else {
                base64String
            }

            val bytes = Base64.decode(base64, Base64.DEFAULT)
            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)

            // Cache the result
            bitmap?.let { imageCache.put(cacheKey, it) }

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
     * Uses overlay_id from backend if available, otherwise generates from animation/sprite/filename.
     */
    suspend fun decodeWithContentKey(
        base64String: String,
        overlayId: String?,
        animationName: String?,
        spriteNumber: Int?,
        sheetFilename: String?
    ): Pair<String, Bitmap?> = withContext(Dispatchers.Default) {
        // Generate content-based cache key
        val cacheKey = if (!overlayId.isNullOrEmpty()) {
            overlayId  // Prefer backend-provided overlay_id
        } else if (animationName != null && spriteNumber != null && sheetFilename != null) {
            // Fallback: generate content key
            "$animationName/$spriteNumber/$sheetFilename"
        } else {
            // Last resort: use first 100 chars (old behavior)
            base64String.take(100)
        }

        // Check cache
        imageCache.get(cacheKey)?.let { return@withContext cacheKey to it }

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
            imageCache.put(cacheKey, it)
            synchronized(decodedKeysLock) {
                decodedKeys.add(cacheKey)
            }
        }

        cacheKey to bitmap
    }

    /**
     * Check if an image is fully decoded and ready to render.
     */
    fun isImageDecoded(key: String): Boolean {
        return synchronized(decodedKeysLock) {
            decodedKeys.contains(key)
        }
    }

    /**
     * Check if image exists in cache (may not be decoded yet).
     */
    fun hasImage(key: String): Boolean {
        return imageCache.get(key) != null
    }

    /**
     * Get cached image by key.
     */
    fun getImage(key: String): Bitmap? {
        return imageCache.get(key)
    }

    /**
     * Check if first N frames are sequentially decoded and ready.
     * Returns true only if frames 0 through minimumCount-1 are all ready.
     */
    fun areFirstFramesReady(keys: List<String>, minimumCount: Int): Boolean {
        val checkCount = minOf(keys.size, minimumCount)
        var readyCount = 0

        for (i in 0 until checkCount) {
            val key = keys.getOrNull(i) ?: break
            if (isImageDecoded(key)) {
                readyCount++
            } else {
                break  // Must be sequential - stop at first gap
            }
        }

        return readyCount >= minimumCount
    }

    // MARK: - Batch Decoding

    /**
     * Decode a batch of frames with full metadata preservation.
     * Preserves coordinates, matchedSpriteFrameNumber, overlayId, etc.
     * Supports both raw bytes (efficient) and base64 strings (fallback).
     */
    suspend fun decodeBatch(batch: FrameBatch): List<DecodedFrame> = withContext(Dispatchers.Default) {
        val decodedFrames = mutableListOf<DecodedFrame>()

        android.util.Log.d("FrameDecoder", "decodeBatch: chunk=${batch.chunkIndex}, frames=${batch.frames.size}")

        batch.frames.mapNotNull { frameData ->
            async {
                // Check if we have any image data (bytes preferred, base64 fallback)
                if (!frameData.hasImageData()) {
                    android.util.Log.w("FrameDecoder", "No imageData for seq=${frameData.sequenceIndex}")
                    return@async null
                }

                // Generate content-based cache key
                val cacheKey = frameData.overlayId
                    ?: if (frameData.animationName.isNotEmpty() && frameData.sheetFilename.isNotEmpty()) {
                        "${frameData.animationName}/${frameData.spriteIndexFolder}/${frameData.sheetFilename}"
                    } else {
                        "frame_${batch.chunkIndex}_${frameData.sequenceIndex}"
                    }

                // Check cache first
                imageCache.get(cacheKey)?.let { cached ->
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

                // Decode bitmap - prefer raw bytes (skips base64 decode)
                val bitmap = if (frameData.imageBytes != null) {
                    // Direct binary decode (efficient!)
                    try {
                        BitmapFactory.decodeByteArray(frameData.imageBytes, 0, frameData.imageBytes.size, options)
                    } catch (e: Exception) {
                        android.util.Log.w("FrameDecoder", "Failed to decode bytes for seq=${frameData.sequenceIndex}: ${e.message}")
                        null
                    }
                } else {
                    // Base64 decode fallback
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

                // Cache result
                imageCache.put(cacheKey, bitmap)
                synchronized(decodedKeysLock) {
                    decodedKeys.add(cacheKey)
                }

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

        // Sort by sequence index
        decodedFrames.sortedBy { it.sequenceIndex }
    }

    /**
     * Parse coordinates from backend format.
     * Backend sends either per-frame [x, y, width, height] or chunk-level zone_top_left.
     */
    private fun parseCoordinates(coords: List<Float>?, zoneTopLeft: List<Int>?): RectF {
        // Prefer per-frame coordinates
        if (coords != null && coords.size >= 4) {
            return RectF(
                coords[0],
                coords[1],
                coords[0] + coords[2],  // right = x + width
                coords[1] + coords[3]   // bottom = y + height
            )
        }

        // Fallback to chunk-level zone_top_left with default size
        if (zoneTopLeft != null && zoneTopLeft.size >= 2) {
            val x = zoneTopLeft[0].toFloat()
            val y = zoneTopLeft[1].toFloat()
            return RectF(x, y, x + 300f, y + 300f)  // Default 300x300 overlay size
        }

        // No position data
        return RectF()
    }

    /**
     * Clear all overlay frames from cache (called on new message).
     */
    fun clearAllOverlays() {
        imageCache.evictAll()
        synchronized(decodedKeysLock) {
            decodedKeys.clear()
        }
        android.util.Log.d("FrameDecoder", "Cleared all overlay caches and decoded keys")
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

    // MARK: - Cache Management

    /**
     * Clear the image cache.
     */
    fun clearCache() {
        imageCache.evictAll()
    }

    /**
     * Handle memory pressure.
     */
    fun onLowMemory() {
        clearCache()
    }

    /**
     * Cancel all pending operations.
     */
    fun cancel() {
        decodeScope.cancel()
    }
}
