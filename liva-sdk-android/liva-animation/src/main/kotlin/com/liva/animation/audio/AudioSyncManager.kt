// @know entity AudioSyncManager_Android
package com.liva.animation.audio

import com.liva.animation.rendering.AnimationEngine
import com.liva.animation.rendering.AnimationMode
import kotlinx.coroutines.*

/**
 * Synchronizes audio playback with frame rendering.
 */
internal class AudioSyncManager(
    private val audioPlayer: AudioPlayer,
    private val animationEngine: AnimationEngine
) {
    private var currentFrame = 0
    private val framesPerChunk = 45

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    fun startSync() {
        currentFrame = 0
        animationEngine.setMode(AnimationMode.TALKING)
    }

    fun onChunkComplete(chunkIndex: Int) {
        val expectedFrame = (chunkIndex + 1) * framesPerChunk
        // TODO: Implement sync adjustment
    }

    fun stopSync() {
        animationEngine.setMode(AnimationMode.IDLE)
        currentFrame = 0
    }

    fun onAudioEnd() {
        scope.launch {
            delay(500)
            animationEngine.setMode(AnimationMode.IDLE)
        }
    }

    fun cancel() {
        scope.cancel()
    }
}
