// @know entity BaseFrameManager_Android
package com.liva.animation.rendering

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import kotlinx.coroutines.*
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * Animation loading priority order (matches frontend).
 */
val ANIMATION_LOAD_ORDER = listOf(
    "idle_1_s_idle_1_e",           // First priority - unlocks UI
    "idle_1_e_idle_1_s",           // Idle loop pair
    "idle_1_e_talking_1_s",        // Transition: idle -> talking
    "talking_1_s_talking_1_e",     // Main talking animation
    "talking_1_e_idle_1_s",        // Transition: talking -> idle
    "talking_1_e_talking_1_s",     // Talking loop
    "idle_1_e_hi_1_s",             // Transition: idle -> hi
    "hi_1_s_hi_1_e",               // Hi animation
    "hi_1_e_idle_1_s"              // Transition: hi -> idle
)

/**
 * Base animation with all frames.
 */
data class BaseAnimation(
    val name: String,
    var frames: Array<Bitmap?>,
    val totalFrames: Int,
    var isComplete: Boolean = false
) {
    fun setFrame(bitmap: Bitmap, index: Int) {
        if (index in frames.indices) {
            frames[index] = bitmap
        }
    }

    fun getFrame(index: Int): Bitmap? {
        return if (index in frames.indices) frames[index] else null
    }

    val loadedFrameCount: Int
        get() = frames.count { it != null }

    val loadProgress: Float
        get() = if (totalFrames > 0) loadedFrameCount.toFloat() / totalFrames else 0f

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false
        other as BaseAnimation
        return name == other.name
    }

    override fun hashCode(): Int = name.hashCode()
}

/**
 * Manages base animation frame loading, caching, and retrieval.
 */
class BaseFrameManager(private val context: Context) {
    companion object {
        private const val TAG = "BaseFrameManager"
        private const val CACHE_DIR_NAME = "LIVABaseFrames"
    }

    // MARK: - Properties

    private val animations = ConcurrentHashMap<String, BaseAnimation>()
    private val loadingAnimations = mutableSetOf<String>()
    private val loadedAnimations = mutableSetOf<String>()

    private var currentAnimationName: String = "idle_1_s_idle_1_e"
    private var currentFrameIndex: Int = 0

    private val cacheDirectory: File?
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    // MARK: - Callbacks

    var onAnimationLoaded: ((String) -> Unit)? = null
    var onLoadProgress: ((String, Float) -> Unit)? = null
    var onFirstIdleFrameReady: (() -> Unit)? = null

    // MARK: - Initialization

    init {
        cacheDirectory = File(context.cacheDir, CACHE_DIR_NAME).also {
            it.mkdirs()
        }
    }

    // MARK: - Animation Management

    /**
     * Register an animation with its total frame count.
     * If already registered with a different frame count (e.g., single-frame preview
     * upgraded to full animation), re-registers preserving existing frames.
     */
    @Synchronized
    fun registerAnimation(name: String, totalFrames: Int) {
        val existing = animations[name]
        if (existing == null) {
            animations[name] = BaseAnimation(
                name = name,
                frames = arrayOfNulls(totalFrames),
                totalFrames = totalFrames
            )
            loadingAnimations.add(name)
        } else if (existing.totalFrames != totalFrames) {
            // Re-register with correct frame count, preserving existing frames
            val newFrames = arrayOfNulls<Bitmap>(totalFrames)
            for (i in existing.frames.indices) {
                if (i < totalFrames) {
                    newFrames[i] = existing.frames[i]
                }
            }
            animations[name] = BaseAnimation(
                name = name,
                frames = newFrames,
                totalFrames = totalFrames
            )
            loadingAnimations.add(name)
            loadedAnimations.remove(name)
            Log.d(TAG, "Re-registered $name: ${existing.totalFrames} -> $totalFrames frames")
        }
    }

    /**
     * Add a frame to an animation.
     */
    fun addFrame(bitmap: Bitmap, animationName: String, frameIndex: Int) {
        val animation = animations[animationName] ?: return

        animation.setFrame(bitmap, frameIndex)

        val progress = animation.loadProgress
        val isComplete = animation.loadedFrameCount == animation.totalFrames
        val isFirstIdleFrame = animationName == "idle_1_s_idle_1_e" && frameIndex == 0

        if (isComplete) {
            synchronized(this) {
                animation.isComplete = true
                loadingAnimations.remove(animationName)
                loadedAnimations.add(animationName)
            }
        }

        // Notify progress on main thread
        scope.launch(Dispatchers.Main) {
            onLoadProgress?.invoke(animationName, progress)
        }

        // Check if first idle frame ready
        if (isFirstIdleFrame) {
            scope.launch(Dispatchers.Main) {
                onFirstIdleFrameReady?.invoke()
            }
        }

        // Notify completion
        if (isComplete) {
            scope.launch(Dispatchers.Main) {
                onAnimationLoaded?.invoke(animationName)
            }

            // Cache to disk
            cacheAnimationToDisk(animationName)
        }
    }

    /**
     * Set a frame directly without triggering callbacks, progress, or disk caching.
     * Used for instant display path to avoid side effects.
     */
    fun setFrameDirect(animationName: String, frameIndex: Int, bitmap: Bitmap) {
        val animation = animations[animationName] ?: return
        animation.setFrame(bitmap, frameIndex)
    }

    /**
     * Get the current frame for idle playback.
     */
    @Synchronized
    fun getCurrentIdleFrame(): Bitmap? {
        val animation = animations[currentAnimationName]
        if (animation == null) {
            Log.w(TAG, "getCurrentIdleFrame: animation '$currentAnimationName' not found!")
            return null
        }
        if (animation.loadedFrameCount == 0) {
            Log.w(TAG, "getCurrentIdleFrame: animation '$currentAnimationName' has 0 loaded frames!")
            return null
        }
        val frame = animation.getFrame(currentFrameIndex)
        if (frame == null) {
            Log.w(TAG, "getCurrentIdleFrame: frame $currentFrameIndex is NULL in '$currentAnimationName' (loaded: ${animation.loadedFrameCount}/${animation.totalFrames})")
        }
        return frame
    }

    /**
     * Advance to next frame (for idle looping).
     * Only advances to frames that are actually loaded to prevent flickering.
     */
    @Synchronized
    fun advanceFrame(): Bitmap? {
        val animation = animations[currentAnimationName]
        if (animation == null) {
            Log.w(TAG, "advanceFrame: animation '$currentAnimationName' not found!")
            return null
        }
        if (animation.loadedFrameCount == 0) {
            Log.w(TAG, "advanceFrame: animation '$currentAnimationName' has 0 loaded frames!")
            return null
        }

        // Find the next loaded frame
        val startIndex = currentFrameIndex
        var nextIndex = (currentFrameIndex + 1) % animation.totalFrames
        var attempts = 0

        // Search for next loaded frame, but don't loop forever
        while (animation.getFrame(nextIndex) == null && attempts < animation.totalFrames) {
            nextIndex = (nextIndex + 1) % animation.totalFrames
            attempts++
        }

        // If we found a loaded frame, use it
        val nextFrame = animation.getFrame(nextIndex)
        if (nextFrame != null) {
            currentFrameIndex = nextIndex
            return nextFrame
        }

        // Fallback: stay on current frame if it's loaded
        val currentFrame = animation.getFrame(currentFrameIndex)
        if (currentFrame == null) {
            Log.w(TAG, "advanceFrame: BOTH next AND current frames are NULL! idx=$currentFrameIndex, attempts=$attempts, loaded=${animation.loadedFrameCount}/${animation.totalFrames}")
        }
        return currentFrame
    }

    /**
     * Get frame at specific index.
     */
    fun getFrame(animationName: String, frameIndex: Int): Bitmap? {
        return animations[animationName]?.getFrame(frameIndex)
    }

    /**
     * Switch to a different animation.
     */
    @Synchronized
    fun switchAnimation(name: String, startFrame: Int = 0) {
        if (animations.containsKey(name)) {
            currentAnimationName = name
            currentFrameIndex = startFrame
        }
    }

    /**
     * Get the base frame for a specific animation mode.
     */
    fun getBaseFrame(animationName: String, frameIndex: Int): Bitmap? {
        return animations[animationName]?.getFrame(frameIndex)
    }

    /**
     * Get all loaded frames for an animation as a list.
     * Used by AnimationEngine for base frame sync with overlay.
     */
    fun getAnimationFrames(animationName: String): List<Bitmap> {
        val animation = animations[animationName] ?: return emptyList()
        return animation.frames.filterNotNull()
    }

    // MARK: - Loading State

    /**
     * Check if an animation is loaded.
     */
    @Synchronized
    fun isAnimationLoaded(name: String): Boolean {
        return loadedAnimations.contains(name)
    }

    /**
     * Get list of all fully loaded animation names.
     * Used to populate readyAnimations in POST /messages.
     */
    @Synchronized
    fun getLoadedAnimationNames(): List<String> {
        return loadedAnimations.toList()
    }

    /**
     * Check if idle animation is ready.
     */
    val isIdleReady: Boolean
        get() = isAnimationLoaded("idle_1_s_idle_1_e")

    /**
     * Check if we have at least one idle frame.
     */
    val hasFirstIdleFrame: Boolean
        get() {
            val animation = animations["idle_1_s_idle_1_e"] ?: return false
            return animation.getFrame(0) != null
        }

    /**
     * Get all animations that need loading.
     */
    @Synchronized
    fun getAnimationsToLoad(): List<String> {
        return ANIMATION_LOAD_ORDER.filter { !loadedAnimations.contains(it) }
    }

    /**
     * Total frame count for an animation.
     */
    fun totalFrames(animationName: String): Int {
        return animations[animationName]?.totalFrames ?: 0
    }

    // MARK: - Disk Cache

    private val versionsFile: File?
        get() = cacheDirectory?.let { File(it, "manifest_versions.json") }

    /**
     * Check if an animation exists in the disk cache (has frame_0000.png).
     */
    fun hasCachedAnimation(animationName: String): Boolean {
        val cacheDir = cacheDirectory ?: return false
        val frame0 = File(File(cacheDir, animationName), "frame_0000.png")
        return frame0.exists()
    }

    /**
     * Load a single frame from disk cache without loading the entire animation.
     * Used for instant display of idle frame 0 on startup.
     */
    fun loadSingleFrame(animationName: String, frameIndex: Int): Bitmap? {
        val cacheDir = cacheDirectory ?: return null
        val fileName = String.format("frame_%04d.png", frameIndex)
        val file = File(File(cacheDir, animationName), fileName)
        if (!file.exists()) return null
        return try {
            BitmapFactory.decodeFile(file.absolutePath)
        } catch (e: Exception) {
            Log.e(TAG, "Error loading single frame: ${e.message}")
            null
        }
    }

    /**
     * Save the manifest version for an animation (for cache validation on next startup).
     */
    @Synchronized
    fun saveVersion(animationName: String, version: String) {
        val file = versionsFile ?: return
        try {
            val json = if (file.exists()) {
                JSONObject(file.readText())
            } else {
                JSONObject()
            }
            json.put(animationName, version)
            file.writeText(json.toString())
        } catch (e: Exception) {
            Log.e(TAG, "Error saving version for $animationName: ${e.message}")
        }
    }

    /**
     * Get the cached manifest version for an animation.
     * Returns null if no version stored.
     */
    @Synchronized
    fun getCachedVersion(animationName: String): String? {
        val file = versionsFile ?: return null
        return try {
            if (file.exists()) {
                val json = JSONObject(file.readText())
                if (json.has(animationName)) json.getString(animationName) else null
            } else {
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error reading cached version for $animationName: ${e.message}")
            null
        }
    }

    private fun cacheAnimationToDisk(name: String) {
        val cacheDir = cacheDirectory ?: return
        val animation = animations[name] ?: return
        val frames = animation.frames.toList()

        scope.launch {
            try {
                val animationDir = File(cacheDir, name).also { it.mkdirs() }

                frames.forEachIndexed { index, frame ->
                    frame?.let { bitmap ->
                        val fileName = String.format("frame_%04d.png", index)
                        val file = File(animationDir, fileName)
                        file.outputStream().use { out ->
                            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                        }
                    }
                }

                Log.d(TAG, "Cached animation to disk: $name")
            } catch (e: Exception) {
                Log.e(TAG, "Error caching animation: ${e.message}")
            }
        }
    }

    /**
     * Load animation from disk cache (bulk path).
     * Populates frames directly without per-frame callbacks, progress notifications,
     * or re-caching to disk. Much faster than addFrame() loop.
     */
    fun loadFromCache(animationName: String): Boolean {
        val cacheDir = cacheDirectory ?: return false
        val animationDir = File(cacheDir, animationName)

        if (!animationDir.exists() || !animationDir.isDirectory) {
            return false
        }

        val frameFiles = animationDir.listFiles { file ->
            file.extension == "png"
        }?.sortedBy { it.name } ?: return false

        if (frameFiles.isEmpty()) return false

        val totalFrames = frameFiles.size
        val frames = arrayOfNulls<Bitmap>(totalFrames)
        var loadedCount = 0

        frameFiles.forEachIndexed { index, file ->
            try {
                val bitmap = BitmapFactory.decodeFile(file.absolutePath)
                if (bitmap != null) {
                    frames[index] = bitmap
                    loadedCount++
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error loading frame $index from cache: ${e.message}")
            }
        }

        if (loadedCount == 0) return false

        // Bulk register: directly set the animation with all frames at once
        // This avoids per-frame callbacks, progress notifications, and re-caching
        synchronized(this) {
            val existing = animations[animationName]
            if (existing != null && existing.totalFrames == totalFrames) {
                // Preserve any existing frames (e.g., frame 0 from instant display)
                // but replace with disk-loaded versions
                for (i in frames.indices) {
                    if (frames[i] != null) {
                        existing.frames[i] = frames[i]
                    }
                }
                if (loadedCount == totalFrames) {
                    existing.isComplete = true
                    loadingAnimations.remove(animationName)
                    loadedAnimations.add(animationName)
                }
            } else {
                // New registration or different frame count
                val animation = BaseAnimation(
                    name = animationName,
                    frames = frames,
                    totalFrames = totalFrames,
                    isComplete = loadedCount == totalFrames
                )
                animations[animationName] = animation
                if (loadedCount == totalFrames) {
                    loadingAnimations.remove(animationName)
                    loadedAnimations.add(animationName)
                } else {
                    loadingAnimations.add(animationName)
                }
            }
        }

        Log.d(TAG, "Bulk loaded $animationName from cache: $loadedCount/$totalFrames frames")
        return loadedCount == totalFrames
    }

    /**
     * Clear all cached frames.
     */
    fun clearCache() {
        cacheDirectory?.deleteRecursively()
        cacheDirectory?.mkdirs()
        versionsFile?.delete()

        synchronized(this) {
            animations.clear()
            loadingAnimations.clear()
            loadedAnimations.clear()
            currentFrameIndex = 0
        }
    }

    /**
     * Release resources.
     */
    fun release() {
        scope.cancel()
        // Recycle bitmaps
        animations.values.forEach { animation ->
            animation.frames.forEach { it?.recycle() }
        }
        animations.clear()
    }

    // MARK: - Debug

    val debugDescription: String
        get() {
            val sb = StringBuilder("BaseFrameManager:\n")
            sb.append("  Current: $currentAnimationName @ frame $currentFrameIndex\n")
            sb.append("  Loaded: ${loadedAnimations.size} animations\n")
            sb.append("  Loading: ${loadingAnimations.size} animations\n")

            animations.forEach { (name, anim) ->
                sb.append("  - $name: ${anim.loadedFrameCount}/${anim.totalFrames} frames")
                if (anim.isComplete) sb.append(" [complete]")
                sb.append("\n")
            }

            return sb.toString()
        }
}
