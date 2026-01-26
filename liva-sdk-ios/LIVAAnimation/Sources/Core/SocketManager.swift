//
//  SocketManager.swift
//  LIVAAnimation
//
//  Socket.IO connection management for LIVA backend.
//

import Foundation
import SocketIO

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
        let imageData: String
        let imageMime: String
        let spriteIndexFolder: Int
        let sheetFilename: String
        let animationName: String
        let sequenceIndex: Int
        let sectionIndex: Int
        let frameIndex: Int
        let matchedSpriteFrameNumber: Int
        let char: String
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

        print("[LIVASocketManager] Connecting to: \(url.absoluteString)")
        print("[LIVASocketManager] Connection params: \(connectionParams)")

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
            print("[LIVASocketManager] ✅ Connected successfully!")
            self?.reconnectAttempts = 0
            self?.onConnect?()
        }

        socket.on(clientEvent: .disconnect) { [weak self] data, _ in
            guard let self = self else { return }
            let reason = (data.first as? String) ?? "unknown"
            print("[LIVASocketManager] ❌ Disconnected. Reason: \(reason)")
            self.onDisconnect?(reason)

            if !self.isManualDisconnect {
                self.scheduleReconnect()
            }
        }

        socket.on(clientEvent: .error) { [weak self] data, _ in
            let errorMessage = (data.first as? String) ?? "Unknown socket error"
            print("[LIVASocketManager] ❌ Socket error: \(errorMessage)")
            print("[LIVASocketManager] Error data: \(data)")
            self?.onError?(LIVAError.connectionFailed(errorMessage))
        }

        socket.on(clientEvent: .statusChange) { [weak self] data, _ in
            print("[LIVASocketManager] Status change: \(data)")
        }

        socket.on(clientEvent: .reconnect) { [weak self] data, _ in
            print("[LIVASocketManager] Reconnecting...")
        }

        socket.on(clientEvent: .reconnectAttempt) { [weak self] data, _ in
            print("[LIVASocketManager] Reconnect attempt...")
        }

        // Audio event
        socket.on("receive_audio") { [weak self] data, _ in
            self?.handleAudioEvent(data)
        }

        // Frame batch event
        socket.on("receive_frame_images_batch") { [weak self] data, _ in
            self?.handleFrameBatchEvent(data)
        }

        // Chunk ready event
        socket.on("chunk_images_ready") { [weak self] data, _ in
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
            for frameDict in framesArray {
                let frame = FrameData(
                    imageData: frameDict["image_data"] as? String ?? "",
                    imageMime: frameDict["image_mime"] as? String ?? "image/webp",
                    spriteIndexFolder: frameDict["sprite_index_folder"] as? Int ?? 0,
                    sheetFilename: frameDict["sheet_filename"] as? String ?? "",
                    animationName: frameDict["animation_name"] as? String ?? "",
                    sequenceIndex: frameDict["sequence_index"] as? Int ?? 0,
                    sectionIndex: frameDict["section_index"] as? Int ?? 0,
                    frameIndex: frameDict["frame_index"] as? Int ?? 0,
                    matchedSpriteFrameNumber: frameDict["matched_sprite_frame_number"] as? Int ?? 0,
                    char: frameDict["char"] as? String ?? ""
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

        onFrameBatchReceived?(batch)
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
              let animationName = dict["animation_name"] as? String,
              let totalFrames = dict["total_frames"] as? Int else {
            return
        }

        onAnimationTotalFrames?(animationName, totalFrames)
    }

    private func handleBaseFrameEvent(_ data: [Any]) {
        guard let dict = data.first as? [String: Any],
              let animationName = dict["animation_name"] as? String,
              let frameIndex = dict["frame_index"] as? Int,
              let imageData = dict["image_data"] as? String else {
            return
        }

        // Decode base64 image data
        // Remove data URL prefix if present
        var base64String = imageData
        if let range = imageData.range(of: "base64,") {
            base64String = String(imageData[range.upperBound...])
        }

        guard let data = Data(base64Encoded: base64String) else {
            return
        }

        onBaseFrameReceived?(animationName, frameIndex, data)
    }

    private func handleAnimationFramesCompleteEvent(_ data: [Any]) {
        guard let dict = data.first as? [String: Any],
              let animationName = dict["animation_name"] as? String else {
            return
        }

        onAnimationFramesComplete?(animationName)
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
