//
//  SocketManager.swift
//  LIVAAnimation
//
//  Socket.IO connection management for LIVA backend.
//

import Foundation
import SocketIO

/// Log to shared debug log for socket events
private func socketLog(_ message: String) {
    LIVADebugLog.shared.log(message)
    print(message)
}

/// Manages Socket.IO connection to AnnaOS-API backend
final class LIVASocketManager {

    // MARK: - Types

    /// Audio chunk received from server
    struct AudioChunk {
        let audioData: Data
        let chunkIndex: Int
        let masterChunkIndex: Int
        let animationFramesChunk: [AnimationFrameChunk]
        let totalFrameImages: Int
        let timestamp: String
    }

    /// Animation frame chunk metadata
    struct AnimationFrameChunk {
        let animationName: String
        let zoneTopLeft: CGPoint
        let masterFramePlayAt: Int
        let mode: String
    }

    /// Frame batch received from server
    struct FrameBatch {
        let frames: [FrameData]
        let chunkIndex: Int
        let batchIndex: Int
        let batchStartIndex: Int
        let batchSize: Int
        let totalBatches: Int
        let emissionTimestamp: Int64
    }

    /// Individual frame data
    struct FrameData {
        let imageData: String  // Base64 string (legacy)
        let imageDataRaw: Data?  // Raw binary data (preferred - avoids base64 roundtrip)
        let imageMime: String
        let spriteIndexFolder: Int
        let sheetFilename: String
        let animationName: String
        let sequenceIndex: Int
        let sectionIndex: Int
        let frameIndex: Int
        let matchedSpriteFrameNumber: Int
        let char: String
        let overlayId: String?  // Content-based cache key from backend

        /// Generate content-based cache key (same format as web)
        /// Format: "{animation_name}/{matched_sprite_frame_number}/{sheet_filename}"
        var contentBasedCacheKey: String {
            // Use backend's overlay_id if available
            if let overlayId = overlayId, !overlayId.isEmpty {
                return overlayId
            }
            // Fallback: construct from available fields (matches web format)
            return "\(animationName)/\(matchedSpriteFrameNumber)/\(sheetFilename)"
        }
    }

    // MARK: - Properties

    private let configuration: LIVAConfiguration
    private var manager: SocketIO.SocketManager?
    private var socket: SocketIOClient?

    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10
    private let maxReconnectDelay: TimeInterval = 30
    private var isManualDisconnect = false

    // MARK: - Callbacks

    var onConnect: (() -> Void)?
    var onDisconnect: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    var onAudioReceived: ((AudioChunk) -> Void)?
    var onFrameBatchReceived: ((FrameBatch) -> Void)?
    var onChunkReady: ((Int, Int) -> Void)?
    var onAudioEnd: (() -> Void)?
    var onPlayBaseAnimation: ((String) -> Void)?

    // Base frame callbacks
    var onAnimationTotalFrames: ((String, Int) -> Void)?
    var onBaseFrameReceived: ((String, Int, Data) -> Void)?
    var onAnimationFramesComplete: ((String) -> Void)?

    // NEW - Animation engine callbacks (chunk streaming)
    var onAnimationChunkMetadata: (([String: Any]) -> Void)?
    var onFrameImageReceived: (([String: Any]) -> Void)?

    // NEW - Base animations manifest callback
    // Manifest contains: { "animations": { "name": {"frames": N, "version": "xxx"}, ... } }
    var onAnimationsManifest: (([String: Any]) -> Void)?

    // MARK: - Initialization

    init(configuration: LIVAConfiguration) {
        self.configuration = configuration
    }

    // MARK: - Connection

    /// Connect to the backend server
    func connect() {
        guard let url = URL(string: configuration.serverURL) else {
            onError?(LIVAError.connectionFailed("Invalid server URL"))
            return
        }

        isManualDisconnect = false

        // Build connection parameters dictionary
        // Backend (Flask-SocketIO) reads from request.args via Socket.IO GET parameters
        let connectionParams: [String: Any] = [
            "user_id": configuration.userId,
            "agent_id": configuration.agentId,
            "instance_id": configuration.instanceId,
            "userResolution": configuration.resolution
        ]

        // Configure Socket.IO manager with connectParams (GET parameters)
        // This is the correct way to pass parameters - Socket.IO adds them to the handshake URL
        manager = SocketIO.SocketManager(
            socketURL: url,
            config: [
                .log(true), // Enable logging to debug connection issues
                .compress,
                .connectParams(connectionParams), // Pass as Socket.IO GET parameters
                .forceWebsockets(false),
                .reconnects(false) // We handle reconnection manually
            ]
        )

        socket = manager?.defaultSocket
        setupEventHandlers()

        socketLog("[LIVASocketManager] Connecting to: \(url.absoluteString)")
        socketLog("[LIVASocketManager] Connection params: \(connectionParams)")

        socket?.connect()
    }

    /// Disconnect from the server
    func disconnect() {
        isManualDisconnect = true
        socket?.disconnect()
        manager = nil
        socket = nil
        reconnectAttempts = 0
    }

    /// Check if connected
    var isConnected: Bool {
        return socket?.status == .connected
    }

    // MARK: - Event Handlers

    private func setupEventHandlers() {
        guard let socket = socket else { return }

        // Connection events
        socket.on(clientEvent: .connect) { [weak self] _, _ in
            socketLog("[LIVASocketManager] ✅ Connected successfully!")
            self?.reconnectAttempts = 0
            self?.onConnect?()
        }

        socket.on(clientEvent: .disconnect) { [weak self] data, _ in
            guard let self = self else { return }
            let reason = (data.first as? String) ?? "unknown"
            socketLog("[LIVASocketManager] ❌ Disconnected. Reason: \(reason)")
            self.onDisconnect?(reason)

            if !self.isManualDisconnect {
                self.scheduleReconnect()
            }
        }

        socket.on(clientEvent: .error) { [weak self] data, _ in
            let errorMessage = (data.first as? String) ?? "Unknown socket error"
            socketLog("[LIVASocketManager] ❌ Socket error: \(errorMessage)")
            socketLog("[LIVASocketManager] Error data: \(data)")
            self?.onError?(LIVAError.connectionFailed(errorMessage))
        }

        socket.on(clientEvent: .statusChange) { [weak self] data, _ in
            socketLog("[LIVASocketManager] Status change: \(data)")
        }

        socket.on(clientEvent: .reconnect) { [weak self] data, _ in
            socketLog("[LIVASocketManager] Reconnecting...")
        }

        socket.on(clientEvent: .reconnectAttempt) { [weak self] data, _ in
            socketLog("[LIVASocketManager] Reconnect attempt...")
        }

        // Audio event
        socket.on("receive_audio") { [weak self] data, _ in
            socketLog("[LIVASocketManager] 📨 RECEIVED: receive_audio event")
            self?.handleAudioEvent(data)
        }

        // Frame batch event
        socket.on("receive_frame_images_batch") { [weak self] data, _ in
            if let dict = data.first as? [String: Any] {
                let chunkIndex = dict["chunk_index"] as? Int ?? -1
                let batchIndex = dict["batch_index"] as? Int ?? -1
                socketLog("[LIVASocketManager] 📨 RECEIVED: receive_frame_images_batch chunk=\(chunkIndex) batch=\(batchIndex)")
            }
            self?.handleFrameBatchEvent(data)
        }

        // Chunk ready event
        socket.on("chunk_images_ready") { [weak self] data, _ in
            if let dict = data.first as? [String: Any] {
                let chunkIndex = dict["chunk_index"] as? Int ?? -1
                socketLog("[LIVASocketManager] 📨 RECEIVED: chunk_images_ready chunk=\(chunkIndex)")
            }
            self?.handleChunkReadyEvent(data)
        }

        // Audio end event
        socket.on("audio_end") { [weak self] _, _ in
            self?.onAudioEnd?()
        }

        // Play base animation event
        socket.on("play_base_animation") { [weak self] data, _ in
            self?.handlePlayAnimationEvent(data)
        }

        socket.on("play_animation") { [weak self] data, _ in
            self?.handlePlayAnimationEvent(data)
        }

        // Base frame events
        socket.on("animation_total_frames") { [weak self] data, _ in
            self?.handleAnimationTotalFramesEvent(data)
        }

        socket.on("receive_base_frame") { [weak self] data, _ in
            self?.handleBaseFrameEvent(data)
        }

        socket.on("animation_frames_complete") { [weak self] data, _ in
            self?.handleAnimationFramesCompleteEvent(data)
        }

        // NEW - Animation engine events (chunk streaming)
        socket.on("animation_chunk_metadata") { [weak self] data, _ in
            self?.handleAnimationChunkMetadataEvent(data)
        }

        socket.on("receive_frame_image") { [weak self] data, _ in
            self?.handleFrameImageEvent(data)
        }

        // NEW - Base animations manifest (tells us what animations are available)
        socket.on("base_animations_manifest") { [weak self] data, _ in
            self?.handleAnimationsManifestEvent(data)
        }
    }

    // MARK: - Request Methods

    /// Request animations manifest from backend
    func requestAnimationsManifest(agentId: String) {
        guard let socket = socket, socket.status == .connected else {
            socketLog("[LIVASocketManager] Cannot request manifest - not connected")
            return
        }

        socketLog("[LIVASocketManager] 📤 Requesting animations manifest for agent: \(agentId)")
        socket.emit("request_base_animations_manifest", [
            "agentId": agentId  // Backend expects camelCase
        ])
    }

    /// Request base animation from backend
    func requestBaseAnimation(name: String, agentId: String) {
        guard let socket = socket, socket.status == .connected else {
            socketLog("[LIVASocketManager] Cannot request animation - not connected")
            return
        }

        socketLog("[LIVASocketManager] 📤 Requesting animation: \(name) for agent: \(agentId)")
        socket.emit("request_specific_base_animation", [
            "animationType": name,  // Backend expects animationType
            "agentId": agentId      // Backend expects camelCase
        ])
    }

    /// Set session ID for backend frame logging
    /// This allows backend to log frames to the same session as iOS
    func setSessionId(_ sessionId: String) {
        guard let socket = socket, socket.status == .connected else {
            socketLog("[LIVASocketManager] Cannot set session ID - not connected")
            return
        }

        socketLog("[LIVASocketManager] 📤 Setting session ID: \(sessionId)")
        socket.emit("set_session_id", ["session_id": sessionId])
    }

    // MARK: - Event Parsing

    private func handleAudioEvent(_ data: [Any]) {
        guard let dict = data.first as? [String: Any] else { return }

        guard let audioBase64 = dict["audio_data"] as? String,
              let audioData = Data(base64Encoded: audioBase64) else {
            return
        }

        let chunkIndex = dict["chunk_index"] as? Int ?? 0
        let masterChunkIndex = dict["master_chunk_index"] as? Int ?? 0
        let totalFrameImages = dict["total_frame_images"] as? Int ?? 0
        let timestamp = dict["timestamp"] as? String ?? ""

        // Parse animation frames chunk
        var animationFramesChunk: [AnimationFrameChunk] = []
        if let framesArray = dict["animationFramesChunk"] as? [[String: Any]] {
            for frameDict in framesArray {
                let animationName = frameDict["animation_name"] as? String ?? ""
                let zoneArray = frameDict["zone_top_left"] as? [Int] ?? [0, 0]
                let zoneTopLeft = CGPoint(x: zoneArray[0], y: zoneArray[1])
                let masterFramePlayAt = frameDict["master_frame_play_at"] as? Int ?? 0
                let mode = frameDict["mode"] as? String ?? "talking"

                let chunk = AnimationFrameChunk(
                    animationName: animationName,
                    zoneTopLeft: zoneTopLeft,
                    masterFramePlayAt: masterFramePlayAt,
                    mode: mode
                )
                animationFramesChunk.append(chunk)
            }
        }

        let audioChunk = AudioChunk(
            audioData: audioData,
            chunkIndex: chunkIndex,
            masterChunkIndex: masterChunkIndex,
            animationFramesChunk: animationFramesChunk,
            totalFrameImages: totalFrameImages,
            timestamp: timestamp
        )

        onAudioReceived?(audioChunk)
    }

    private func handleFrameBatchEvent(_ data: [Any]) {
        guard let dict = data.first as? [String: Any] else { return }

        let chunkIndex = dict["chunk_index"] as? Int ?? 0
        let batchIndex = dict["batch_index"] as? Int ?? 0
        let batchStartIndex = dict["batch_start_index"] as? Int ?? 0
        let batchSize = dict["batch_size"] as? Int ?? 0
        let totalBatches = dict["total_batches"] as? Int ?? 1
        let emissionTimestamp = dict["emission_timestamp"] as? Int64 ?? 0

        var frames: [FrameData] = []
        if let framesArray = dict["frames"] as? [[String: Any]] {
            for (idx, frameDict) in framesArray.enumerated() {
                // Debug: Log the frame dict keys and image_data type
                if idx == 0 {
                    socketLog("[LIVASocketManager] 🔍 Frame keys: \(Array(frameDict.keys).prefix(10))")
                    if let imageData = frameDict["image_data"] {
                        socketLog("[LIVASocketManager] 🔍 image_data type: \(type(of: imageData))")
                        if let stringData = imageData as? String {
                            socketLog("[LIVASocketManager] 🔍 image_data as String, length: \(stringData.count)")
                        } else if let dataData = imageData as? Data {
                            socketLog("[LIVASocketManager] 🔍 image_data as Data, size: \(dataData.count)")
                        } else if let dictData = imageData as? [String: Any] {
                            socketLog("[LIVASocketManager] 🔍 image_data as Dict, keys: \(Array(dictData.keys))")
                        }
                    } else {
                        socketLog("[LIVASocketManager] 🔍 image_data is nil")
                    }
                }

                // Handle image_data - can be either Data (binary) or String (base64)
                // OPTIMIZATION: Store raw Data when available to avoid base64 encode+decode
                var imageDataString = ""
                var imageDataRaw: Data? = nil
                if let binaryData = frameDict["image_data"] as? Data {
                    // Backend sends binary data - store raw (avoids base64 roundtrip!)
                    imageDataRaw = binaryData
                    imageDataString = ""  // Empty string as fallback
                } else if let stringData = frameDict["image_data"] as? String {
                    // Already base64 string
                    imageDataString = stringData
                }

                // VERBOSE LOGGING: Log overlay_id from backend
                let overlayIdFromBackend = frameDict["overlay_id"] as? String
                if frames.count < 3 {
                    socketLog("[LIVASocketManager] 🔍 FRAME_DATA seq=\(frameDict["sequence_index"] ?? -1) overlay_id='\(overlayIdFromBackend ?? "nil")' anim='\(frameDict["animation_name"] ?? "")' spriteNum=\(frameDict["matched_sprite_frame_number"] ?? -1) sheet='\(frameDict["sheet_filename"] ?? "")' raw=\(imageDataRaw != nil)")
                }

                let frame = FrameData(
                    imageData: imageDataString,
                    imageDataRaw: imageDataRaw,
                    imageMime: frameDict["image_mime"] as? String ?? "image/webp",
                    spriteIndexFolder: frameDict["sprite_index_folder"] as? Int ?? 0,
                    sheetFilename: frameDict["sheet_filename"] as? String ?? "",
                    animationName: frameDict["animation_name"] as? String ?? "",
                    sequenceIndex: frameDict["sequence_index"] as? Int ?? 0,
                    sectionIndex: frameDict["section_index"] as? Int ?? 0,
                    frameIndex: frameDict["frame_index"] as? Int ?? 0,
                    matchedSpriteFrameNumber: frameDict["matched_sprite_frame_number"] as? Int ?? 0,
                    char: frameDict["char"] as? String ?? "",
                    overlayId: overlayIdFromBackend
                )
                frames.append(frame)
            }
        }

        let batch = FrameBatch(
            frames: frames,
            chunkIndex: chunkIndex,
            batchIndex: batchIndex,
            batchStartIndex: batchStartIndex,
            batchSize: batchSize,
            totalBatches: totalBatches,
            emissionTimestamp: emissionTimestamp
        )

        socketLog("[LIVASocketManager] 📦 Parsed batch \(batchIndex) with \(frames.count) frames, calling callback...")
        if onFrameBatchReceived != nil {
            onFrameBatchReceived?(batch)
        } else {
            socketLog("[LIVASocketManager] ⚠️ onFrameBatchReceived callback is nil!")
        }
    }

    private func handleChunkReadyEvent(_ data: [Any]) {
        guard let dict = data.first as? [String: Any] else { return }

        let chunkIndex = dict["chunk_index"] as? Int ?? 0
        let totalImagesSent = dict["total_images_sent"] as? Int ?? 0

        onChunkReady?(chunkIndex, totalImagesSent)
    }

    private func handlePlayAnimationEvent(_ data: [Any]) {
        guard let dict = data.first as? [String: Any],
              let animationName = dict["animation_name"] as? String else {
            return
        }

        onPlayBaseAnimation?(animationName)
    }

    private func handleAnimationTotalFramesEvent(_ data: [Any]) {
        guard let dict = data.first as? [String: Any],
              let animationType = dict["animation_type"] as? String,
              let totalFrames = dict["total_frames"] as? Int else {
            socketLog("[LIVASocketManager] ⚠️ Invalid animation_total_frames format")
            return
        }

        socketLog("[LIVASocketManager] 📊 Animation \(animationType) has \(totalFrames) frames")
        onAnimationTotalFrames?(animationType, totalFrames)
    }

    private func handleBaseFrameEvent(_ data: [Any]) {
        guard let dict = data.first as? [String: Any],
              let animationType = dict["animation_type"] as? String,
              let frameIndex = dict["frame_index"] as? Int,
              let frameData = dict["frame_data"] as? [String: Any],
              let imageData = frameData["data"] as? String else {
            socketLog("[LIVASocketManager] ⚠️ Invalid receive_base_frame format")
            return
        }

        // Decode base64 image data
        // Remove data URL prefix if present
        var base64String = imageData
        if let range = imageData.range(of: "base64,") {
            base64String = String(imageData[range.upperBound...])
        }

        guard let data = Data(base64Encoded: base64String) else {
            socketLog("[LIVASocketManager] ⚠️ Failed to decode base64 image data")
            return
        }

        // Log first frame of each animation
        if frameIndex == 0 {
            socketLog("[LIVASocketManager] 📷 Received first frame of \(animationType)")
        }

        onBaseFrameReceived?(animationType, frameIndex, data)
    }

    private func handleAnimationFramesCompleteEvent(_ data: [Any]) {
        guard let dict = data.first as? [String: Any] else {
            socketLog("[LIVASocketManager] ⚠️ Invalid animation_frames_complete format")
            return
        }

        // Backend sends "animation_type", not "animation_name"
        guard let animationName = dict["animation_type"] as? String else {
            socketLog("[LIVASocketManager] ⚠️ Missing animation_type in animation_frames_complete")
            return
        }

        socketLog("[LIVASocketManager] ✅ Animation frames complete: \(animationName)")
        onAnimationFramesComplete?(animationName)
    }

    // NEW - Animation chunk metadata event handler
    private func handleAnimationChunkMetadataEvent(_ data: [Any]) {
        guard let dict = data.first as? [String: Any] else {
            socketLog("[LIVASocketManager] ⚠️ Invalid animation_chunk_metadata format")
            return
        }

        socketLog("[LIVASocketManager] 📦 Received animation_chunk_metadata: chunk \(dict["chunk_index"] ?? "?")")

        // Forward raw dictionary to callback - LIVAAnimationEngine will parse it
        onAnimationChunkMetadata?(dict)
    }

    // NEW - Frame image event handler
    private func handleFrameImageEvent(_ data: [Any]) {
        guard let dict = data.first as? [String: Any] else {
            socketLog("[LIVASocketManager] ⚠️ Invalid receive_frame_image format")
            return
        }

        // Forward raw dictionary to callback - LIVAAnimationEngine will parse it
        onFrameImageReceived?(dict)
    }

    // NEW - Base animations manifest event handler
    private func handleAnimationsManifestEvent(_ data: [Any]) {
        guard let dict = data.first as? [String: Any] else {
            socketLog("[LIVASocketManager] ⚠️ Invalid base_animations_manifest format")
            return
        }

        socketLog("[LIVASocketManager] 📋 Received animations manifest")

        // Extract animations dictionary (keys = animation names)
        if let animations = dict["animations"] as? [String: Any] {
            socketLog("[LIVASocketManager] 📋 Found \(animations.count) animations in manifest: \(Array(animations.keys).prefix(3))...")
            onAnimationsManifest?(animations)
        } else {
            socketLog("[LIVASocketManager] ⚠️ No animations dictionary in manifest")
        }
    }

    // MARK: - Reconnection

    private func scheduleReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            onError?(LIVAError.connectionFailed("Max reconnection attempts reached"))
            return
        }

        let delay = min(pow(2.0, Double(reconnectAttempts)), maxReconnectDelay)
        reconnectAttempts += 1

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, !self.isManualDisconnect else { return }
            self.connect()
        }
    }
}
