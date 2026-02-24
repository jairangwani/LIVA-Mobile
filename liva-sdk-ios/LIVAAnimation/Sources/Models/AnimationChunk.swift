// @know entity AnimationChunk_iOS
//
//  AnimationChunk.swift
//  LIVAAnimation
//
//  Animation chunk metadata models.
//

import Foundation

/// Animation chunk metadata from receive_audio event
struct AnimationChunkData: Codable {
    let animationName: String
    let sections: [[[String: Any]]]?
    let zoneTopLeft: [Int]
    let masterFramePlayAt: Int
    let mode: String

    enum CodingKeys: String, CodingKey {
        case animationName = "animation_name"
        case sections
        case zoneTopLeft = "zone_top_left"
        case masterFramePlayAt = "master_frame_play_at"
        case mode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        animationName = try container.decode(String.self, forKey: .animationName)
        zoneTopLeft = try container.decode([Int].self, forKey: .zoneTopLeft)
        masterFramePlayAt = try container.decode(Int.self, forKey: .masterFramePlayAt)
        mode = try container.decode(String.self, forKey: .mode)
        sections = nil  // Complex nested type, handle separately
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(animationName, forKey: .animationName)
        try container.encode(zoneTopLeft, forKey: .zoneTopLeft)
        try container.encode(masterFramePlayAt, forKey: .masterFramePlayAt)
        try container.encode(mode, forKey: .mode)
    }
}

/// Audio event data
struct AudioEventData: Codable {
    let audioData: String
    let chunkIndex: Int
    let masterChunkIndex: Int
    let totalFrameImages: Int
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case audioData = "audio_data"
        case chunkIndex = "chunk_index"
        case masterChunkIndex = "master_chunk_index"
        case totalFrameImages = "total_frame_images"
        case timestamp
    }
}
