//
//  LIVAClient.swift
//  LIVAAnimation
//
//  Main SDK interface for LIVA avatar animations.
//

import UIKit

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
    private var frameDecoder: FrameDecoder?
    private var animationEngine: AnimationEngine? // OLD - Legacy support
    private var newAnimationEngine: LIVAAnimationEngine? // NEW - Base + overlay rendering
    private var audioPlayer: AudioPlayer?
    private var baseFrameManager: BaseFrameManager?
    private weak var canvasView: LIVACanvasView?

    // MARK: - Base Frame Loading State

    private var isBaseFramesLoaded: Bool = false
    private var pendingConnect: Bool = false

    // MARK: - State Tracking

    private var currentChunkFrames: [Int: [DecodedFrame]] = [:]
    private var pendingOverlayPositions: [Int: CGPoint] = [:]

    // MARK: - Public Methods

    /// Configure the SDK with connection parameters
    /// - Parameter config: Configuration object
    public func configure(_ config: LIVAConfiguration) {
        self.configuration = config

        // Initialize components
        frameDecoder = FrameDecoder()
        animationEngine = AnimationEngine() // OLD - Legacy support
        audioPlayer = AudioPlayer()
        baseFrameManager = BaseFrameManager()

        // NEW - Initialize new animation engine (will replace old one)
        // Note: Needs canvas view to be attached first
        // Will be initialized in attachView()

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
        view.animationEngine = animationEngine // OLD - Legacy support

        // NEW - Initialize new animation engine with canvas view
        newAnimationEngine = LIVAAnimationEngine(canvasView: view)

        print("[LIVAClient] ✅ Attached canvas view and initialized new animation engine")
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
        canvasView?.stopRenderLoop()
        audioPlayer?.stop()
        animationEngine?.clearQueue()
        newAnimationEngine?.stopRendering() // NEW
        newAnimationEngine?.reset() // NEW
        socketManager?.disconnect()
        socketManager = nil
        state = .idle
    }

    // MARK: - Socket Callbacks

    private func setupSocketCallbacks() {
        guard let socket = socketManager else { return }

        socket.onConnect = { [weak self] in
            self?.state = .connected
            self?.canvasView?.startRenderLoop()
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
    }

    // MARK: - Event Handlers

    private func handleAudioReceived(_ audioChunk: LIVASocketManager.AudioChunk) {
        // Update state to animating
        if state == .connected {
            state = .animating
        }

        // Queue audio for playback
        audioPlayer?.queueAudio(audioChunk.audioData, chunkIndex: audioChunk.chunkIndex)

        // Store overlay position for this chunk
        if let firstFrame = audioChunk.animationFramesChunk.first {
            pendingOverlayPositions[audioChunk.chunkIndex] = firstFrame.zoneTopLeft
        }
    }

    private func handleFrameBatchReceived(_ frameBatch: LIVASocketManager.FrameBatch) {
        // Decode frames asynchronously
        frameDecoder?.decodeBatch(frameBatch) { [weak self] decodedFrames in
            guard let self = self else { return }

            // Store decoded frames for this chunk
            let chunkIndex = frameBatch.chunkIndex
            if self.currentChunkFrames[chunkIndex] == nil {
                self.currentChunkFrames[chunkIndex] = []
            }
            self.currentChunkFrames[chunkIndex]?.append(contentsOf: decodedFrames)
        }
    }

    private func handleChunkReady(chunkIndex: Int, totalSent: Int) {
        // Get all frames for this chunk
        guard let frames = currentChunkFrames[chunkIndex], !frames.isEmpty else { return }

        // Get overlay position
        let overlayPosition = pendingOverlayPositions[chunkIndex] ?? .zero

        // Create animation chunk
        let animationChunk = AnimationChunk(
            chunkIndex: chunkIndex,
            frames: frames,
            overlayPosition: overlayPosition,
            animationName: frames.first?.animationName ?? "",
            isReady: true
        )

        // Queue for animation
        animationEngine?.enqueueChunk(animationChunk)

        // Also add frames directly for immediate playback
        animationEngine?.enqueueFrames(frames, forChunk: chunkIndex)
        animationEngine?.setOverlayPosition(overlayPosition)

        // Clean up stored frames
        currentChunkFrames.removeValue(forKey: chunkIndex)
        pendingOverlayPositions.removeValue(forKey: chunkIndex)
    }

    private func handleAudioEnd() {
        // Audio streaming is complete, animation will transition to idle
        // after current frames are played
        animationEngine?.onAnimationComplete = { [weak self] in
            if self?.state == .animating {
                self?.state = .connected
            }
            self?.animationEngine?.transitionToIdle()
        }
    }

    private func handlePlayBaseAnimation(_ animationName: String) {
        // Handle base/idle animation request
        // This typically comes after speaking ends
        animationEngine?.transitionToIdle()
        if state == .animating {
            state = .connected
        }
    }

    // MARK: - Animation Engine Callbacks

    private func setupAnimationEngineCallbacks() {
        animationEngine?.onModeChange = { [weak self] mode in
            switch mode {
            case .talking:
                if self?.state == .connected {
                    self?.state = .animating
                }
            case .idle, .transition:
                if self?.state == .animating {
                    self?.state = .connected
                }
            }
        }

        animationEngine?.onChunkComplete = { [weak self] chunkIndex in
            // Chunk animation complete
        }
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
            // All audio complete
            self?.animationEngine?.transitionToIdle()
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

        // NEW - Also load into new animation engine
        if let frames = baseFrameManager?.getFrames(for: animationName) {
            let expectedCount = baseFrameManager?.getTotalFrames(for: animationName) ?? frames.count
            newAnimationEngine?.loadBaseAnimation(
                name: animationName,
                frames: frames,
                expectedCount: expectedCount
            )

            print("[LIVAClient] ✅ Loaded base animation into new engine: \(animationName), frames: \(frames.count)")

            // Start rendering if this is the idle animation
            if animationName == "idle_1_s_idle_1_e" {
                newAnimationEngine?.startRendering()
                print("[LIVAClient] ▶️ Started new animation engine rendering")
            }
        }
    }

    // NEW - Handle animation chunk metadata
    private func handleAnimationChunkMetadata(_ dict: [String: Any]) {
        guard let chunkIndex = dict["chunk_index"] as? Int,
              let totalFrames = dict["total_frame_images"] as? Int,
              let sectionsArray = dict["sections"] as? [[String: Any]] else {
            print("[LIVAClient] ⚠️ Invalid animation_chunk_metadata format")
            return
        }

        print("[LIVAClient] 📦 Received chunk metadata: chunk \(chunkIndex), total frames: \(totalFrames)")

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

        print("[LIVAClient] ✅ Enqueued overlay chunk \(chunkIndex), frames: \(overlayFrames.count)")
    }

    // NEW - Handle individual frame image
    private func handleFrameImageReceived(_ dict: [String: Any]) {
        guard let chunkIndex = dict["chunk_index"] as? Int,
              let sectionIndex = dict["section_index"] as? Int,
              let sequenceIndex = dict["sequence_index"] as? Int else {
            print("[LIVAClient] ⚠️ Invalid receive_frame_image format")
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
            print("[LIVAClient] ⚠️ Failed to decode overlay image for chunk \(chunkIndex)")
            return
        }

        // Cache for later playback
        let key = getOverlayKey(
            chunkIndex: chunkIndex,
            sectionIndex: sectionIndex,
            sequenceIndex: sequenceIndex
        )

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
            self?.canvasView?.startRenderLoop()
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
        animationEngine?.setBaseFrameManager(baseFrameManager)

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
        frameDecoder?.handleMemoryWarning()
        animationEngine?.clearQueue()
        // NEW - Reset new engine on memory warning
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
          Animation: \(animationEngine?.debugDescription ?? "nil")
          Audio queue: \(audioPlayer?.queuedChunkCount ?? 0)
        """
    }
}
