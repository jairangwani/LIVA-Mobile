//
//  AudioPlayer.swift
//  LIVAAnimation
//
//  Audio playback for avatar speech with streaming support.
//

import AVFoundation

/// Audio chunk for queued playback
struct QueuedAudioChunk {
    let data: Data
    let chunkIndex: Int
    var isPlaying: Bool = false
    var isComplete: Bool = false
}

/// Audio player for streaming MP3 playback
final class AudioPlayer: NSObject {

    // MARK: - Properties

    /// Audio engine for playback
    private var audioEngine: AVAudioEngine?

    /// Player node for scheduled playback
    private var playerNode: AVAudioPlayerNode?

    /// Audio queue
    private var audioQueue: [QueuedAudioChunk] = []
    private let queueLock = NSLock()

    /// Current playback state
    private var isPlaying = false
    private var currentChunkIndex = -1

    /// Audio format (MP3 decoded to PCM)
    private var audioFormat: AVAudioFormat?

    /// Converter for MP3 to PCM
    private var audioConverter: AVAudioConverter?

    // MARK: - Callbacks

    /// Called when a chunk starts playing
    var onChunkStart: ((Int) -> Void)?

    /// Called when a chunk finishes playing
    var onChunkComplete: ((Int) -> Void)?

    /// Called when all audio is complete
    var onPlaybackComplete: (() -> Void)?

    /// Called on error
    var onError: ((Error) -> Void)?

    // MARK: - Initialization

    override init() {
        super.init()
        setupAudioSession()
        setupAudioEngine()
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            onError?(LIVAError.audioPlaybackFailed)
        }
    }

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let engine = audioEngine, let player = playerNode else { return }

        engine.attach(player)

        // Use standard format for decoded audio
        let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 1,
            interleaved: false
        )

        // Connect player to mixer
        if let format = audioFormat {
            engine.connect(player, to: engine.mainMixerNode, format: format)
        } else {
            engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        }

        do {
            try engine.start()
        } catch {
            onError?(LIVAError.audioPlaybackFailed)
        }
    }

    // MARK: - Playback

    /// Queue an audio chunk for playback
    func queueAudio(_ data: Data, chunkIndex: Int) {
        let chunk = QueuedAudioChunk(data: data, chunkIndex: chunkIndex)

        queueLock.lock()
        audioQueue.append(chunk)
        audioQueue.sort { $0.chunkIndex < $1.chunkIndex }
        queueLock.unlock()

        // Start playback if not already playing
        if !isPlaying {
            playNextChunk()
        }
    }

    /// Play the next chunk in queue
    private func playNextChunk() {
        queueLock.lock()

        // Find next chunk to play
        guard let nextIndex = audioQueue.firstIndex(where: { !$0.isComplete && !$0.isPlaying }) else {
            queueLock.unlock()
            isPlaying = false
            DispatchQueue.main.async { [weak self] in
                self?.onPlaybackComplete?()
            }
            return
        }

        audioQueue[nextIndex].isPlaying = true
        let chunk = audioQueue[nextIndex]
        queueLock.unlock()

        currentChunkIndex = chunk.chunkIndex
        isPlaying = true

        DispatchQueue.main.async { [weak self] in
            self?.onChunkStart?(chunk.chunkIndex)
        }

        // Decode and play
        decodeAndPlay(chunk: chunk)
    }

    /// Decode MP3 data and schedule for playback
    private func decodeAndPlay(chunk: QueuedAudioChunk) {
        // Create audio file from data for decoding
        guard let tempURL = createTempFile(with: chunk.data) else {
            markChunkComplete(chunk.chunkIndex)
            playNextChunk()
            return
        }

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        do {
            let audioFile = try AVAudioFile(forReading: tempURL)
            let frameCount = AVAudioFrameCount(audioFile.length)

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: frameCount
            ) else {
                markChunkComplete(chunk.chunkIndex)
                playNextChunk()
                return
            }

            try audioFile.read(into: buffer)

            // Convert to output format if needed
            let playBuffer: AVAudioPCMBuffer
            if audioFile.processingFormat != playerNode?.outputFormat(forBus: 0) {
                if let converted = convertBuffer(buffer, to: playerNode?.outputFormat(forBus: 0)) {
                    playBuffer = converted
                } else {
                    playBuffer = buffer
                }
            } else {
                playBuffer = buffer
            }

            // Schedule buffer
            playerNode?.scheduleBuffer(playBuffer) { [weak self] in
                self?.markChunkComplete(chunk.chunkIndex)
                DispatchQueue.main.async {
                    self?.onChunkComplete?(chunk.chunkIndex)
                    self?.playNextChunk()
                }
            }

            // Start playing if not already
            if playerNode?.isPlaying == false {
                playerNode?.play()
            }

        } catch {
            markChunkComplete(chunk.chunkIndex)
            playNextChunk()
        }
    }

    /// Convert audio buffer to different format
    private func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat?) -> AVAudioPCMBuffer? {
        guard let format = format,
              let converter = AVAudioConverter(from: buffer.format, to: format) else {
            return nil
        }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        return error == nil ? outputBuffer : nil
    }

    /// Create temporary file for audio decoding
    private func createTempFile(with data: Data) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString + ".mp3")

        do {
            try data.write(to: tempFile)
            return tempFile
        } catch {
            return nil
        }
    }

    /// Mark a chunk as complete
    private func markChunkComplete(_ chunkIndex: Int) {
        queueLock.lock()
        if let index = audioQueue.firstIndex(where: { $0.chunkIndex == chunkIndex }) {
            audioQueue[index].isComplete = true
            audioQueue[index].isPlaying = false
        }
        queueLock.unlock()
    }

    // MARK: - Control

    /// Stop all playback
    func stop() {
        playerNode?.stop()
        isPlaying = false

        queueLock.lock()
        audioQueue.removeAll()
        queueLock.unlock()

        currentChunkIndex = -1
    }

    /// Pause playback
    func pause() {
        playerNode?.pause()
        isPlaying = false
    }

    /// Resume playback
    func resume() {
        playerNode?.play()
        isPlaying = true
    }

    /// Clear queue but keep current playing
    func clearQueue() {
        queueLock.lock()
        audioQueue = audioQueue.filter { $0.isPlaying }
        queueLock.unlock()
    }

    // MARK: - State

    /// Whether currently playing
    var isCurrentlyPlaying: Bool {
        return isPlaying && (playerNode?.isPlaying == true)
    }

    /// Current chunk being played
    var currentPlayingChunk: Int {
        return currentChunkIndex
    }

    /// Number of chunks in queue
    var queuedChunkCount: Int {
        queueLock.lock()
        defer { queueLock.unlock() }
        return audioQueue.filter { !$0.isComplete }.count
    }

    // MARK: - Cleanup

    deinit {
        stop()
        audioEngine?.stop()
    }
}
