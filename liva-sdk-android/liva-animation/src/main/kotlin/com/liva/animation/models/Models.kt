package com.liva.animation.models

import android.graphics.Bitmap
import android.graphics.RectF
import com.google.gson.annotations.SerializedName

/**
 * Raw frame data from server.
 * Supports both base64 string (imageData) and raw bytes (imageBytes) for efficiency.
 * When Socket.IO sends binary data, we store it in imageBytes to avoid base64 overhead.
 */
data class FrameData(
    @SerializedName("image_data") val imageData: String = "",        // Base64 string (legacy/fallback)
    val imageBytes: ByteArray? = null,                                // Raw bytes (preferred, skips base64 decode)
    @SerializedName("image_mime") val imageMime: String,
    @SerializedName("sprite_index_folder") val spriteIndexFolder: Int,
    @SerializedName("sheet_filename") val sheetFilename: String,
    @SerializedName("animation_name") val animationName: String,
    @SerializedName("sequence_index") val sequenceIndex: Int,
    @SerializedName("section_index") val sectionIndex: Int,
    @SerializedName("frame_index") val frameIndex: Int,
    @SerializedName("matched_sprite_frame_number") val matchedSpriteFrameNumber: Int,
    @SerializedName("char") val char: String,
    @SerializedName("overlay_id") val overlayId: String? = null,  // Content-based cache key from backend
    @SerializedName("coordinates") val coordinates: List<Float>? = null,  // [x, y, width, height] per-frame position
    @SerializedName("zone_top_left") val zoneTopLeft: List<Int>? = null   // Chunk-level fallback position
) {
    // Convenience: Check if we have image data (either format)
    fun hasImageData(): Boolean = imageBytes != null || imageData.isNotEmpty()
}

/**
 * Frame batch received from server.
 */
data class FrameBatch(
    val frames: List<FrameData>,
    @SerializedName("chunk_index") val chunkIndex: Int,
    @SerializedName("batch_index") val batchIndex: Int,
    @SerializedName("total_batches") val totalBatches: Int
)

/**
 * Decoded frame ready for rendering.
 * Matches iOS OverlayFrame structure for parity.
 */
data class DecodedFrame(
    val image: Bitmap,
    val sequenceIndex: Int,
    val animationName: String,
    // NEW: Per-frame overlay position (x, y, width, height)
    val coordinates: RectF = RectF(),
    // NEW: Base frame number to sync with (critical for lip sync)
    val matchedSpriteFrameNumber: Int = 0,
    // NEW: Content-based cache key (for deduplication)
    val overlayId: String? = null,
    // NEW: Sprite sheet filename
    val sheetFilename: String = "",
    // NEW: Character being spoken (for debug logging)
    val char: String? = null,
    // NEW: Section index within chunk
    val sectionIndex: Int = 0,
    // NEW: Original frame index from backend
    val originalFrameIndex: Int = 0
)

/**
 * Overlay section state tracking.
 * Matches iOS OverlaySection/OverlayState for animation playback.
 */
data class OverlaySection(
    val frames: List<DecodedFrame>,
    val chunkIndex: Int,
    val sectionIndex: Int,
    val animationName: String,
    val zoneTopLeft: Pair<Int, Int>,
    val totalFrames: Int,

    // Mutable playback state
    var playing: Boolean = false,
    var currentDrawingFrame: Int = 0,
    var done: Boolean = false,
    var holdingLastFrame: Boolean = false,  // JITTER FIX: Hold while waiting for next chunk
    var startTime: Long? = null,            // For time-based frame advancement
    var audioStarted: Boolean = false,

    // Audio-paced frame advancement: sync overlay to audio playback position
    var audioTriggerTime: Long? = null,     // SystemClock.elapsedRealtime() when audio triggered
    var audioDurationMs: Long = 0           // PCM-computed duration for this chunk's audio
)

/**
 * Audio chunk received from server.
 */
data class AudioChunk(
    val audioData: ByteArray,
    val chunkIndex: Int,
    val animationMetadata: AnimationMetadata?
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false
        other as AudioChunk
        return chunkIndex == other.chunkIndex
    }

    override fun hashCode(): Int = chunkIndex
}

/**
 * Animation metadata from audio chunk.
 */
data class AnimationMetadata(
    val animationName: String,
    val zoneTopLeft: Pair<Int, Int>,
    val masterFramePlayAt: Int,
    val mode: String
)

/**
 * Agent configuration from backend.
 */
data class AgentConfig(
    @SerializedName("agent_id") val id: String,
    val name: String,
    val description: String?,
    @SerializedName("voice_id") val voiceId: String?,
    val status: String
)
