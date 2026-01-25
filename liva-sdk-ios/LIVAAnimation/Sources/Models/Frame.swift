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
    }
}
