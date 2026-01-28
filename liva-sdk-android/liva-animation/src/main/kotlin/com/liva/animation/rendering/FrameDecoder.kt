package com.liva.animation.rendering

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import android.util.LruCache
import com.liva.animation.models.DecodedFrame
import com.liva.animation.models.FrameBatch
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

    // MARK: - Batch Decoding

    /**
     * Decode a batch of frames.
     */
    suspend fun decodeBatch(batch: FrameBatch): List<DecodedFrame> = withContext(Dispatchers.Default) {
        val decodedFrames = mutableListOf<DecodedFrame>()

        batch.frames.mapNotNull { frameData ->
            async {
                // Use content-based cache keys
                val (cacheKey, bitmap) = decodeWithContentKey(
                    base64String = frameData.imageData,
                    overlayId = frameData.overlayId,
                    animationName = frameData.animationName,
                    spriteNumber = frameData.spriteIndexFolder,
                    sheetFilename = frameData.sheetFilename
                )

                bitmap?.let {
                    DecodedFrame(
                        image = it,
                        sequenceIndex = frameData.sequenceIndex,
                        animationName = frameData.animationName
                    )
                }
            }
        }.awaitAll().filterNotNull().let { frames ->
            decodedFrames.addAll(frames)
        }

        // Sort by sequence index
        decodedFrames.sortedBy { it.sequenceIndex }
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
