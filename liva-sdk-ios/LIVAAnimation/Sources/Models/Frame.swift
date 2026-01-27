//
//  Frame.swift
//  LIVAAnimation
//
//  Frame data models.
//

import Foundation

/// Raw frame data from server
struct FrameData: Codable {
    let imageData: String
    let imageMime: String
    let spriteIndexFolder: Int
    let sheetFilename: String
    let animationName: String
    let sequenceIndex: Int
    let sectionIndex: Int
    let frameIndex: Int
    let matchedSpriteFrameNumber: Int
    let char: String
    let overlayId: String?  // Content-based cache key from backend (matches web)

    enum CodingKeys: String, CodingKey {
        case imageData = "image_data"
        case imageMime = "image_mime"
        case spriteIndexFolder = "sprite_index_folder"
        case sheetFilename = "sheet_filename"
        case animationName = "animation_name"
        case sequenceIndex = "sequence_index"
        case sectionIndex = "section_index"
        case frameIndex = "frame_index"
        case matchedSpriteFrameNumber = "matched_sprite_frame_number"
        case char
        case overlayId = "overlay_id"
    }

    /// Generate content-based cache key (same format as web)
    /// Format: "{animation_name}/{matched_sprite_frame_number}/{sheet_filename}"
    var contentBasedCacheKey: String {
        // Use backend's overlay_id if available
        if let overlayId = overlayId, !overlayId.isEmpty {
            return overlayId
        }
        // Fallback: construct from available fields (matches web format)
        return "\(animationName)/\(matchedSpriteFrameNumber)/\(sheetFilename)"
    }
}
