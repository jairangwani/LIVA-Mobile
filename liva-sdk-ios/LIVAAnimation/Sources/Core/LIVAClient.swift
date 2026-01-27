//
//  LIVAClient.swift
//  LIVAAnimation
//
//  Main SDK interface for LIVA avatar animations.
//

import UIKit
import os.log
import QuartzCore

// Debug logger for LIVA client
private let clientLogger = OSLog(subsystem: "com.liva.animation", category: "LIVAClient")

/// Log to both os_log and shared debug log
func clientLog(_ message: String, type: OSLogType = .debug) {
    os_log("%{public}@", log: clientLogger, type: type, message)
    LIVADebugLog.shared.log(message)
}

/// Main client for LIVA Animation SDK
public final class LIVAClient {

    // MARK: - Singleton

    /// Shared instance
    public static let shared = LIVAClient()

    private init() {
        // Register for memory warnings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    // MARK: - Properties

    /// Current configuration
    public private(set) var configuration: LIVAConfiguration?

    /// Current connection state
    public private(set) var state: LIVAState = .idle {
        didSet {
            if oldValue != state {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.onStateChange?(self.state)
                }
            }
        }
    }

    /// Whether the client is currently connected
    public var isConnected: Bool {
        return socketManager?.isConnected ?? false
    }

    // MARK: - Callbacks

    /// Called when connection state changes
    public var onStateChange: ((LIVAState) -> Void)?

    /// Called when an error occurs
    public var onError: ((LIVAError) -> Void)?

    // MARK: - Components

    private var socketManager: LIVASocketManager?
    private var newAnimationEngine: LIVAAnimationEngine?
    private var audioPlayer: AudioPlayer?
    private var baseFrameManager: BaseFrameManager?
    private weak var canvasView: LIVACanvasView?

    // MARK: - Base Frame Loading State

    private var isBaseFramesLoaded: Bool = false
    private var pendingConnect: Bool = false

    // MARK: - State Tracking

    private var pendingOverlayPositions: [Int: CGPoint] = [:]

    // NEW - Track overlay frame metadata for new animation engine
    private var pendingOverlayFrames: [Int: [OverlayFrame]] = [:]
    private var chunkAnimationNames: [Int: String] = [:]

    // PHASE 1 & 5: Batched processing with yields
    /// Track pending batch operations per chunk (for async batch processing)
    private var pendingBatchCount: [Int: Int] = [:]
    /// Deferred chunk ready signals (when batches are still processing)
    private var deferredChunkReady: [Int: Int] = [:]  // chunkIndex -> totalSent
    /// Lock for batch tracking state
    private let batchTrackingLock = NSLock()
    /// Batch size for frame processing (matches web frontend's 15)
    private let frameBatchSize = 15

    /// Background queue for frame processing (prevents main thread blocking)
    private let frameProcessingQueue = DispatchQueue(label: "com.liva.frameProcessing", qos: .userInitiated)

    /// CONCURRENT DECODE: Queue of frames waiting to be decoded
    private var frameDecodeQueue: [(frame: LIVASocketManager.FrameData, chunkIndex: Int)] = []
    private let decodeQueueLock = NSLock()

    /// Maximum concurrent decode operations (streaming approach)
    /// 1 worker = simple sequential processing, no lock contention
    /// Overlay images are small and fast - one worker is sufficient for 30fps
    /// This is a streaming app, not batch processing - decode as we play
    private let maxConcurrentDecodes: Int = 1

    /// Pending base animation to play after all chunks finish (like web's pendingBaseAtEndRef)
    /// Set when backend sends play_base_animation event, used when transitioning to idle
    private var pendingBaseAtEnd: String?

    /// Animation names from server manifest (source of truth for available animations)
    /// This replaces the hardcoded ANIMATION_LOAD_ORDER as the list of animations to load
    private var manifestAnimationNames: [String] = []

    /// Set of animation names that have been fully loaded and are ready for use
    /// Updated as animations complete loading from cache or server
    /// Used to tell backend which animations are available (matches web's getReadyAnimations)
    private var loadedAnimationNames: Set<String> = []

    // MARK: - Public Methods

    /// Configure the SDK with connection parameters
    /// - Parameter config: Configuration object
    public func configure(_ config: LIVAConfiguration) {
        self.configuration = config

        // Initialize components
        audioPlayer = AudioPlayer()
        baseFrameManager = BaseFrameManager()

        // NEW - Initialize new animation engine (will replace old one)
        // Note: Needs canvas view to be attached first
        // Will be initialized in attachView()

        // Configure session logger for centralized logging to LIVA-TESTS/logs/sessions/
        LIVASessionLogger.shared.configure(serverUrl: config.serverURL)

        setupAnimationEngineCallbacks()
        setupAudioPlayerCallbacks()
        setupBaseFrameManagerCallbacks()

        // Try to load base frames from cache
        loadBaseFramesFromCache()
    }

    /// Attach a canvas view for rendering
    /// - Parameter view: The canvas view to render to
    public func attachView(_ view: LIVACanvasView) {
        self.canvasView = view

        // Initialize animation engine with canvas view
        newAnimationEngine = LIVAAnimationEngine(canvasView: view)
        newAnimationEngine?.delegate = self  // Set delegate for audio-animation sync

        clientLog("[LIVAClient] ✅ Attached canvas view and initialized new animation engine with audio sync")
    }

    /// DEBUG: Disable overlay rendering to test base frames + audio only
    /// - Parameter disable: True to disable overlays, false to enable (default: false)
    public func setOverlayRenderingDisabled(_ disable: Bool) {
        newAnimationEngine?.disableOverlayRendering = disable
        clientLog("[LIVAClient] 🎬 Overlay rendering \(disable ? "DISABLED" : "ENABLED")")
    }

    /// DEBUG: Start test mode - cycle through base animations only
    /// No chunks, no overlays, no audio - pure base animation rendering test
    /// - Parameter cycles: Number of times to cycle through all loaded animations (default: 5)
    public func startAnimationTest(cycles: Int = 5) {
        newAnimationEngine?.startTestMode(cycles: cycles)
        clientLog("[LIVAClient] 🧪 Started animation test mode: \(cycles) cycles")
    }

    /// DEBUG: Stop test mode
    public func stopAnimationTest() {
        newAnimationEngine?.stopTestMode()
        clientLog("[LIVAClient] 🧪 Stopped animation test mode")
    }

    /// Get list of loaded animation names (for Flutter bridge or direct API use)
    /// Backend uses this to only select from animations the frontend has available
    /// - Returns: Array of animation names that are fully loaded, in priority order
    public func getLoadedAnimations() -> [String] {
        return getReadyAnimations()
    }

    /// Connect to the backend server
    public func connect() {
        guard let config = configuration else {
            handleError(.notConfigured)
            return
        }

        state = .connecting

        // Reset performance tracker for new session
        LIVAPerformanceTracker.shared.reset()

        // Create socket manager
        socketManager = LIVASocketManager(configuration: config)
        setupSocketCallbacks()
        socketManager?.connect()
    }

    /// Disconnect from the server
    public func disconnect() {
        // Print final performance report before disconnecting
        LIVAPerformanceTracker.shared.printReport()

        // End session logging before disconnect
        LIVASessionLogger.shared.endSession {
            clientLog("[LIVAClient] 📊 Ended logging session")
        }

        canvasView?.stopRenderLoop()
        audioPlayer?.stop()
        newAnimationEngine?.stopRendering()
        newAnimationEngine?.reset()
        socketManager?.disconnect()
        socketManager = nil
        state = .idle
    }

    /// Force immediate transition to idle and clear all caches
    /// Call this BEFORE sending a new message to prevent stale overlay reuse
    /// This matches web frontend's forceIdleNow() + stopAllAudio() behavior
    public func forceIdleNow() {
        clientLog("[LIVAClient] 🔄 forceIdleNow - stopping audio and clearing caches")

        // Stop any ongoing audio playback (like web's stopAllAudio)
        audioPlayer?.stop()

        // Clear animation engine caches and state
        newAnimationEngine?.forceIdleNow()

        // Clear pending state in client (only accessed from main thread)
        pendingOverlayPositions.removeAll()

        // THREAD SAFETY: Clear shared state under lock
        batchTrackingLock.withLock {
            pendingOverlayFrames.removeAll()
            chunkAnimationNames.removeAll()
            pendingBatchCount.removeAll()
            deferredChunkReady.removeAll()
        }

        // Clear pending base animation (like web's pendingBaseAtEndRef.current = null)
        pendingBaseAtEnd = nil

        // Update state if we were animating
        if state == .animating {
            state = .connected
        }
    }

    // MARK: - Socket Callbacks

    private func setupSocketCallbacks() {
        guard let socket = socketManager else { return }

        socket.onConnect = { [weak self] in
            self?.state = .connected
            // NOTE: Don't start legacy canvas render loop - new animation engine handles rendering
            // self?.canvasView?.startRenderLoop()

            // Start session logging to LIVA-TESTS/logs/sessions/
            let userId = self?.configuration?.userId ?? ""
            let agentId = self?.configuration?.agentId ?? ""
            LIVASessionLogger.shared.startSession(userId: userId, agentId: agentId) { sessionId in
                if let sessionId = sessionId {
                    clientLog("[LIVAClient] 📊 Started logging session: \(sessionId)")
                    // Tell backend to log frames to same session (enables backend vs iOS comparison)
                    self?.socketManager?.setSessionId(sessionId)
                }
            }

            // Request animations manifest to start loading base frames
            if let agentId = self?.configuration?.agentId {
                clientLog("[LIVAClient] 📤 Requesting animations manifest after connect")
                self?.socketManager?.requestAnimationsManifest(agentId: agentId)
            }
        }

        socket.onDisconnect = { [weak self] reason in
            self?.canvasView?.stopRenderLoop()
            if self?.state != .idle {
                self?.state = .error(.socketDisconnected)
            }
        }

        socket.onError = { [weak self] error in
            if let livaError = error as? LIVAError {
                self?.handleError(livaError)
            } else {
                self?.handleError(.unknown(error.localizedDescription))
            }
        }

        socket.onAudioReceived = { [weak self] audioChunk in
            self?.handleAudioReceived(audioChunk)
        }

        socket.onFrameBatchReceived = { [weak self] frameBatch in
            self?.handleFrameBatchReceived(frameBatch)
        }

        socket.onChunkReady = { [weak self] chunkIndex, totalSent in
            self?.handleChunkReady(chunkIndex: chunkIndex, totalSent: totalSent)
        }

        socket.onAudioEnd = { [weak self] in
            self?.handleAudioEnd()
        }

        socket.onPlayBaseAnimation = { [weak self] animationName in
            self?.handlePlayBaseAnimation(animationName)
        }

        // Base frame events
        socket.onAnimationTotalFrames = { [weak self] animationName, totalFrames in
            self?.handleAnimationTotalFrames(animationName, totalFrames: totalFrames)
        }

        socket.onBaseFrameReceived = { [weak self] animationName, frameIndex, data in
            self?.handleBaseFrameReceived(animationName, frameIndex: frameIndex, data: data)
        }

        socket.onAnimationFramesComplete = { [weak self] animationName in
            self?.handleAnimationFramesComplete(animationName)
        }

        // NEW - Animation engine events (chunk streaming)
        socket.onAnimationChunkMetadata = { [weak self] dict in
            self?.handleAnimationChunkMetadata(dict)
        }

        socket.onFrameImageReceived = { [weak self] dict in
            self?.handleFrameImageReceived(dict)
        }

        // NEW - Handle animations manifest to request base frames
        socket.onAnimationsManifest = { [weak self] animations in
            self?.handleAnimationsManifest(animations)
        }
    }

    // NEW - Handle animations manifest and request animations
    // Manifest format: { "animation_name": {"frames": N, "version": "xxx"}, ... }
    // Uses manifest as SOURCE OF TRUTH for available animations (not hardcoded list)
    private func handleAnimationsManifest(_ animations: [String: Any]) {
        guard let config = configuration else { return }

        let animationNamesSet = Set(animations.keys)
        clientLog("[LIVAClient] 📋 Received manifest with \(animationNamesSet.count) animations")

        // Build prioritized list: animations in ANIMATION_LOAD_ORDER first (in order),
        // then any additional animations from manifest that aren't in the priority list
        var orderedAnimations: [String] = []

        // First: add animations from priority list that exist in manifest
        for animationName in ANIMATION_LOAD_ORDER {
            if animationNamesSet.contains(animationName) {
                orderedAnimations.append(animationName)
            }
        }

        // Second: add any additional animations from manifest not in priority list
        let prioritySet = Set(ANIMATION_LOAD_ORDER)
        for animationName in animations.keys.sorted() {
            if !prioritySet.contains(animationName) {
                orderedAnimations.append(animationName)
                clientLog("[LIVAClient] 📋 Found additional animation from manifest: \(animationName)")
            }
        }

        // Store manifest animation names for later use (cache loading, etc.)
        manifestAnimationNames = orderedAnimations
        clientLog("[LIVAClient] 📋 Will load \(orderedAnimations.count) animations in priority order")

        // Request ALL animations from manifest in priority order
        for animationName in orderedAnimations {
            clientLog("[LIVAClient] 📤 Requesting animation: \(animationName)")
            socketManager?.requestBaseAnimation(name: animationName, agentId: config.agentId)
        }
    }

    // MARK: - Event Handlers

    private func handleAudioReceived(_ audioChunk: LIVASocketManager.AudioChunk) {
        // Update state to animating
        if state == .connected {
            state = .animating
        }

        clientLog("[LIVAClient] 🔊 Received audio chunk \(audioChunk.chunkIndex), animationFramesChunk count: \(audioChunk.animationFramesChunk.count)")

        // AUDIO-ANIMATION SYNC FIX:
        // DON'T play audio immediately - queue it for animation engine to trigger
        // Audio will start when first overlay frame renders (like web frontend)
        newAnimationEngine?.queueAudioForChunk(chunkIndex: audioChunk.chunkIndex, audioData: audioChunk.audioData)

        // Store overlay position for this chunk
        if let firstFrame = audioChunk.animationFramesChunk.first {
            pendingOverlayPositions[audioChunk.chunkIndex] = firstFrame.zoneTopLeft
            clientLog("[LIVAClient] 📍 Stored overlay position for chunk \(audioChunk.chunkIndex): \(firstFrame.zoneTopLeft), animation: \(firstFrame.animationName)")
        } else {
            clientLog("[LIVAClient] ⚠️ No animationFramesChunk for audio chunk \(audioChunk.chunkIndex)")
        }
    }

    /// Background queue for frame batch processing to avoid blocking main thread
    private static let frameBatchQueue = DispatchQueue(
        label: "com.liva.frameBatchProcessing",
        qos: .userInitiated
    )

    private func handleFrameBatchReceived(_ frameBatch: LIVASocketManager.FrameBatch) {
        let chunkIndex = frameBatch.chunkIndex
        let batchIndex = frameBatch.batchIndex
        let frameCount = frameBatch.frames.count
        let frames = frameBatch.frames

        // PHASE 1 & 5: Increment pending batch count IMMEDIATELY (before async)
        batchTrackingLock.withLock {
            pendingBatchCount[chunkIndex, default: 0] += 1
        }

        // Initialize tracking arrays for this chunk if needed (thread-safe)
        batchTrackingLock.withLock {
            if pendingOverlayFrames[chunkIndex] == nil {
                pendingOverlayFrames[chunkIndex] = []
                pendingOverlayFrames[chunkIndex]?.reserveCapacity(120)
            }
        }

        // Cache engine reference
        let engine = newAnimationEngine

        // PERF FIX: Move ALL frame processing to background queue
        // This prevents main thread blocking during frame batch arrival
        frameProcessingQueue.async { [weak self] in
            guard let self = self else { return }

            // Log batch received (now on background thread)
            clientLog("[LIVAClient] 📥 handleFrameBatchReceived: chunk=\(chunkIndex), batch=\(batchIndex), frames=\(frameCount)")

            // DIAGNOSTICS: Record frames received in single batch call (reduces overhead)
            LIVAPerformanceTracker.shared.recordFramesReceivedBatch(chunk: chunkIndex, count: frameCount)

            // RATE LIMITING: Queue frames for one-at-a-time processing
            // This prevents flooding the system with 100+ decode operations at once
            self.decodeQueueLock.lock()
            for frame in frames {
                self.frameDecodeQueue.append((frame: frame, chunkIndex: chunkIndex))
            }
            self.decodeQueueLock.unlock()

            // Start processing if not already running
            self.startRateLimitedFrameProcessing(engine: engine)

            // Batch complete - notify on main thread
            DispatchQueue.main.async {
                self.onBatchComplete(chunkIndex: chunkIndex)
            }
        }
    }

    /// CONCURRENT DECODE: Process frames with controlled parallelism
    /// Decodes multiple frames simultaneously but throttles to maxConcurrentDecodes
    /// This keeps decode ahead of 30fps playback without flooding the system
    private func startRateLimitedFrameProcessing(engine: LIVAAnimationEngine?) {
        // Kick off parallel decode workers up to max concurrency
        for _ in 0..<maxConcurrentDecodes {
            frameProcessingQueue.async { [weak self] in
                self?.processNextFrameInQueue(engine: engine)
            }
        }
    }

    /// Process next frame in queue (concurrent worker)
    /// Multiple workers run in parallel, each grabbing next frame from queue
    private func processNextFrameInQueue(engine: LIVAAnimationEngine?) {
        while true {
            decodeQueueLock.lock()

            // Queue empty? This worker exits
            guard !frameDecodeQueue.isEmpty else {
                decodeQueueLock.unlock()
                return
            }

            // Get next frame
            let item = frameDecodeQueue.removeFirst()
            let queueSize = frameDecodeQueue.count
            decodeQueueLock.unlock()

            // Process this frame (decode happens here - this is the slow operation)
            self.processFrameMetadata(item.frame, chunkIndex: item.chunkIndex, engine: engine)

            // Log progress every 50 frames
            if item.frame.sequenceIndex % 50 == 0 {
                clientLog("[LIVAClient] 🔄 Decode progress: seq=\(item.frame.sequenceIndex), queue=\(queueSize)")
            }
        }
    }

    /// Process a single frame's metadata and queue async image decode
    /// PHASE 1: Extracted for batched processing
    /// NOTE: Thread-safe - can be called from background queue
    private func processFrameMetadata(_ frame: LIVASocketManager.FrameData, chunkIndex: Int, engine: LIVAAnimationEngine?) {
        let contentKey = frame.contentBasedCacheKey

        // VERBOSE LOGGING: Log every frame's store key (first 20 per chunk for better visibility)
        if frame.sequenceIndex < 20 {
            clientLog("[LIVAClient] 💾 FRAME_ARRIVE chunk=\(chunkIndex) seq=\(frame.sequenceIndex) key='\(contentKey)'")
        }

        // ASYNC: Decode image on background (already thread-safe)
        // This starts decoding IMMEDIATELY for ALL frames as they arrive
        // OPTIMIZATION: Only pass completion callback for first 20 frames (avoid flooding main queue)
        // OPTIMIZATION: Use raw Data when available (skip base64 roundtrip)
        let needsLogging = frame.sequenceIndex < 20
        if let rawData = frame.imageDataRaw {
            // Fast path: decode directly from Data (no base64 overhead)
            engine?.processAndCacheOverlayImageAsync(
                imageData: rawData,
                key: contentKey,
                chunkIndex: chunkIndex,
                completion: needsLogging ? { success in
                    clientLog("[LIVAClient] ✅ FRAME_DECODED chunk=\(chunkIndex) seq=\(frame.sequenceIndex) success=\(success) [raw]")
                } : nil
            )
        } else {
            // Legacy path: decode from base64 string
            engine?.processAndCacheOverlayImageAsync(
                base64Data: frame.imageData,
                key: contentKey,
                chunkIndex: chunkIndex,
                completion: needsLogging ? { success in
                    clientLog("[LIVAClient] ✅ FRAME_DECODED chunk=\(chunkIndex) seq=\(frame.sequenceIndex) success=\(success) [b64]")
                } : nil
            )
        }

        // Build OverlayFrame (struct copy is fast)
        let overlayFrame = OverlayFrame(
            matchedSpriteFrameNumber: frame.matchedSpriteFrameNumber,
            sheetFilename: frame.sheetFilename,
            coordinates: .zero,
            imageData: nil,
            sequenceIndex: frame.sequenceIndex,
            animationName: frame.animationName,
            originalFrameIndex: frame.frameIndex,
            overlayId: contentKey,
            char: frame.char,
            viseme: nil
        )

        // THREAD SAFETY: Lock when accessing shared state
        batchTrackingLock.withLock {
            pendingOverlayFrames[chunkIndex]?.append(overlayFrame)
            if !frame.animationName.isEmpty && chunkAnimationNames[chunkIndex] == nil {
                chunkAnimationNames[chunkIndex] = frame.animationName
            }
        }
    }

    /// PHASE 5: Called when a batch finishes processing
    /// Decrements pending count and processes deferred chunk_ready if all batches done
    /// NOTE: Called from main thread via DispatchQueue.main.async
    private func onBatchComplete(chunkIndex: Int) {
        let (deferredTotal, framesExist) = batchTrackingLock.withLock { () -> (Int?, Bool) in
            pendingBatchCount[chunkIndex, default: 1] -= 1
            let remaining = pendingBatchCount[chunkIndex] ?? 0
            let deferredTotal = remaining == 0 ? deferredChunkReady.removeValue(forKey: chunkIndex) : nil
            let framesExist = pendingOverlayFrames[chunkIndex] != nil && !(pendingOverlayFrames[chunkIndex]?.isEmpty ?? true)
            return (deferredTotal, framesExist)
        }

        // If all batches done and chunk_ready was deferred, process it now
        if let totalSent = deferredTotal {
            if framesExist {
                clientLog("[LIVAClient] ✅ All batches complete for chunk \(chunkIndex), processing deferred chunk_ready")
                processChunkReady(chunkIndex: chunkIndex, totalSent: totalSent)
            } else {
                clientLog("[LIVAClient] ⚠️ Batches complete but NO FRAMES for chunk \(chunkIndex) - this shouldn't happen!")
            }
        }
    }

    private func handleChunkReady(chunkIndex: Int, totalSent: Int) {
        // PHASE 5: Check if batches are still processing + frames exist (single lock)
        let shouldDefer = batchTrackingLock.withLock { () -> (shouldDefer: Bool, reason: String?) in
            let pendingCount = pendingBatchCount[chunkIndex, default: 0]
            let framesExist = pendingOverlayFrames[chunkIndex] != nil && !(pendingOverlayFrames[chunkIndex]?.isEmpty ?? true)

            if pendingCount > 0 {
                // Batches still processing - defer chunk_ready
                deferredChunkReady[chunkIndex] = totalSent
                return (true, "⏳ Deferring chunk_ready for chunk \(chunkIndex) - \(pendingCount) batches still processing")
            }

            if !framesExist {
                // No frames yet - defer chunk_ready
                deferredChunkReady[chunkIndex] = totalSent
                return (true, "⏳ Deferring chunk_ready for chunk \(chunkIndex) - NO FRAMES YET (race condition)")
            }

            return (false, nil)
        }

        if shouldDefer.shouldDefer {
            if let reason = shouldDefer.reason {
                clientLog("[LIVAClient] \(reason)")
            }
            return
        }

        // All batches done AND frames exist - process chunk_ready
        processChunkReady(chunkIndex: chunkIndex, totalSent: totalSent)
    }

    /// Process chunk ready (extracted for deferred processing)
    /// NOTE: Must be called from main thread for thread safety with animation engine
    private func processChunkReady(chunkIndex: Int, totalSent: Int) {
        // DIAGNOSTICS: Record chunk ready (lightweight, can stay on current thread)
        LIVAPerformanceTracker.shared.recordChunkReady(chunkIndex: chunkIndex)
        LIVAPerformanceTracker.shared.logEvent(
            category: "CHUNK",
            event: "READY",
            details: ["chunkIndex": chunkIndex, "totalSent": totalSent]
        )

        // THREAD SAFETY: Copy data under lock, then release lock before processing
        let (overlayFramesCopy, animationNameFromDict) = batchTrackingLock.withLock { () -> ([OverlayFrame]?, String?) in
            let overlayFramesCopy = pendingOverlayFrames[chunkIndex]
            let animationNameFromDict = chunkAnimationNames[chunkIndex]
            // Clean up stored frames immediately (under lock)
            pendingOverlayFrames.removeValue(forKey: chunkIndex)
            chunkAnimationNames.removeValue(forKey: chunkIndex)
            return (overlayFramesCopy, animationNameFromDict)
        }

        // Get overlay position (accessed from current thread)
        let overlayPosition = pendingOverlayPositions[chunkIndex] ?? .zero
        pendingOverlayPositions.removeValue(forKey: chunkIndex)

        // Capture engine reference for background work
        let engine = newAnimationEngine

        // PERF FIX: Move ALL frame processing to background queue
        frameProcessingQueue.async { [weak self] in
            guard let self = self else { return }

            // Process overlay frames in background
            if var overlayFrames = overlayFramesCopy, !overlayFrames.isEmpty {
                // Sort by sequence index to ensure correct playback order
                overlayFrames.sort { $0.sequenceIndex < $1.sequenceIndex }

                // Update coordinates for each frame using the overlay position
                // Get first frame's image to determine frame size
                // CONTENT-BASED CACHING: Use overlayId from first frame
                let firstFrame = overlayFrames[0]
                let firstKey = getOverlayCacheKey(
                    for: firstFrame,
                    chunkIndex: chunkIndex,
                    sectionIndex: 0,
                    sequenceIndex: 0
                )
                var frameSize = CGSize(width: 300, height: 300) // Default size
                if let firstImage = engine?.getOverlayImage(forKey: firstKey) {
                    frameSize = firstImage.size
                    clientLog("[LIVAClient] 📐 Got overlay frame size: \(frameSize)")
                } else {
                    clientLog("[LIVAClient] ⚠️ Could not get overlay image for key: \(firstKey)")
                }

                // Update each frame with proper coordinates (EXPENSIVE - now in background!)
                var framesWithCoordinates: [OverlayFrame] = []
                framesWithCoordinates.reserveCapacity(overlayFrames.count)
                for frame in overlayFrames {
                    let coordinates = CGRect(
                        x: overlayPosition.x,
                        y: overlayPosition.y,
                        width: frameSize.width,
                        height: frameSize.height
                    )
                    let updatedFrame = OverlayFrame(
                        matchedSpriteFrameNumber: frame.matchedSpriteFrameNumber,
                        sheetFilename: frame.sheetFilename,
                        coordinates: coordinates,
                        imageData: frame.imageData,
                        sequenceIndex: frame.sequenceIndex,
                        animationName: frame.animationName,
                        originalFrameIndex: frame.originalFrameIndex,
                        overlayId: frame.overlayId,
                        char: frame.char,
                        viseme: frame.viseme
                    )
                    framesWithCoordinates.append(updatedFrame)
                }

                // Get animation name for this chunk (use copied value from earlier)
                let animationName = animationNameFromDict ?? framesWithCoordinates.first?.animationName ?? "talking_1_s_talking_1_e"

                // VERBOSE LOGGING: Log what overlayId is set on the frames being enqueued
                if let firstEnqueuedFrame = framesWithCoordinates.first {
                    clientLog("[LIVAClient] 📤 ENQUEUE chunk=\(chunkIndex) firstFrame.overlayId='\(firstEnqueuedFrame.overlayId ?? "nil")'")
                }

                // THREAD SAFETY FIX: Enqueue on main thread to avoid race condition with draw()
                // The overlayQueue is accessed by both socket callback thread and CADisplayLink thread
                // Without this, chunks could be lost due to thread-unsafe array operations
                let framesForEnqueue = framesWithCoordinates
                let animForEnqueue = animationName
                let chunkForEnqueue = chunkIndex
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.newAnimationEngine?.enqueueOverlaySet(
                        frames: framesForEnqueue,
                        chunkIndex: chunkForEnqueue,
                        animationName: animForEnqueue,
                        totalFrames: framesForEnqueue.count
                    )
                    clientLog("[LIVAClient] ✅ Enqueued overlay chunk \(chunkForEnqueue) with \(framesForEnqueue.count) frames, position: \(overlayPosition), animation: \(animForEnqueue)")
                }
            } else {
                // DIAGNOSTIC: Log when enqueue is skipped (should not happen after race condition fix)
                clientLog("[LIVAClient] ❌ SKIPPED ENQUEUE for chunk \(chunkIndex) - (pendingOverlayFrames was nil or empty!)")
            }
        }

        // PHASE 5: Clean up batch tracking
        batchTrackingLock.withLock {
            pendingBatchCount.removeValue(forKey: chunkIndex)
            deferredChunkReady.removeValue(forKey: chunkIndex)
        }
    }

    private func handleAudioEnd() {
        // Audio streaming is complete, animation will transition to idle
        // after current frames are played
        if state == .animating {
            state = .connected
        }
    }

    private func handlePlayBaseAnimation(_ animationName: String) {
        // FIX: Don't call reset() here - that clears the queue prematurely!
        // The web frontend sets pendingBaseAtEndRef and lets all chunks play first.
        // Backend sends play_base_animation BEFORE all chunks finish playing.
        // We just store the animation name and let the engine transition naturally
        // when all chunks are done (in animationEngineDidFinishAllChunks).
        clientLog("[LIVAClient] 📌 Storing pendingBaseAtEnd: \(animationName) (NOT resetting)")
        pendingBaseAtEnd = animationName
        // Don't change state or call reset - let animation continue playing
    }

    // MARK: - Animation Engine Callbacks (NEW)

    private func setupAnimationEngineCallbacks() {
        // New animation engine callbacks are handled via delegate (LIVAAnimationEngineDelegate)
        // See: animationEngine(_:playAudioData:forChunk:) and animationEngineDidFinishAllChunks(_:)
    }

    // MARK: - Audio Player Callbacks

    private func setupAudioPlayerCallbacks() {
        audioPlayer?.onChunkStart = { [weak self] chunkIndex in
            // Audio chunk started - sync with animation
        }

        audioPlayer?.onChunkComplete = { [weak self] chunkIndex in
            // Audio chunk complete
        }

        audioPlayer?.onPlaybackComplete = { [weak self] in
            // All audio complete - animation engine will transition to idle
            // when overlay frames finish
            if self?.state == .animating {
                self?.state = .connected
            }
        }
    }

    // MARK: - Base Frame Event Handlers

    private func handleAnimationTotalFrames(_ animationName: String, totalFrames: Int) {
        baseFrameManager?.registerAnimation(name: animationName, totalFrames: totalFrames)
    }

    private func handleBaseFrameReceived(_ animationName: String, frameIndex: Int, data: Data) {
        guard let rawImage = UIImage(data: data) else { return }

        // CRITICAL: Force image decompression when receiving base frames
        // UIImage defers JPEG/PNG decompression until first draw, which
        // causes freezes during animation. Pre-decode so base frames are
        // ready to render immediately. Force decompression to prevent render thread blocking.
        let image = forceImageDecompression(rawImage)

        baseFrameManager?.addFrame(image, animationName: animationName, frameIndex: frameIndex)
    }

    private func handleAnimationFramesComplete(_ animationName: String) {
        // Animation complete, check if idle is ready
        if animationName == "idle_1_s_idle_1_e" && !isBaseFramesLoaded {
            isBaseFramesLoaded = true
            notifyIdleReady()
        }

        // Load ALL completed animations into new animation engine (not just idle)
        if let frames = baseFrameManager?.getFrames(for: animationName), !frames.isEmpty {
            let expectedCount = baseFrameManager?.getTotalFrames(for: animationName) ?? frames.count
            newAnimationEngine?.loadBaseAnimation(
                name: animationName,
                frames: frames,
                expectedCount: expectedCount
            )

            clientLog("[LIVAClient] ✅ Loaded base animation into new engine: \(animationName), frames: \(frames.count)")

            // Track loaded animation (for readyAnimations communication with backend)
            loadedAnimationNames.insert(animationName)
            clientLog("[LIVAClient] 📋 Animation ready: \(animationName) (total ready: \(loadedAnimationNames.count))")

            // Start rendering if this is the idle animation
            if animationName == "idle_1_s_idle_1_e" {
                newAnimationEngine?.startRendering()
                clientLog("[LIVAClient] ▶️ Started new animation engine rendering")
            }
        } else {
            clientLog("[LIVAClient] ⚠️ No frames to load for animation: \(animationName)")
        }
    }

    // NEW - Handle animation chunk metadata
    private func handleAnimationChunkMetadata(_ dict: [String: Any]) {
        guard let chunkIndex = dict["chunk_index"] as? Int,
              let totalFrames = dict["total_frame_images"] as? Int,
              let sectionsArray = dict["sections"] as? [[String: Any]] else {
            clientLog("[LIVAClient] ⚠️ Invalid animation_chunk_metadata format")
            return
        }

        clientLog("[LIVAClient] 📦 Received chunk metadata: chunk \(chunkIndex), total frames: \(totalFrames)")

        // Parse overlay frames from sections
        var overlayFrames: [OverlayFrame] = []

        for (sectionIdx, sectionDict) in sectionsArray.enumerated() {
            guard let framesArray = sectionDict["frames"] as? [[String: Any]] else { continue }

            for (seqIdx, frameDict) in framesArray.enumerated() {
                // Parse coordinates
                let coordinates = parseCoordinates(frameDict["coordinates"])

                let frame = OverlayFrame(
                    matchedSpriteFrameNumber: frameDict["matched_sprite_frame_number"] as? Int ?? 0,
                    sheetFilename: frameDict["sheet_filename"] as? String ?? "",
                    coordinates: coordinates,
                    imageData: nil, // Will be filled via receive_frame_image
                    sequenceIndex: seqIdx,
                    animationName: frameDict["animation_name"] as? String ?? "",
                    originalFrameIndex: frameDict["frame_index"] as? Int ?? 0,
                    overlayId: frameDict["overlay_id"] as? String,
                    char: frameDict["char"] as? String,
                    viseme: frameDict["viseme"] as? String
                )
                overlayFrames.append(frame)
            }
        }

        // Get animation name from first section
        let animationName = sectionsArray.first?["animation_name"] as? String ?? "talking_1_s_talking_1_e"

        // THREAD SAFETY FIX: Enqueue on main thread to avoid race condition with draw()
        let framesForEnqueue = overlayFrames
        let animForEnqueue = animationName
        let chunkForEnqueue = chunkIndex
        let totalForEnqueue = totalFrames
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.newAnimationEngine?.enqueueOverlaySet(
                frames: framesForEnqueue,
                chunkIndex: chunkForEnqueue,
                animationName: animForEnqueue,
                totalFrames: totalForEnqueue
            )
            clientLog("[LIVAClient] ✅ Enqueued overlay chunk \(chunkForEnqueue), frames: \(framesForEnqueue.count)")
        }
    }

    // NEW - Handle individual frame image
    private func handleFrameImageReceived(_ dict: [String: Any]) {
        guard let chunkIndex = dict["chunk_index"] as? Int,
              let sectionIndex = dict["section_index"] as? Int,
              let sequenceIndex = dict["sequence_index"] as? Int else {
            clientLog("[LIVAClient] ⚠️ Invalid receive_frame_image format")
            return
        }

        // Decode image data (could be base64 string or binary Data)
        var imageData: Data?

        if let dataString = dict["image_data"] as? String {
            // Base64 encoded
            imageData = Data(base64Encoded: dataString)
        } else if let dataBinary = dict["image_data"] as? Data {
            // Binary data
            imageData = dataBinary
        }

        guard let data = imageData,
              let image = UIImage(data: data) else {
            clientLog("[LIVAClient] ⚠️ Failed to decode overlay image for chunk \(chunkIndex)")
            return
        }

        // CONTENT-BASED CACHING: Use overlay_id if available, otherwise fallback to positional key
        let key: String
        if let overlayId = dict["overlay_id"] as? String, !overlayId.isEmpty {
            key = overlayId
        } else if let animationName = dict["animation_name"] as? String,
                  let spriteFrame = dict["matched_sprite_frame_number"] as? Int,
                  let sheetFilename = dict["sheet_filename"] as? String {
            // Construct content-based key from available fields
            key = "\(animationName)/\(spriteFrame)/\(sheetFilename)"
        } else {
            // Fallback to positional key (not recommended - content-based keys preferred)
            key = "\(chunkIndex)_\(sectionIndex)_\(sequenceIndex)"
        }

        newAnimationEngine?.cacheOverlayImage(image, forKey: key, chunkIndex: chunkIndex)
    }

    // Helper: Parse coordinates array to CGRect
    private func parseCoordinates(_ coordArray: Any?) -> CGRect {
        guard let coords = coordArray as? [CGFloat], coords.count == 4 else {
            return .zero
        }
        return CGRect(x: coords[0], y: coords[1], width: coords[2], height: coords[3])
    }

    // MARK: - Base Frame Manager Callbacks

    private func setupBaseFrameManagerCallbacks() {
        baseFrameManager?.onAnimationLoaded = { [weak self] animationName in
            // Animation fully loaded
        }

        baseFrameManager?.onLoadProgress = { [weak self] animationName, progress in
            // Update loading progress if UI wants to show it
        }

        baseFrameManager?.onFirstIdleFrameReady = { [weak self] in
            // First idle frame received - can start showing avatar
            // NOTE: Animation engine handles rendering, no setup needed here
        }
    }

    private func loadBaseFramesFromCache() {
        // Use manifest animation names if available, otherwise fall back to hardcoded priority list
        // This ensures we load all animations the server provides, not just hardcoded ones
        let animationsToLoad = manifestAnimationNames.isEmpty ? ANIMATION_LOAD_ORDER : manifestAnimationNames

        // Try to load from disk cache
        for animationName in animationsToLoad {
            if baseFrameManager?.loadFromCache(animationName: animationName) == true {
                // Track loaded animation (for readyAnimations communication with backend)
                loadedAnimationNames.insert(animationName)

                if animationName == "idle_1_s_idle_1_e" {
                    isBaseFramesLoaded = true
                }
            }
        }

        if !loadedAnimationNames.isEmpty {
            clientLog("[LIVAClient] 📋 Loaded \(loadedAnimationNames.count) animations from cache")
        }
    }

    private func notifyIdleReady() {
        // Idle animation is fully loaded, animation can start
        // New animation engine loads base frames directly via loadAnimation()

        // If waiting to connect, proceed now
        if pendingConnect {
            pendingConnect = false
            // Continue with connection flow
        }
    }

    // MARK: - Ready Animations (for backend communication)

    /// Get list of animation names that are fully loaded and ready
    /// Returns array sorted by priority (ANIMATION_LOAD_ORDER first, then any extras)
    /// This matches web frontend's getReadyAnimations() behavior
    private func getReadyAnimations() -> [String] {
        let prioritySet = Set(ANIMATION_LOAD_ORDER)
        var ready: [String] = []

        // First: animations from priority list that are loaded (maintains priority order)
        for name in ANIMATION_LOAD_ORDER {
            if loadedAnimationNames.contains(name) {
                ready.append(name)
            }
        }

        // Second: any additional loaded animations not in priority list (sorted alphabetically)
        for name in loadedAnimationNames.sorted() {
            if !prioritySet.contains(name) {
                ready.append(name)
            }
        }

        return ready
    }

    // MARK: - Error Handling

    private func handleError(_ error: LIVAError) {
        state = .error(error)
        DispatchQueue.main.async { [weak self] in
            self?.onError?(error)
        }
    }

    // MARK: - Memory Management

    @objc private func handleMemoryWarning() {
        // Reset animation engine on memory warning
        newAnimationEngine?.reset()
    }

    // MARK: - Cleanup

    deinit {
        NotificationCenter.default.removeObserver(self)
        disconnect()
    }
}

// MARK: - Debug

public extension LIVAClient {
    /// Debug description of current state
    var debugDescription: String {
        return """
        LIVAClient:
          State: \(state)
          Connected: \(isConnected)
          Animation: \(newAnimationEngine?.getDebugInfo() ?? [:])
          Audio queue: \(audioPlayer?.queuedChunkCount ?? 0)
        """
    }

    /// Get debug logs from SDK
    func getDebugLogs() -> String {
        return LIVADebugLog.shared.getLogsString()
    }

    /// Get array of debug log entries
    func getDebugLogEntries() -> [String] {
        return LIVADebugLog.shared.getLogs()
    }

    /// Get real-time animation debug info for Flutter display
    func getAnimationDebugInfo() -> [String: Any] {
        // Use new animation engine info if available
        if let engineInfo = newAnimationEngine?.getDebugInfo() {
            var info = engineInfo
            info["state"] = stateToString(state)
            info["isConnected"] = isConnected
            return info
        }

        // Fallback with basic state info
        return [
            "fps": 0.0,
            "animationName": "unknown",
            "frameNumber": 0,
            "totalFrames": 0,
            "mode": "idle",
            "hasOverlay": false,
            "state": stateToString(state),
            "isConnected": isConnected
        ]
    }

    /// Convert state to string for debug info
    private func stateToString(_ state: LIVAState) -> String {
        switch state {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .animating: return "animating"
        case .error: return "error"
        }
    }

    // MARK: - Performance Diagnostics

    /// Print diagnostic report to console
    func printDiagnosticReport() {
        LIVAPerformanceTracker.shared.printReport()
    }

    /// Get performance status string
    func getPerformanceStatus() -> String {
        return LIVAPerformanceTracker.shared.getStatus()
    }
}

// MARK: - LIVAAnimationEngineDelegate

extension LIVAClient: LIVAAnimationEngineDelegate {
    /// Called when animation engine wants to start audio for a chunk (synced with animation)
    func animationEngine(_ engine: LIVAAnimationEngine, playAudioData data: Data, forChunk chunkIndex: Int) {
        // Play audio NOW - this is called exactly when the first overlay frame renders
        // Perfect lip sync: audio and animation start together
        audioPlayer?.queueAudio(data, chunkIndex: chunkIndex)
        clientLog("[LIVAClient] 🔊 Playing audio for chunk \(chunkIndex) - synced with animation")
    }

    /// Called when all overlay chunks have finished playing
    func animationEngineDidFinishAllChunks(_ engine: LIVAAnimationEngine) {
        // Clear pendingBaseAtEnd (like web's pendingBaseAtEndRef.current = null)
        let wasWaiting = pendingBaseAtEnd != nil
        pendingBaseAtEnd = nil

        clientLog("[LIVAClient] ✅ All overlay chunks complete - transitioning to idle (pendingBaseWasSet: \(wasWaiting))")

        // Update state to connected (not animating anymore)
        if state == .animating {
            state = .connected
        }
    }
}
