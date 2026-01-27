//
//  LIVAClient.swift
//  LIVAAnimation
//
//  Main SDK interface for LIVA avatar animations.
//

import UIKit
import os.log

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

    /// Connect to the backend server
    public func connect() {
        guard let config = configuration else {
            handleError(.notConfigured)
            return
        }

        state = .connecting

        // Create socket manager
        socketManager = LIVASocketManager(configuration: config)
        setupSocketCallbacks()
        socketManager?.connect()
    }

    /// Disconnect from the server
    public func disconnect() {
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

        // Clear pending state in client
        pendingOverlayPositions.removeAll()
        pendingOverlayFrames.removeAll()
        chunkAnimationNames.removeAll()

        // PHASE 5: Clear batch tracking state
        batchTrackingLock.lock()
        pendingBatchCount.removeAll()
        deferredChunkReady.removeAll()
        batchTrackingLock.unlock()

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
    private func handleAnimationsManifest(_ animations: [String: Any]) {
        guard let config = configuration else { return }

        let animationNames = Set(animations.keys)
        clientLog("[LIVAClient] 📋 Received manifest with \(animationNames.count) animations: \(Array(animationNames).prefix(5))...")

        // Request animations in priority order
        for animationName in ANIMATION_LOAD_ORDER {
            // Check if animation exists in manifest (animations is a dictionary with animation names as keys)
            if animationNames.contains(animationName) {
                clientLog("[LIVAClient] 📤 Requesting animation: \(animationName)")
                socketManager?.requestBaseAnimation(name: animationName, agentId: config.agentId)
            } else {
                clientLog("[LIVAClient] ⚠️ Animation not in manifest: \(animationName)")
            }
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

        clientLog("[LIVAClient] 📥 handleFrameBatchReceived: chunk=\(chunkIndex), batch=\(batchIndex), frames=\(frameCount)")

        // Initialize tracking arrays for this chunk if needed (once per chunk)
        if pendingOverlayFrames[chunkIndex] == nil {
            pendingOverlayFrames[chunkIndex] = []
            pendingOverlayFrames[chunkIndex]?.reserveCapacity(120) // Typical chunk size
        }

        // PHASE 1 & 5: Increment pending batch count (track async processing)
        batchTrackingLock.lock()
        pendingBatchCount[chunkIndex, default: 0] += 1
        batchTrackingLock.unlock()

        // Cache engine reference once
        let engine = newAnimationEngine

        // PHASE 1: Process FIRST frame immediately (critical for playback start)
        // This ensures the first overlay is available ASAP for buffer readiness check
        if let firstFrame = frames.first {
            processFrameMetadata(firstFrame, chunkIndex: chunkIndex, engine: engine)
        }

        // PHASE 1: Process remaining frames in batches with yields to event loop
        // This matches web frontend's pattern: setTimeout(0) between batches
        if frames.count > 1 {
            var currentIndex = 1

            func processNextBatch() {
                let endIndex = min(currentIndex + self.frameBatchSize, frames.count)

                // Process batch of frames
                for i in currentIndex..<endIndex {
                    self.processFrameMetadata(frames[i], chunkIndex: chunkIndex, engine: engine)
                }

                currentIndex = endIndex

                // If more frames, yield to run loop then continue
                if currentIndex < frames.count {
                    DispatchQueue.main.async {
                        processNextBatch()
                    }
                } else {
                    // Batch complete - decrement pending count and check for deferred chunk ready
                    self.onBatchComplete(chunkIndex: chunkIndex)
                }
            }

            // Start batch processing after yielding to run loop
            DispatchQueue.main.async {
                processNextBatch()
            }
        } else {
            // Only one frame - mark batch complete immediately
            onBatchComplete(chunkIndex: chunkIndex)
        }

        // NOTE: Legacy frameDecoder path removed - was causing double decode work
        // The new processFrameMetadata() path handles all frame processing
    }

    /// Process a single frame's metadata and queue async image decode
    /// PHASE 1: Extracted for batched processing
    private func processFrameMetadata(_ frame: LIVASocketManager.FrameData, chunkIndex: Int, engine: LIVAAnimationEngine?) {
        let contentKey = frame.contentBasedCacheKey

        // ASYNC: Decode image on background (just dispatch, no completion closure overhead)
        engine?.processAndCacheOverlayImageAsync(
            base64Data: frame.imageData,
            key: contentKey,
            chunkIndex: chunkIndex,
            completion: nil  // Skip completion to reduce overhead
        )

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

        // Append to pending frames
        pendingOverlayFrames[chunkIndex]?.append(overlayFrame)

        // Track animation name
        if !frame.animationName.isEmpty && chunkAnimationNames[chunkIndex] == nil {
            chunkAnimationNames[chunkIndex] = frame.animationName
        }
    }

    /// PHASE 5: Called when a batch finishes processing
    /// Decrements pending count and processes deferred chunk_ready if all batches done
    private func onBatchComplete(chunkIndex: Int) {
        batchTrackingLock.lock()
        pendingBatchCount[chunkIndex, default: 1] -= 1
        let remaining = pendingBatchCount[chunkIndex] ?? 0
        let deferredTotal = remaining == 0 ? deferredChunkReady.removeValue(forKey: chunkIndex) : nil
        batchTrackingLock.unlock()

        // If all batches done and chunk_ready was deferred, process it now
        if let totalSent = deferredTotal {
            clientLog("[LIVAClient] ✅ All batches complete for chunk \(chunkIndex), processing deferred chunk_ready")
            processChunkReady(chunkIndex: chunkIndex, totalSent: totalSent)
        }
    }

    private func handleChunkReady(chunkIndex: Int, totalSent: Int) {
        // PHASE 5: Check if batches are still processing
        batchTrackingLock.lock()
        let pendingCount = pendingBatchCount[chunkIndex, default: 0]
        if pendingCount > 0 {
            // Batches still processing - defer chunk_ready
            deferredChunkReady[chunkIndex] = totalSent
            batchTrackingLock.unlock()
            clientLog("[LIVAClient] ⏳ Deferring chunk_ready for chunk \(chunkIndex) - \(pendingCount) batches still processing")
            return
        }
        batchTrackingLock.unlock()

        // All batches done - process chunk_ready
        processChunkReady(chunkIndex: chunkIndex, totalSent: totalSent)
    }

    /// Process chunk ready (extracted for deferred processing)
    private func processChunkReady(chunkIndex: Int, totalSent: Int) {
        // Get overlay position from audio event
        let overlayPosition = pendingOverlayPositions[chunkIndex] ?? .zero

        // NEW - Enqueue overlay set in new animation engine
        if var overlayFrames = pendingOverlayFrames[chunkIndex], !overlayFrames.isEmpty {
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
            if let firstImage = newAnimationEngine?.getOverlayImage(forKey: firstKey) {
                frameSize = firstImage.size
                clientLog("[LIVAClient] 📐 Got overlay frame size: \(frameSize)")
            } else {
                clientLog("[LIVAClient] ⚠️ Could not get overlay image for key: \(firstKey)")
            }

            // Update each frame with proper coordinates
            var framesWithCoordinates: [OverlayFrame] = []
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

            // Get animation name for this chunk
            let animationName = chunkAnimationNames[chunkIndex] ?? framesWithCoordinates.first?.animationName ?? "talking_1_s_talking_1_e"

            // Enqueue for playback
            newAnimationEngine?.enqueueOverlaySet(
                frames: framesWithCoordinates,
                chunkIndex: chunkIndex,
                animationName: animationName,
                totalFrames: framesWithCoordinates.count
            )

            clientLog("[LIVAClient] ✅ Enqueued overlay chunk \(chunkIndex) with \(framesWithCoordinates.count) frames, position: \(overlayPosition), animation: \(animationName)")
        }

        // Clean up stored frames
        pendingOverlayPositions.removeValue(forKey: chunkIndex)
        pendingOverlayFrames.removeValue(forKey: chunkIndex)
        chunkAnimationNames.removeValue(forKey: chunkIndex)

        // PHASE 5: Clean up batch tracking
        batchTrackingLock.lock()
        pendingBatchCount.removeValue(forKey: chunkIndex)
        deferredChunkReady.removeValue(forKey: chunkIndex)
        batchTrackingLock.unlock()
    }

    private func handleAudioEnd() {
        // Audio streaming is complete, animation will transition to idle
        // after current frames are played
        if state == .animating {
            state = .connected
        }
    }

    private func handlePlayBaseAnimation(_ animationName: String) {
        // Handle base/idle animation request
        // This typically comes after speaking ends
        newAnimationEngine?.reset()
        if state == .animating {
            state = .connected
        }
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
        guard let image = UIImage(data: data) else { return }
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

        // Enqueue for playback
        newAnimationEngine?.enqueueOverlaySet(
            frames: overlayFrames,
            chunkIndex: chunkIndex,
            animationName: animationName,
            totalFrames: totalFrames
        )

        clientLog("[LIVAClient] ✅ Enqueued overlay chunk \(chunkIndex), frames: \(overlayFrames.count)")
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
            // Fallback to positional key
            key = getOverlayKey(
                chunkIndex: chunkIndex,
                sectionIndex: sectionIndex,
                sequenceIndex: sequenceIndex
            )
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
            self?.canvasView?.setBaseFrameManager(self?.baseFrameManager)
            // NOTE: Don't start legacy canvas render loop - new animation engine handles rendering
            // self?.canvasView?.startRenderLoop()
        }
    }

    private func loadBaseFramesFromCache() {
        // Try to load from disk cache
        for animationName in ANIMATION_LOAD_ORDER {
            if baseFrameManager?.loadFromCache(animationName: animationName) == true {
                if animationName == "idle_1_s_idle_1_e" {
                    isBaseFramesLoaded = true
                }
            }
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
        clientLog("[LIVAClient] ✅ All overlay chunks complete - transitioning to idle")

        // Update state to connected (not animating anymore)
        if state == .animating {
            state = .connected
        }
    }
}
