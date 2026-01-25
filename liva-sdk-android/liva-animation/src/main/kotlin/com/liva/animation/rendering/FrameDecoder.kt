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

    // MARK: - Batch Decoding

    /**
     * Decode a batch of frames.
     */
    suspend fun decodeBatch(batch: FrameBatch): List<DecodedFrame> = withContext(Dispatchers.Default) {
        val decodedFrames = mutableListOf<DecodedFrame>()

        batch.frames.mapNotNull { frameData ->
            async {
                decodeSync(frameData.imageData)?.let { bitmap ->
                    DecodedFrame(
                        image = bitmap,
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
