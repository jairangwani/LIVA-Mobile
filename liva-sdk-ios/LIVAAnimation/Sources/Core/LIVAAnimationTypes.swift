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

    // NOTE: skipFirstAdvance REMOVED - was causing frame 0 to draw twice (jitter bug)
    // The getOverlayDrivenBaseFrame() already handles synchronization correctly.

    /// When playback started (for time-based advancement)
    var startTime: CFTimeInterval?

    /// When section was created (for fallback timing)
    var createdAt: CFTimeInterval = CACurrentMediaTime()

    /// Holding at last frame waiting for next chunk buffer (JITTER FIX)
    var holdingLastFrame: Bool = false
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

// MARK: - Lock Utilities

extension NSLock {
    /// Execute block with lock held, guaranteed unlock via defer
    /// - Parameter block: Code to execute while holding the lock
    /// - Returns: Return value from the block
    /// - Throws: Rethrows any error from the block
    ///
    /// **Usage:**
    /// ```swift
    /// let value = myLock.withLock {
    ///     return protectedData
    /// }
    /// ```
    ///
    /// **Thread Safety:** Always releases lock even if block throws
    func withLock<T>(_ block: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try block()
    }
}

// MARK: - Cache Key Helper

/// Generate cache key for overlay frame (uses unified CacheKeyGenerator)
/// - Parameters:
///   - frame: The overlay frame containing overlayId and animation data
///   - chunkIndex: Chunk index (fallback only)
///   - sectionIndex: Section index (fallback only)
///   - sequenceIndex: Sequence index (fallback only)
/// - Returns: Cache key string (content-based if available, else positional)
func getOverlayCacheKey(for frame: OverlayFrame, chunkIndex: Int, sectionIndex: Int, sequenceIndex: Int) -> String {
    return CacheKeyGenerator.generate(
        overlayId: frame.overlayId,
        animationName: frame.animationName,
        spriteNumber: frame.matchedSpriteFrameNumber,
        sheetFilename: frame.sheetFilename,
        fallbackChunk: chunkIndex,
        fallbackSection: sectionIndex,
        fallbackSequence: sequenceIndex
    )
}

// MARK: - Image Decompression Helper

/// Force image decompression on background thread to prevent render thread blocking
/// - Parameter rawImage: Image to decompress
/// - Returns: Decompressed image ready for rendering
///
/// **Performance:**
/// - iOS 15+: Uses optimized `preparingForDisplay()` API
/// - iOS 14-: Falls back to bitmap context drawing
///
/// **Why needed:**
/// UIImage is lazily decoded. First draw triggers expensive decompression on render thread.
/// Pre-decompressing on background prevents frame drops during animation.
///
/// **Usage:** Call from background queue before caching or rendering
func forceImageDecompression(_ rawImage: UIImage) -> UIImage {
    if #available(iOS 15.0, *), let prepared = rawImage.preparingForDisplay() {
        // iOS 15+ has optimized pre-rendering (faster than bitmap context)
        return prepared
    } else {
        // Fallback: draw to bitmap context to force decompression
        let size = rawImage.size
        let scale = rawImage.scale
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        rawImage.draw(in: CGRect(origin: .zero, size: size))
        let decompressed = UIGraphicsGetImageFromCurrentImageContext() ?? rawImage
        UIGraphicsEndImageContext()
        return decompressed
    }
}

