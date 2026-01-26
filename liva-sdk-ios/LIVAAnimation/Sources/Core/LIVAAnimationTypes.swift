//
//  LIVAAnimationTypes.swift
//  LIVAAnimation
//
//  Created by Claude Code on 2026-01-26.
//  Copyright © 2026 LIVA. All rights reserved.
//

import UIKit

// MARK: - Animation Mode

/// Current animation playback mode
enum AnimationMode {
    case idle           // Playing idle animation loop
    case overlay        // Playing overlay (lip sync) on top of base animation
    case transition     // Transitioning between animations
}

// MARK: - Overlay Frame

/// Single overlay frame (lip sync frame)
struct OverlayFrame {
    /// Which base frame this overlay should be displayed with
    let matchedSpriteFrameNumber: Int

    /// Sprite sheet filename
    let sheetFilename: String

    /// Position and size on canvas (x, y, width, height)
    let coordinates: CGRect

    /// Binary image data (PNG/WEBP/JPEG)
    var imageData: Data?

    /// Position in the overlay sequence
    let sequenceIndex: Int

    /// Animation name (e.g., "talking_1_s_talking_1_e")
    let animationName: String

    /// Original frame index from backend
    let originalFrameIndex: Int

    /// Unique overlay ID for tracking
    let overlayId: String?

    /// Character data (for debugging)
    let char: String?
    let viseme: String?
}

// MARK: - Overlay Section

/// Chunk of overlay animation (one streaming chunk from backend)
struct OverlaySection {
    /// Mode (usually "lips_data")
    let mode: String

    /// Array of overlay frames in this section
    let frames: [OverlayFrame]

    /// Section index within the chunk
    let sectionIndex: Int

    /// Chunk index (0, 1, 2, ...)
    let chunkIndex: Int

    /// Top-left position for overlay zone
    let zoneTopLeft: CGPoint

    /// Unique set ID for tracking
    let uniqueSetId: Int

    /// Total frames in the full animation
    let animationTotalFrames: Int
}

// MARK: - Overlay State

/// Playback state for an overlay section
struct OverlayState {
    /// Is this section currently playing?
    var playing: Bool = false

    /// Current frame position in frames array
    var currentDrawingFrame: Int = 0

    /// Has this section finished playing?
    var done: Bool = false

    /// Has audio been started for this section?
    var audioStarted: Bool = false

    /// Skip first frame advance for sync (set when starting)
    var skipFirstAdvance: Bool = true

    /// When playback started (for time-based advancement)
    var startTime: CFTimeInterval?

    /// When section was created (for fallback timing)
    var createdAt: CFTimeInterval = CACurrentMediaTime()
}

// MARK: - Queued Overlay

/// Overlay chunk waiting in queue to be played
struct QueuedOverlay {
    /// The overlay section data
    let section: OverlaySection

    /// Animation name for this overlay
    let animationName: String

    /// When this was added to queue (for buffer wait tracking)
    var queuedAt: CFTimeInterval = CACurrentMediaTime()
}

// MARK: - Overlay Driven Frame

/// Information about which base frame to display (driven by overlay data)
struct OverlayDrivenFrame {
    /// Animation name to use
    let animationName: String

    /// Base frame index to display
    let frameIndex: Int

    /// Which overlay section is driving this
    let sectionIndex: Int

    /// Should we start playing this overlay?
    let shouldStartPlaying: Bool

    /// Chunk index
    let chunkIndex: Int
}

// MARK: - Safe Array Access

extension Array {
    /// Safe array access - returns nil if index out of bounds
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Cache Key Helper

/// Generate cache key for overlay frame
/// - Parameters:
///   - chunkIndex: Chunk index
///   - sectionIndex: Section index
///   - sequenceIndex: Sequence index (position in frames array)
/// - Returns: Cache key string (format: "chunk_section_sequence")
func getOverlayKey(chunkIndex: Int, sectionIndex: Int, sequenceIndex: Int) -> String {
    return "\(chunkIndex)_\(sectionIndex)_\(sequenceIndex)"
}
