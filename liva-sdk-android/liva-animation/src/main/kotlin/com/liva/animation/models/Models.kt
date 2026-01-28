package com.liva.animation.models

import android.graphics.Bitmap
import com.google.gson.annotations.SerializedName

/**
 * Raw frame data from server.
 */
data class FrameData(
    @SerializedName("image_data") val imageData: String,
    @SerializedName("image_mime") val imageMime: String,
    @SerializedName("sprite_index_folder") val spriteIndexFolder: Int,
    @SerializedName("sheet_filename") val sheetFilename: String,
    @SerializedName("animation_name") val animationName: String,
    @SerializedName("sequence_index") val sequenceIndex: Int,
    @SerializedName("section_index") val sectionIndex: Int,
    @SerializedName("frame_index") val frameIndex: Int,
    @SerializedName("matched_sprite_frame_number") val matchedSpriteFrameNumber: Int,
    @SerializedName("char") val char: String,
    @SerializedName("overlay_id") val overlayId: String? = null  // Content-based cache key from backend
)

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
 */
data class DecodedFrame(
    val image: Bitmap,
    val sequenceIndex: Int,
    val animationName: String
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
