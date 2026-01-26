//
//  LIVAAnimationEngine.swift
//  LIVAAnimation
//
//  Created by Claude Code on 2026-01-26.
//  Copyright © 2026 LIVA. All rights reserved.
//

import UIKit
import os.log

// Debug logger for animation engine
private let animLogger = OSLog(subsystem: "com.liva.animation", category: "AnimationEngine")

/// Log to both os_log and file for debugging
func animLog(_ message: String, type: OSLogType = .debug) {
    os_log("%{public}@", log: animLogger, type: type, message)
    LIVADebugLog.shared.log(message)
}

/// Shared debug log that writes to file
class LIVADebugLog {
    static let shared = LIVADebugLog()
    private var logs: [String] = []
    private let maxLogs = 500
    private let logFileURL: URL?

    init() {
        // Create log file in documents directory
        if let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            logFileURL = documentsPath.appendingPathComponent("liva_debug.log")
            // Clear old log file
            try? FileManager.default.removeItem(at: logFileURL!)
        } else {
            logFileURL = nil
        }
    }

    func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] \(message)"
        logs.append(entry)
        if logs.count > maxLogs {
            logs.removeFirst()
        }
        // Also print to console using NSLog for visibility
        NSLog("%@", message)

        // Write to file
        if let url = logFileURL {
            let line = entry + "\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: url.path) {
                    if let fileHandle = try? FileHandle(forWritingTo: url) {
                        fileHandle.seekToEndOfFile()
                        fileHandle.write(data)
                        fileHandle.closeFile()
                    }
                } else {
                    try? data.write(to: url)
                }
            }
        }
    }

    func getLogs() -> [String] {
        return logs
    }

    func getLogsString() -> String {
        return logs.joined(separator: "\n")
    }
}

/// Core animation rendering engine
/// Handles base animations + overlay frames (lip sync) with synchronized playback
class LIVAAnimationEngine {

    // MARK: - Properties

    /// Current animation mode
    private var mode: AnimationMode = .idle

    /// Current base animation name
    private var currentOverlayBaseName: String = "idle_1_s_idle_1_e"

    /// Global frame index (used in idle mode)
    private var globalFrameIndex: Int = 0

    /// Active overlay sections (chunks being played)
    private var overlaySections: [OverlaySection] = []

    /// Playback state for each section
    private var overlayStates: [OverlayState] = []

    /// Queue of overlays waiting to play
    private var overlayQueue: [QueuedOverlay] = []

    /// Is a set currently playing?
    private var isSetPlaying: Bool = false

    /// Image cache for overlay frames
    private let imageCache = LIVAImageCache()

    /// Base animation frames by name
    private var animationFrames: [String: [UIImage]] = [:]

    /// Expected frame counts from backend (authoritative)
    private var expectedFrameCounts: [String: Int] = [:]

    /// Display link for rendering loop
    private var displayLink: CADisplayLink?

    /// Last frame timestamp
    private var lastFrameTime: CFTimeInterval = 0

    /// Canvas view for rendering
    private weak var canvasView: LIVACanvasView?

    // MARK: - Constants

    /// Idle animation frame rate (FPS)
    private let idleFrameRate: Double = 10.0

    /// Active animation frame rate (FPS) - overlay/transition modes
    private let activeFrameRate: Double = 30.0

    /// Default idle animation name (full name format: state_num_pos_state_num_pos)
    private let defaultIdleAnimation = "idle_1_s_idle_1_e"

    /// Minimum frames needed before starting playback (adaptive buffering)
    private let minFramesBeforeStart = 10

    /// Maximum wait time for buffer (milliseconds)
    private let maxBufferWaitMs: Int = 3000

    // MARK: - Initialization

    init(canvasView: LIVACanvasView) {
        self.canvasView = canvasView
        animLog("[LIVAAnimationEngine] Initialized")
    }

    deinit {
        stopRendering()
    }

    // MARK: - Public API

    /// Start the rendering loop
    func startRendering() {
        guard displayLink == nil else {
            animLog("[LIVAAnimationEngine] Already rendering")
            return
        }

        displayLink = CADisplayLink(target: self, selector: #selector(draw))
        displayLink?.add(to: .main, forMode: .common)
        lastFrameTime = CACurrentMediaTime()

        animLog("[LIVAAnimationEngine] ▶️ Started rendering")
    }

    /// Stop the rendering loop
    func stopRendering() {
        displayLink?.invalidate()
        displayLink = nil

        animLog("[LIVAAnimationEngine] ⏹️ Stopped rendering")
    }

    /// Load base animation frames
    /// - Parameters:
    ///   - name: Animation name (e.g., "idle_1_s")
    ///   - frames: Array of UIImages
    ///   - expectedCount: Expected frame count from backend (optional)
    func loadBaseAnimation(name: String, frames: [UIImage], expectedCount: Int? = nil) {
        animationFrames[name] = frames

        if let count = expectedCount {
            expectedFrameCounts[name] = count
        }

        animLog("[LIVAAnimationEngine] Loaded base animation: \(name), frames: \(frames.count), expected: \(expectedCount ?? frames.count)")
    }

    /// Enqueue overlay set for playback
    /// - Parameters:
    ///   - frames: Array of overlay frames
    ///   - chunkIndex: Chunk index (0, 1, 2, ...)
    ///   - animationName: Base animation name
    ///   - totalFrames: Total frames in overlay sequence
    func enqueueOverlaySet(frames: [OverlayFrame], chunkIndex: Int, animationName: String, totalFrames: Int) {
        let section = OverlaySection(
            mode: "lips_data",
            frames: frames,
            sectionIndex: 0,
            chunkIndex: chunkIndex,
            zoneTopLeft: .zero,
            uniqueSetId: chunkIndex,
            animationTotalFrames: totalFrames
        )

        let queued = QueuedOverlay(
            section: section,
            animationName: animationName
        )

        overlayQueue.append(queued)

        animLog("[LIVAAnimationEngine] 📦 Enqueued overlay chunk \(chunkIndex), frames: \(frames.count), queue length: \(overlayQueue.count)")

        // Start playback if not already playing
        if !isSetPlaying {
            startNextOverlaySetIfAny()
        }
    }

    /// Cache overlay image for later playback
    /// - Parameters:
    ///   - image: Overlay image
    ///   - key: Cache key (format: "chunkIndex_sectionIndex_sequenceIndex")
    ///   - chunkIndex: Chunk index for batch eviction
    func cacheOverlayImage(_ image: UIImage, forKey key: String, chunkIndex: Int) {
        imageCache.setImage(image, forKey: key, chunkIndex: chunkIndex)
    }

    /// Get overlay image from cache
    /// - Parameter key: Cache key
    /// - Returns: Cached image if available
    func getOverlayImage(forKey key: String) -> UIImage? {
        return imageCache.getImage(forKey: key)
    }

    /// Reset to idle state
    func reset() {
        mode = .idle
        currentOverlayBaseName = defaultIdleAnimation
        globalFrameIndex = 0
        overlaySections.removeAll()
        overlayStates.removeAll()
        overlayQueue.removeAll()
        isSetPlaying = false
        imageCache.clearAll()

        animLog("[LIVAAnimationEngine] 🔄 Reset to idle")
    }

    /// Force immediate transition to idle and clear all caches
    /// Call this when a new message is about to be sent to prevent stale overlay reuse
    /// This matches web frontend's forceIdleNow() behavior
    func forceIdleNow() {
        // Stop any playing overlays
        mode = .idle
        globalFrameIndex = 0

        // Clear all overlay state
        overlaySections.removeAll()
        overlayStates.removeAll()
        overlayQueue.removeAll()
        isSetPlaying = false

        // CRITICAL: Clear overlay image cache to prevent stale overlays from previous response
        // Without this, chunk indices reset to 0 but old images at key "0_0_0" etc. would be reused
        // This caused visual desync in web frontend (fixed 2026-01-26) - same fix needed here
        imageCache.clearAll()

        animLog("[LIVAAnimationEngine] 🔄 forceIdleNow - cleared all caches and state")
    }

    // MARK: - Rendering Loop

    private var drawCallCount = 0

    /// Enable detailed frame sync logging (set to true to debug frame matching)
    var frameSyncDebugEnabled: Bool = true

    @objc private func draw(link: CADisplayLink) {
        let now = link.timestamp
        let elapsed = now - lastFrameTime

        // Throttle to 30 FPS (overlay/transition) or 10 FPS (idle)
        let isIdleMode = mode == .idle
        let frameDuration = isIdleMode ? (1.0 / idleFrameRate) : (1.0 / activeFrameRate)

        guard elapsed >= frameDuration else { return }

        lastFrameTime = now
        drawCallCount += 1

        // Log every 100 frames to avoid spam (summary)
        if drawCallCount % 100 == 1 {
            animLog("[LIVAAnimationEngine] 🎨 Draw #\(drawCallCount): mode=\(mode), overlaySections=\(overlaySections.count), queue=\(overlayQueue.count)")
        }

        // 1. Determine base frame to draw
        let baseImage: UIImage?
        var overlayDrivenFrame: OverlayDrivenFrame? = nil
        var backendMatchedSprite: Int? = nil
        var overlaySequenceIndex: Int? = nil
        var overlayChar: String? = nil

        if let overlayDriven = getOverlayDrivenBaseFrame() {
            overlayDrivenFrame = overlayDriven

            // ═══ OVERLAY MODE: Use overlay's exact base frame requirement ═══
            if overlayDriven.shouldStartPlaying {
                overlayStates[overlayDriven.sectionIndex].playing = true
                overlayStates[overlayDriven.sectionIndex].currentDrawingFrame = 0
                overlayStates[overlayDriven.sectionIndex].skipFirstAdvance = true
                overlayStates[overlayDriven.sectionIndex].startTime = now
                mode = .overlay

                animLog("[LIVAAnimationEngine] 🎬 Starting overlay chunk \(overlayDriven.chunkIndex)")
            }

            // Switch base animation if needed
            if overlayDriven.animationName != currentOverlayBaseName {
                currentOverlayBaseName = overlayDriven.animationName
                animLog("[LIVAAnimationEngine] 🔄 Switched base animation to: \(currentOverlayBaseName)")
            }

            // Get base frames for current animation
            let baseFrames = animationFrames[currentOverlayBaseName] ?? []
            baseImage = baseFrames[safe: overlayDriven.frameIndex]
            globalFrameIndex = overlayDriven.frameIndex

            // Capture backend's intended frame for logging
            if overlayDriven.sectionIndex < overlaySections.count {
                let section = overlaySections[overlayDriven.sectionIndex]
                let state = overlayStates[overlayDriven.sectionIndex]
                if state.currentDrawingFrame < section.frames.count {
                    let overlayFrame = section.frames[state.currentDrawingFrame]
                    backendMatchedSprite = overlayFrame.matchedSpriteFrameNumber
                    overlaySequenceIndex = state.currentDrawingFrame
                    overlayChar = overlayFrame.char
                }
            }

        } else {
            // ═══ IDLE MODE: No overlay active, use independent counter ═══
            var baseFrames = animationFrames[currentOverlayBaseName] ?? []

            if baseFrames.isEmpty {
                currentOverlayBaseName = defaultIdleAnimation
                baseFrames = animationFrames[defaultIdleAnimation] ?? []
            }

            baseImage = baseFrames[safe: globalFrameIndex]
        }

        // 2. Collect overlay images to draw
        var overlaysToRender: [(image: UIImage, frame: CGRect)] = []
        var overlayKey: String? = nil
        var hasOverlayImage: Bool = false

        if mode == .overlay {
            for (index, section) in overlaySections.enumerated() {
                let state = overlayStates[index]

                guard state.playing, !state.done else { continue }

                let overlayFrame = section.frames[state.currentDrawingFrame]
                let key = getOverlayKey(
                    chunkIndex: section.chunkIndex,
                    sectionIndex: section.sectionIndex,
                    sequenceIndex: state.currentDrawingFrame
                )
                overlayKey = key

                if let overlayImage = imageCache.getImage(forKey: key) {
                    overlaysToRender.append((overlayImage, overlayFrame.coordinates))
                    hasOverlayImage = true
                } else {
                    // Missing overlay frame - log warning
                    hasOverlayImage = false
                    if state.currentDrawingFrame % 10 == 0 {
                        animLog("[LIVAAnimationEngine] ⚠️ Missing overlay frame: \(key)")
                    }
                }
            }
        }

        // ═══ FRAME SYNC DEBUG LOGGING ═══
        // Log every frame in overlay mode for debugging (like web frontend's LOG_FRAME_SYNC_DEBUG)
        if frameSyncDebugEnabled && mode == .overlay {
            if let overlayDriven = overlayDrivenFrame {
                let baseFrameCount = animationFrames[currentOverlayBaseName]?.count ?? 0
                let syncStatus = (backendMatchedSprite != nil && backendMatchedSprite! % max(baseFrameCount, 1) == overlayDriven.frameIndex) ? "✅SYNC" : "❌DESYNC"

                animLog("[FRAME_SYNC] draw=\(drawCallCount) chunk=\(overlayDriven.chunkIndex) seq=\(overlaySequenceIndex ?? -1) " +
                       "base=\(overlayDriven.frameIndex)/\(baseFrameCount) backend_matched=\(backendMatchedSprite ?? -1) " +
                       "anim=\(currentOverlayBaseName) char=\(overlayChar ?? "-") " +
                       "overlay_key=\(overlayKey ?? "nil") hasImage=\(hasOverlayImage) \(syncStatus)")
            }
        }

        // 3. Render frame to canvas
        if let baseImage = baseImage {
            canvasView?.renderFrame(base: baseImage, overlays: overlaysToRender)
        } else {
            animLog("[LIVAAnimationEngine] ⚠️ No base image for frame \(globalFrameIndex) in \(currentOverlayBaseName)")
        }

        // 4. Advance frame counters
        if mode == .overlay {
            advanceOverlays()
            cleanupOverlays()
        } else if mode == .idle {
            advanceIdleFrame()
        }
    }

    // MARK: - Frame Synchronization

    /// Get which base frame to display based on overlay data
    /// This is the SINGLE SOURCE OF TRUTH for base frame selection in overlay mode
    private func getOverlayDrivenBaseFrame() -> OverlayDrivenFrame? {
        // Find first playing or ready-to-start overlay section
        if drawCallCount % 100 == 1 && !overlaySections.isEmpty {
            animLog("[LIVAAnimationEngine] 🔍 getOverlayDrivenBaseFrame: checking \(overlaySections.count) sections")
        }

        for (index, section) in overlaySections.enumerated() {
            let state = overlayStates[index]

            // If already playing, use its current frame requirement
            if state.playing {
                let overlayFrame = section.frames[state.currentDrawingFrame]
                let baseFrameCount = getBaseFrameCount(for: section.frames[0].animationName)
                let baseFrameIndex = overlayFrame.matchedSpriteFrameNumber % baseFrameCount

                return OverlayDrivenFrame(
                    animationName: section.frames[0].animationName,
                    frameIndex: baseFrameIndex,
                    sectionIndex: index,
                    shouldStartPlaying: false,
                    chunkIndex: section.chunkIndex
                )
            }

            // Check if ready to start (first frame decoded)
            if !state.playing && !state.done && isFirstOverlayFrameReady(section) {
                let overlayFrame = section.frames[0]
                let baseFrameCount = getBaseFrameCount(for: section.frames[0].animationName)
                let baseFrameIndex = overlayFrame.matchedSpriteFrameNumber % baseFrameCount

                return OverlayDrivenFrame(
                    animationName: section.frames[0].animationName,
                    frameIndex: baseFrameIndex,
                    sectionIndex: index,
                    shouldStartPlaying: true, // Signal to start playing
                    chunkIndex: section.chunkIndex
                )
            }
        }

        return nil // No overlay active, use idle mode
    }

    /// Check if first overlay frame is ready to play
    private func isFirstOverlayFrameReady(_ section: OverlaySection) -> Bool {
        guard !section.frames.isEmpty else { return false }

        let key = getOverlayKey(
            chunkIndex: section.chunkIndex,
            sectionIndex: section.sectionIndex,
            sequenceIndex: 0
        )

        let hasImage = imageCache.hasImage(forKey: key)
        if !hasImage && drawCallCount % 100 == 1 {
            animLog("[LIVAAnimationEngine] ❌ First frame not ready, key: \(key), cache count: \(imageCache.count)")
        }
        return hasImage
    }

    /// Get base frame count for animation
    private func getBaseFrameCount(for animationName: String) -> Int {
        if let expectedCount = expectedFrameCounts[animationName] {
            return expectedCount
        }
        return animationFrames[animationName]?.count ?? 1
    }

    // MARK: - Frame Advancement

    /// Advance overlay frame counters
    private func advanceOverlays() {
        for (index, section) in overlaySections.enumerated() {
            var state = overlayStates[index]

            guard state.playing && !state.done else { continue }

            // Skip first advance to sync with base frame
            if state.skipFirstAdvance {
                state.skipFirstAdvance = false
                overlayStates[index] = state
                continue
            }

            // Advance overlay frame counter
            state.currentDrawingFrame += 1

            if state.currentDrawingFrame >= section.frames.count {
                state.playing = false
                state.done = true

                animLog("[LIVAAnimationEngine] ✅ Overlay chunk \(section.chunkIndex) finished")
            }

            overlayStates[index] = state
        }
    }

    /// Advance idle frame counter
    private func advanceIdleFrame() {
        let baseFrames = animationFrames[currentOverlayBaseName] ?? []
        guard !baseFrames.isEmpty else { return }

        globalFrameIndex = (globalFrameIndex + 1) % baseFrames.count
    }

    // MARK: - Cleanup & Queue Management

    /// Remove finished overlays and start next in queue
    private func cleanupOverlays() {
        let activeSections = overlaySections.enumerated().filter { index, _ in
            !overlayStates[index].done
        }

        if activeSections.count != overlaySections.count {
            // Get completed chunk indices for cleanup
            let doneChunkIndices = Set(
                overlaySections.enumerated()
                    .filter { overlayStates[$0.offset].done }
                    .map { $0.element.chunkIndex }
            )

            // Async cleanup of images for completed chunks
            DispatchQueue.global(qos: .background).async { [weak self] in
                self?.imageCache.evictChunks(doneChunkIndices)
            }

            // Update active sections
            overlaySections = activeSections.map { $0.element }
            overlayStates = activeSections.map { overlayStates[$0.offset] }

            if overlaySections.isEmpty {
                isSetPlaying = false

                // Start next chunk in queue (if any)
                if !overlayQueue.isEmpty {
                    animLog("[LIVAAnimationEngine] ▶️ Starting next chunk from queue")
                    startNextOverlaySetIfAny()
                } else {
                    // All chunks done, return to idle
                    mode = .idle
                    animLog("[LIVAAnimationEngine] 💤 Returned to idle mode")
                }
            }
        }
    }

    /// Start next overlay set from queue
    private func startNextOverlaySetIfAny() {
        guard !isSetPlaying && !overlayQueue.isEmpty else { return }

        let queued = overlayQueue.removeFirst()

        // Check if buffer is ready (adaptive buffering)
        if !isBufferReady(queued.section) {
            let waitedMs = Int((CACurrentMediaTime() - queued.queuedAt) * 1000)

            if waitedMs < maxBufferWaitMs {
                // Buffer not ready, re-queue and retry
                animLog("[LIVAAnimationEngine] ⏳ Buffer not ready, waited \(waitedMs)ms, re-queueing")
                overlayQueue.insert(queued, at: 0)

                // Retry after 100ms
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.startNextOverlaySetIfAny()
                }
                return
            } else {
                // Timeout exceeded, start anyway
                animLog("[LIVAAnimationEngine] ⚠️ Buffer timeout (\(waitedMs)ms), starting anyway")
            }
        }

        let state = OverlayState(
            playing: false,
            currentDrawingFrame: 0,
            done: false,
            audioStarted: false,
            skipFirstAdvance: true,
            startTime: nil
        )

        overlaySections = [queued.section]
        overlayStates = [state]
        isSetPlaying = true

        animLog("[LIVAAnimationEngine] 🚀 Processed overlay set, chunk: \(queued.section.chunkIndex)")
    }

    /// Check if enough frames are ready to start playback (adaptive buffering)
    private func isBufferReady(_ section: OverlaySection) -> Bool {
        guard !section.frames.isEmpty else { return false }

        let framesToCheck = min(section.frames.count, minFramesBeforeStart)
        var readyCount = 0

        for i in 0..<framesToCheck {
            let key = getOverlayKey(
                chunkIndex: section.chunkIndex,
                sectionIndex: section.sectionIndex,
                sequenceIndex: i
            )

            if imageCache.hasImage(forKey: key) {
                readyCount += 1
            } else {
                break // Stop at first missing frame
            }
        }

        return readyCount >= minFramesBeforeStart
    }
}
