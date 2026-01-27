//
//  CacheKeyGenerator.swift
//  LIVAAnimation
//
//  Created by Claude Code on 2026-01-27.
//  Copyright © 2026 LIVA. All rights reserved.
//
//  Single source of truth for overlay image cache key generation.
//

import Foundation

/// Generates cache keys for overlay images
///
/// **Priority order:**
/// 1. `overlayId` from backend (content-based, highest priority)
/// 2. Animation/sprite/sheet combination (content-based)
/// 3. Chunk/section/sequence position (positional fallback)
///
/// **Thread Safety:** All methods are thread-safe (stateless struct)
///
/// **Usage:**
/// ```swift
/// let key = CacheKeyGenerator.generate(
///     overlayId: frame.overlayId,
///     animationName: frame.animationName,
///     spriteNumber: frame.matchedSpriteFrameNumber,
///     sheetFilename: frame.sheetFilename
/// )
/// ```
struct CacheKeyGenerator {

    /// Generate content-based cache key (matches web frontend format)
    ///
    /// - Parameters:
    ///   - overlayId: Backend's overlay ID (highest priority if available)
    ///   - animationName: Animation name (e.g., "talking_1_s_talking_1_e")
    ///   - spriteNumber: Matched sprite frame number
    ///   - sheetFilename: Sheet filename (e.g., "J1_X2_M0.webp")
    ///   - fallbackChunk: Chunk index (used only if content keys unavailable)
    ///   - fallbackSection: Section index (used only if content keys unavailable)
    ///   - fallbackSequence: Sequence index (used only if content keys unavailable)
    /// - Returns: Cache key string
    ///
    /// **Priority:**
    /// 1. If `overlayId` is non-empty, return it directly (backend's content-based key)
    /// 2. If animation name and sheet filename are available, return "animationName/spriteNumber/sheetFilename"
    /// 3. If fallback positions provided, return "chunk_section_sequence"
    /// 4. Last resort: return unique UUID-based key
    ///
    /// **Examples:**
    /// - Content-based: `"talking_1_s_talking_1_e/12/J1_X2_M0.webp"`
    /// - Backend overlay ID: `"talking_1_s_talking_1_e/12/J1_X2_M0.webp"` (same format)
    /// - Positional fallback: `"0_0_24"`
    static func generate(
        overlayId: String?,
        animationName: String,
        spriteNumber: Int,
        sheetFilename: String,
        fallbackChunk: Int? = nil,
        fallbackSection: Int? = nil,
        fallbackSequence: Int? = nil
    ) -> String {
        // Priority 1: Use backend's overlay_id if available (highest priority)
        // Backend generates this as content-based key matching web format
        if let overlayId = overlayId, !overlayId.isEmpty {
            return overlayId
        }

        // Priority 2: Content-based key (web format)
        // This ensures same sprite/sheet always gets same key
        if !animationName.isEmpty && !sheetFilename.isEmpty {
            return "\(animationName)/\(spriteNumber)/\(sheetFilename)"
        }

        // Priority 3: Positional fallback (only if content keys unavailable)
        // This can cause cache issues if animation changes but position stays same
        if let chunk = fallbackChunk, let section = fallbackSection, let seq = fallbackSequence {
            return "\(chunk)_\(section)_\(seq)"
        }

        // Priority 4: Last resort - unique key
        // This prevents cache hits but better than wrong cache hit
        return "unknown_\(UUID().uuidString)"
    }
}
