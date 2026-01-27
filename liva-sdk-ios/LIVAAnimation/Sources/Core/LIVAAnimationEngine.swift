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

/// Delegate protocol for animation engine events
protocol LIVAAnimationEngineDelegate: AnyObject {
    /// Called when audio should start playing for a chunk (synced with animation)
    func animationEngine(_ engine: LIVAAnimationEngine, playAudioData data: Data, forChunk chunkIndex: Int)

    /// Called when all chunks have finished playing
    func animationEngineDidFinishAllChunks(_ engine: LIVAAnimationEngine)
}

/// Core animation rendering engine
/// Handles base animations + overlay frames (lip sync) with synchronized playback
class LIVAAnimationEngine {

    // MARK: - Properties

    /// Delegate for audio playback events
    weak var delegate: LIVAAnimationEngineDelegate?

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

    /// FPS tracking for debug info (animation FPS, not render FPS)
    private var animationFrameCount: Int = 0
    private var fpsLastUpdateTime: CFTimeInterval = 0
    private var currentFPS: Double = 0.0

    /// Next chunk readiness tracking (prefetch callback system)
    private var nextChunkReady: [Int: Bool] = [:]

    /// Time-based frame advancement (accumulator pattern)
    /// This allows rendering at 60fps while animating at 30fps
    private var idleFrameAccumulator: CFTimeInterval = 0.0
    private var overlayFrameAccumulator: CFTimeInterval = 0.0
    private let idleFrameDuration: CFTimeInterval = 1.0 / 30.0  // 30 FPS for idle
    private let overlayFrameDuration: CFTimeInterval = 1.0 / 30.0  // 30 FPS for overlay

    /// Current overlay info for debug display
    private var currentOverlayKey: String = ""
    private var currentOverlaySeq: Int = 0
    private var currentChunkIndex: Int = 0

    // MARK: - Audio-Animation Sync (Performance Fix)

    /// Pending audio data per chunk (audio doesn't play immediately - animation triggers it)
    private var pendingAudioChunks: [Int: Data] = [:]

    /// Track which chunks have started audio playback
    private var audioStartedForChunk: Set<Int> = []

    // MARK: - Constants

    /// Idle animation frame rate (FPS) - increased from 10 to 30 for smoother playback
    private let idleFrameRate: Double = 30.0

    /// Active animation frame rate (FPS) - overlay/transition modes
    private let activeFrameRate: Double = 30.0

    /// Default idle animation name (full name format: state_num_pos_state_num_pos)
    private let defaultIdleAnimation = "idle_1_s_idle_1_e"

    /// Alternate idle animation (plays in reverse direction for seamless looping)
    private let alternateIdleAnimation = "idle_1_e_idle_1_s"

    /// Minimum frames needed before starting playback (adaptive buffering)
    /// Reduced from 10 to 5 to minimize chunk transition delays
    private let minFramesBeforeStart = 5

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
        // Run at 60 FPS for smooth animation (no throttling)
        if #available(iOS 15.0, *) {
            displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        } else {
            displayLink?.preferredFramesPerSecond = 60
        }
        displayLink?.add(to: .main, forMode: .common)
        lastFrameTime = CACurrentMediaTime()
        fpsLastUpdateTime = CACurrentMediaTime()

        animLog("[LIVAAnimationEngine] ▶️ Started rendering at 60 FPS")
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

        // PREFETCH CALLBACK: Register callback to know when this chunk's images are fully cached
        // This prevents blocking at chunk transitions by proactively signaling readiness
        imageCache.onChunkComplete(chunkIndex: chunkIndex) { [weak self] in
            guard let self = self else { return }
            self.nextChunkReady[chunkIndex] = true
            animLog("[LIVAAnimationEngine] ✅ PREFETCH READY: Chunk \(chunkIndex) images fully cached")
        }

        // Start playback if not already playing
        if !isSetPlaying {
            startNextOverlaySetIfAny()
        }
    }

    /// Cache overlay image for later playback (synchronous - use async version for better performance)
    /// - Parameters:
    ///   - image: Overlay image
    ///   - key: Cache key (format: "chunkIndex-sectionIndex-sequenceIndex")
    ///   - chunkIndex: Chunk index for batch eviction
    func cacheOverlayImage(_ image: UIImage, forKey key: String, chunkIndex: Int) {
        imageCache.setImage(image, forKey: key, chunkIndex: chunkIndex)
    }

    /// Process and cache overlay image asynchronously (NON-BLOCKING - prevents FPS drops)
    /// Base64 decoding and UIImage creation happen on background thread
    /// - Parameters:
    ///   - base64Data: Base64 encoded image string
    ///   - key: Cache key (format: "chunkIndex-sectionIndex-sequenceIndex")
    ///   - chunkIndex: Chunk index for batch tracking
    ///   - completion: Optional callback when done (called on main queue)
    func processAndCacheOverlayImageAsync(
        base64Data: String,
        key: String,
        chunkIndex: Int,
        completion: ((Bool) -> Void)? = nil
    ) {
        imageCache.processAndCacheAsync(
            base64Data: base64Data,
            key: key,
            chunkIndex: chunkIndex,
            completion: completion
        )
    }

    /// Get overlay image from cache
    /// - Parameter key: Cache key
    /// - Returns: Cached image if available
    func getOverlayImage(forKey key: String) -> UIImage? {
        return imageCache.getImage(forKey: key)
    }

    // MARK: - Audio-Animation Sync

    /// Queue audio data for a chunk - does NOT play immediately
    /// Audio will start when first overlay frame of this chunk renders
    /// This ensures perfect lip sync (like web frontend)
    /// - Parameters:
    ///   - chunkIndex: Chunk index
    ///   - audioData: Raw audio data
    func queueAudioForChunk(chunkIndex: Int, audioData: Data) {
        pendingAudioChunks[chunkIndex] = audioData
        animLog("[LIVAAnimationEngine] 📦 Queued audio for chunk \(chunkIndex) (NOT playing yet - will sync with animation)")
    }

    /// Start audio for a chunk (called when first frame renders)
    private func startAudioForChunk(_ chunkIndex: Int) {
        guard let audioData = pendingAudioChunks[chunkIndex] else {
            animLog("[LIVAAnimationEngine] ⚠️ No audio data for chunk \(chunkIndex)")
            return
        }

        // Don't start audio twice for same chunk
        guard !audioStartedForChunk.contains(chunkIndex) else { return }

        audioStartedForChunk.insert(chunkIndex)

        // Notify delegate to play audio NOW (in sync with animation)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.animationEngine(self, playAudioData: audioData, forChunk: chunkIndex)
        }

        animLog("[LIVAAnimationEngine] 🔊 Started audio for chunk \(chunkIndex) - IN SYNC with first overlay frame")
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
        // Reset time accumulators
        idleFrameAccumulator = 0.0
        overlayFrameAccumulator = 0.0
        // Clear audio state
        pendingAudioChunks.removeAll()
        audioStartedForChunk.removeAll()
        // Clear prefetch tracking
        nextChunkReady.removeAll()
        // Reset FPS calculation
        animationFrameCount = 0
        currentFPS = 0.0

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

        // Reset time accumulators
        idleFrameAccumulator = 0.0
        overlayFrameAccumulator = 0.0

        // CRITICAL: Clear overlay image cache to prevent stale overlays from previous response
        // Without this, chunk indices reset to 0 but old images at key "0-0-0" etc. would be reused
        // This caused visual desync in web frontend (fixed 2026-01-26) - same fix needed here
        imageCache.clearAll()

        // Clear pending audio data (new message = new audio)
        pendingAudioChunks.removeAll()
        audioStartedForChunk.removeAll()

        // Clear prefetch tracking
        nextChunkReady.removeAll()
        // Reset FPS calculation
        animationFrameCount = 0
        currentFPS = 0.0

        animLog("[LIVAAnimationEngine] 🔄 forceIdleNow - cleared all caches, state, and audio")
    }

    // MARK: - Rendering Loop

    private var drawCallCount = 0

    /// Enable detailed frame sync logging (set to true to debug frame matching)
    var frameSyncDebugEnabled: Bool = true

    /// Performance tracking
    private var perfTrackingEnabled: Bool = true
    private var lastPerfLogTime: CFTimeInterval = 0
    private var drawTimes: [CFTimeInterval] = []
    private var cacheLookupTimes: [CFTimeInterval] = []
    private var renderTimes: [CFTimeInterval] = []

    @objc private func draw(link: CADisplayLink) {
        let drawStartTime = CACurrentMediaTime()
        let now = link.timestamp
        let deltaTime = now - lastFrameTime

        // Track delta time for frame advancement
        lastFrameTime = now
        drawCallCount += 1

        // FREEZE DETECTION: Log when frame delta is abnormally high (> 50ms = potential freeze)
        if deltaTime > 0.050 && drawCallCount > 10 {
            animLog("[LIVAAnimationEngine] ⚠️ FREEZE DETECTED: deltaTime=\(String(format: "%.1f", deltaTime * 1000))ms (expected ~16ms)")
            LIVASessionLogger.shared.logEvent("FREEZE_DETECTED", details: [
                "delta_ms": Int(deltaTime * 1000),
                "draw_count": drawCallCount,
                "mode": mode == .overlay ? "overlay" : "idle"
            ])
        }

        // Accumulate time for frame advancement (time-based animation)
        if mode == .overlay {
            overlayFrameAccumulator += deltaTime
        } else {
            idleFrameAccumulator += deltaTime
        }

        // FPS tracking - Calculate ANIMATION FPS (not render FPS)
        // We want to show 30fps (animation rate), not 60fps (render rate)
        // Track time between animation frame advances, not render calls
        let fpsDelta = now - fpsLastUpdateTime
        if fpsDelta >= 0.5 {  // Update every 0.5 seconds for responsiveness
            if animationFrameCount > 0 {
                currentFPS = Double(animationFrameCount) / fpsDelta
            }
            animationFrameCount = 0
            fpsLastUpdateTime = now
        }

        // Log every 100 frames to avoid spam (summary)
        if drawCallCount % 100 == 1 {
            animLog("[LIVAAnimationEngine] 🎨 Draw #\(drawCallCount): mode=\(mode), overlaySections=\(overlaySections.count), queue=\(overlayQueue.count), animFPS=\(String(format: "%.1f", currentFPS))")
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
                // NOTE: skipFirstAdvance REMOVED - was causing frame 0 to draw twice
                overlayStates[overlayDriven.sectionIndex].startTime = now
                mode = .overlay

                animLog("[LIVAAnimationEngine] 🎬 Starting overlay chunk \(overlayDriven.chunkIndex)")

                // SESSION LOGGER: Log chunk start event
                LIVASessionLogger.shared.logEvent("CHUNK_START", details: [
                    "chunk": overlayDriven.chunkIndex,
                    "animation": overlayDriven.animationName
                ])

                // AUDIO-ANIMATION SYNC: Start audio when first frame of chunk renders
                // This ensures perfect lip sync (audio and animation start together)
                startAudioForChunk(overlayDriven.chunkIndex)
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
        let cacheLookupStart = CACurrentMediaTime()
        var overlaysToRender: [(image: UIImage, frame: CGRect)] = []
        var overlayKey: String? = nil
        var hasOverlayImage: Bool = false

        if mode == .overlay {
            for (index, section) in overlaySections.enumerated() {
                let state = overlayStates[index]

                guard state.playing, !state.done else { continue }
                guard state.currentDrawingFrame < section.frames.count else { continue }

                let overlayFrame = section.frames[state.currentDrawingFrame]

                // CONTENT-BASED CACHING: Use overlayId from frame instead of positional key
                // This matches web behavior and prevents wrong images on cache miss/corruption
                let key = getOverlayCacheKey(
                    for: overlayFrame,
                    chunkIndex: section.chunkIndex,
                    sectionIndex: section.sectionIndex,
                    sequenceIndex: state.currentDrawingFrame
                )
                overlayKey = key

                if let overlayImage = imageCache.getImage(forKey: key) {
                    overlaysToRender.append((overlayImage, overlayFrame.coordinates))
                    hasOverlayImage = true

                    // Log image size to verify correct image
                    if state.currentDrawingFrame == 0 || state.currentDrawingFrame % 30 == 0 {
                        animLog("[LIVAAnimationEngine] 🖼️ Got overlay: key=\(key), size=\(overlayImage.size), coords=\(overlayFrame.coordinates)")
                    }
                } else {
                    // Missing overlay frame - log warning every frame when missing
                    hasOverlayImage = false
                    animLog("[LIVAAnimationEngine] ⚠️ MISSING overlay: key=\(key), drawFrame=\(state.currentDrawingFrame), seqIndex=\(overlayFrame.sequenceIndex), cacheCount=\(imageCache.count)")
                }
            }
        }
        let cacheLookupTime = CACurrentMediaTime() - cacheLookupStart

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
        let renderStart = CACurrentMediaTime()
        if let baseImage = baseImage {
            canvasView?.renderFrame(base: baseImage, overlays: overlaysToRender)

            // Update debug info on canvas (real-time display)
            // IMPORTANT: Show ACTUAL base animation frame info (not overlay counts)
            let baseFrameCount = animationFrames[currentOverlayBaseName]?.count ?? expectedFrameCounts[currentOverlayBaseName] ?? 0
            let baseFrameNum = globalFrameIndex

            if mode == .overlay && !overlaySections.isEmpty {
                currentChunkIndex = overlaySections.first?.chunkIndex ?? 0
                let drawFrame = overlayStates.first?.currentDrawingFrame ?? 0
                // Get the actual sequenceIndex and content-based key from the frame metadata
                if let section = overlaySections.first, drawFrame < section.frames.count {
                    let overlayFrame = section.frames[drawFrame]
                    currentOverlaySeq = overlayFrame.sequenceIndex
                    // Use content-based key for debug display
                    currentOverlayKey = getOverlayCacheKey(
                        for: overlayFrame,
                        chunkIndex: currentChunkIndex,
                        sectionIndex: 0,
                        sequenceIndex: currentOverlaySeq
                    )
                } else {
                    currentOverlaySeq = drawFrame
                    currentOverlayKey = ""
                }
            } else {
                currentOverlayKey = ""
                currentOverlaySeq = 0
                currentChunkIndex = 0
            }

            canvasView?.updateDebugInfo(
                fps: currentFPS,
                frameNumber: baseFrameNum,  // Actual base frame index
                totalFrames: baseFrameCount,  // Actual base animation frame count
                animationName: currentOverlayBaseName,
                mode: mode == .overlay ? "overlay" : "idle",
                hasOverlay: !overlaysToRender.isEmpty,
                overlayKey: currentOverlayKey,
                overlaySeq: currentOverlaySeq,
                chunkIndex: currentChunkIndex
            )

            // SESSION LOGGER: Only log overlay/talking frames, skip idle to reduce clutter
            if mode == .overlay {
                let isInSync: Bool
                if let overlayDriven = overlayDrivenFrame {
                    isInSync = (backendMatchedSprite != nil && backendMatchedSprite! % max(baseFrameCount, 1) == overlayDriven.frameIndex)
                } else {
                    isInSync = true
                }

                LIVASessionLogger.shared.logFrame(
                    chunk: currentChunkIndex,
                    seq: currentOverlaySeq,
                    anim: currentOverlayBaseName,
                    baseFrame: baseFrameNum,
                    overlayKey: currentOverlayKey,
                    syncStatus: isInSync ? "SYNC" : "DESYNC",
                    fps: currentFPS
                )
            }
        } else {
            animLog("[LIVAAnimationEngine] ⚠️ No base image for frame \(globalFrameIndex) in \(currentOverlayBaseName)")
        }
        let renderTime = CACurrentMediaTime() - renderStart
        let totalDrawTime = CACurrentMediaTime() - drawStartTime

        // SLOW FRAME DETECTION: Log immediately when draw takes too long (> 20ms)
        if totalDrawTime > 0.020 {
            animLog("[LIVAAnimationEngine] 🐢 SLOW FRAME: total=\(String(format: "%.1f", totalDrawTime * 1000))ms cache=\(String(format: "%.1f", cacheLookupTime * 1000))ms render=\(String(format: "%.1f", renderTime * 1000))ms")
            LIVASessionLogger.shared.logEvent("SLOW_FRAME", details: [
                "total_ms": Int(totalDrawTime * 1000),
                "cache_ms": Int(cacheLookupTime * 1000),
                "render_ms": Int(renderTime * 1000),
                "chunk": currentChunkIndex,
                "seq": currentOverlaySeq
            ])
        }

        // Performance tracking - log every second during overlay mode
        if perfTrackingEnabled && mode == .overlay {
            drawTimes.append(totalDrawTime)
            cacheLookupTimes.append(cacheLookupTime)
            renderTimes.append(renderTime)

            if now - lastPerfLogTime >= 1.0 {
                let avgDraw = drawTimes.reduce(0, +) / Double(max(drawTimes.count, 1)) * 1000
                let avgCache = cacheLookupTimes.reduce(0, +) / Double(max(cacheLookupTimes.count, 1)) * 1000
                let avgRender = renderTimes.reduce(0, +) / Double(max(renderTimes.count, 1)) * 1000
                let maxDraw = (drawTimes.max() ?? 0) * 1000
                let maxCache = (cacheLookupTimes.max() ?? 0) * 1000
                let maxRender = (renderTimes.max() ?? 0) * 1000

                animLog("[PERF] avg: draw=\(String(format: "%.2f", avgDraw))ms cache=\(String(format: "%.2f", avgCache))ms render=\(String(format: "%.2f", avgRender))ms | max: draw=\(String(format: "%.2f", maxDraw))ms cache=\(String(format: "%.2f", maxCache))ms render=\(String(format: "%.2f", maxRender))ms | samples=\(drawTimes.count)")

                drawTimes.removeAll()
                cacheLookupTimes.removeAll()
                renderTimes.removeAll()
                lastPerfLogTime = now
            }
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
                // FIX: Use current frame's animation name, not first frame's (matches web behavior)
                let baseFrameCount = getBaseFrameCount(for: overlayFrame.animationName)
                let baseFrameIndex = overlayFrame.matchedSpriteFrameNumber % baseFrameCount

                return OverlayDrivenFrame(
                    animationName: overlayFrame.animationName,  // FIX: Use current frame's animation
                    frameIndex: baseFrameIndex,
                    sectionIndex: index,
                    shouldStartPlaying: false,
                    chunkIndex: section.chunkIndex
                )
            }

            // Check if ready to start (first frame decoded)
            if !state.playing && !state.done && isFirstOverlayFrameReady(section) {
                let overlayFrame = section.frames[0]
                // Use overlayFrame.animationName for consistency (same as frames[0] here)
                let baseFrameCount = getBaseFrameCount(for: overlayFrame.animationName)
                let baseFrameIndex = overlayFrame.matchedSpriteFrameNumber % baseFrameCount

                return OverlayDrivenFrame(
                    animationName: overlayFrame.animationName,  // Consistent with above
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
        guard let firstFrame = section.frames.first else { return false }

        // CONTENT-BASED CACHING: Use overlayId from frame for lookup
        let key = getOverlayCacheKey(
            for: firstFrame,
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

    /// Advance overlay frame counters (time-based)
    private func advanceOverlays() {
        // Only advance when enough time has accumulated
        guard overlayFrameAccumulator >= overlayFrameDuration else { return }

        // FRAME SKIP FIX: Only advance ONE frame per render cycle
        // Previously used a while loop that could skip frames if time accumulated
        // This caused visible stuttering where frames 11,12,13 were skipped (10 → 14)
        // Cap accumulator to prevent runaway catch-up (max 2 frames worth)
        if overlayFrameAccumulator > overlayFrameDuration * 2 {
            overlayFrameAccumulator = overlayFrameDuration * 2
        }
        overlayFrameAccumulator -= overlayFrameDuration

        // Advance exactly one frame
        var didAdvance = false

            for (index, section) in overlaySections.enumerated() {
                var state = overlayStates[index]

                guard state.playing && !state.done else { continue }

                // JITTER FIX: Skip if holding at last frame waiting for next chunk buffer
                if state.holdingLastFrame {
                    continue
                }

                // NOTE: skipFirstAdvance logic REMOVED - was causing frame 0 to draw twice
                // The getOverlayDrivenBaseFrame() already handles synchronization correctly.

                // Check if this is the last frame
                let isLastFrame = state.currentDrawingFrame >= section.frames.count - 1

                if isLastFrame {
                    // JITTER FIX: Before marking done, check if next chunk buffer is ready
                    if !overlayQueue.isEmpty {
                        let nextChunk = overlayQueue.first!
                        let nextChunkIndex = nextChunk.section.chunkIndex

                        // FAST PATH: Check prefetch callback flag first (avoids polling)
                        let isPrefetchReady = nextChunkReady[nextChunkIndex] == true

                        // SLOW PATH: If prefetch not ready, check minimum buffer
                        let isMinBufferReady = isPrefetchReady || isBufferReady(nextChunk.section)

                        if !isMinBufferReady {
                            // Buffer NOT ready - hold at last frame
                            state.holdingLastFrame = true
                            overlayStates[index] = state
                            animLog("[LIVAAnimationEngine] ⏸️ HOLDING: Chunk \(section.chunkIndex) waiting for chunk \(nextChunkIndex) buffer (prefetch=\(isPrefetchReady))")
                            continue
                        }
                    }

                    // Buffer ready (or no more chunks) - mark done and cleanup
                    state.playing = false
                    state.done = true
                    state.holdingLastFrame = false
                    // Clear prefetch flag for current chunk (memory cleanup)
                    nextChunkReady.removeValue(forKey: section.chunkIndex)
                    animLog("[LIVAAnimationEngine] ✅ Overlay chunk \(section.chunkIndex) finished")
                } else {
                    // Not last frame - advance normally
                    state.currentDrawingFrame += 1
                    didAdvance = true
                }

                overlayStates[index] = state
            }

        // Count animation frame for FPS (not render frame)
        if didAdvance {
            animationFrameCount += 1
        }
    }

    /// Advance idle frame counter (time-based)
    /// Alternates between idle_1_s_idle_1_e and idle_1_e_idle_1_s for seamless looping
    private func advanceIdleFrame() {
        let baseFrames = animationFrames[currentOverlayBaseName] ?? []
        guard !baseFrames.isEmpty else { return }

        // Only advance frame when enough time has accumulated
        while idleFrameAccumulator >= idleFrameDuration {
            idleFrameAccumulator -= idleFrameDuration

            let nextFrame = globalFrameIndex + 1

            if nextFrame >= baseFrames.count {
                // Animation finished - switch to alternate idle animation
                let nextAnim: String
                if currentOverlayBaseName == defaultIdleAnimation {
                    nextAnim = alternateIdleAnimation
                } else if currentOverlayBaseName == alternateIdleAnimation {
                    nextAnim = defaultIdleAnimation
                } else {
                    nextAnim = defaultIdleAnimation
                }

                // Only switch if alternate animation has frames loaded
                if let nextFrames = animationFrames[nextAnim], !nextFrames.isEmpty {
                    currentOverlayBaseName = nextAnim
                    globalFrameIndex = 0
                } else {
                    // Fallback: wrap around within same animation
                    globalFrameIndex = 0
                }
            } else {
                globalFrameIndex = nextFrame
            }

            // Count animation frame for FPS (not render frame)
            animationFrameCount += 1
        }
    }

    // MARK: - Transitions

    /// Transition smoothly back to idle animation
    private func transitionToIdle() {
        mode = .idle

        // Switch back to default idle animation
        currentOverlayBaseName = defaultIdleAnimation
        globalFrameIndex = 0

        // Reset accumulators for clean start
        idleFrameAccumulator = 0.0
        overlayFrameAccumulator = 0.0

        // Clear ALL overlay state to prevent any flickering
        overlaySections.removeAll()
        overlayStates.removeAll()
        overlayQueue.removeAll()
        isSetPlaying = false

        // Clear overlay tracking
        currentOverlayKey = ""
        currentOverlaySeq = 0
        currentChunkIndex = 0

        // Clear overlay image cache to prevent stale frames
        imageCache.clearAll()

        // Clear audio state (chunks complete)
        pendingAudioChunks.removeAll()
        audioStartedForChunk.removeAll()

        // Clear prefetch tracking
        nextChunkReady.removeAll()

        // Notify delegate that all chunks finished
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.animationEngineDidFinishAllChunks(self)
        }

        animLog("[LIVAAnimationEngine] 💤 Transitioned to idle: \(currentOverlayBaseName), cleared all overlay caches and audio")
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
                    // All chunks done, return to idle smoothly
                    transitionToIdle()
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
            // NOTE: skipFirstAdvance REMOVED - was causing frame 0 to draw twice
            startTime: nil,
            holdingLastFrame: false
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
            guard i < section.frames.count else { break }
            let frame = section.frames[i]

            // CONTENT-BASED CACHING: Use overlayId from frame for lookup
            let key = getOverlayCacheKey(
                for: frame,
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

    // MARK: - Debug Info

    /// Get real-time debug info for display in Flutter UI
    func getDebugInfo() -> [String: Any] {
        // Determine current animation name
        let animationName: String
        let frameNumber: Int
        var totalFrames: Int = 0
        let hasOverlay = !overlaySections.isEmpty

        if mode == .overlay && !overlaySections.isEmpty {
            // In overlay mode, show overlay animation info from first frame
            animationName = overlaySections.first?.frames.first?.animationName ?? currentOverlayBaseName
            frameNumber = overlayStates.first?.currentDrawingFrame ?? 0
            totalFrames = overlaySections.first?.frames.count ?? 0
        } else {
            // In idle mode, show idle animation info
            animationName = currentOverlayBaseName
            frameNumber = globalFrameIndex
            totalFrames = animationFrames[currentOverlayBaseName]?.count ?? expectedFrameCounts[currentOverlayBaseName] ?? 0
        }

        return [
            "fps": currentFPS,
            "animationName": animationName,
            "frameNumber": frameNumber,
            "totalFrames": totalFrames,
            "mode": mode == .overlay ? "overlay" : "idle",
            "hasOverlay": hasOverlay,
            "queuedChunks": overlayQueue.count,
            "drawCount": drawCallCount
        ]
    }
}
