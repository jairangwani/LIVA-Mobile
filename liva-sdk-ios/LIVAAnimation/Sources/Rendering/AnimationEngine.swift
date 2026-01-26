//
//  AnimationEngine.swift
//  LIVAAnimation
//
//  Frame timing, queue management, and playback synchronization.
//

import UIKit

/// Animation playback mode
enum LegacyAnimationMode {
    case idle       // 10 fps for idle animations
    case talking    // 30 fps for lip sync
    case transition // Transition between animations

    var frameRate: Double {
        switch self {
        case .idle: return 10.0
        case .talking: return 30.0
        case .transition: return 30.0
        }
    }

    var frameInterval: TimeInterval {
        return 1.0 / frameRate
    }
}

/// Frame ready for rendering
struct RenderFrame {
    let baseImage: UIImage?
    let overlayImage: UIImage?
    let overlayPosition: CGPoint
    let timestamp: CFTimeInterval
}

/// Animation chunk for queued playback
struct AnimationChunk {
    let chunkIndex: Int
    let frames: [DecodedFrame]
    let overlayPosition: CGPoint
    let animationName: String
    var isReady: Bool
}

/// Manages animation frame timing and queue
final class AnimationEngine {

    // MARK: - Properties

    /// Current animation mode
    private(set) var mode: LegacyAnimationMode = .idle {
        didSet {
            if oldValue != mode {
                onModeChange?(mode)
            }
        }
    }

    /// Current animation name
    private(set) var currentAnimationName: String = ""

    /// Frame queue for current chunk
    private var frameQueue: [DecodedFrame] = []
    private let queueLock = NSLock()

    /// Chunk queue for buffering
    private var chunkQueue: [AnimationChunk] = []
    private let chunkLock = NSLock()

    /// Current playback state
    private var currentFrameIndex = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var isPlaying = false

    /// Base frame (full avatar when not animating mouth)
    private var baseFrame: UIImage?

    /// Base frame manager for idle/transition animations
    private weak var baseFrameManager: BaseFrameManager?

    /// Current overlay position
    private var overlayPosition: CGPoint = .zero

    /// Idle animation timer for 10fps playback
    private var idleFrameTimer: CFTimeInterval = 0

    /// Buffer threshold before starting playback
    private let bufferThreshold = 10

    // MARK: - Callbacks

    var onModeChange: ((LegacyAnimationMode) -> Void)?
    var onChunkComplete: ((Int) -> Void)?
    var onAnimationComplete: (() -> Void)?

    // MARK: - Configuration

    /// Minimum frames to buffer before playback
    var minimumBufferFrames: Int = 10

    /// Whether to loop idle animations
    var loopIdleAnimations: Bool = true

    // MARK: - Frame Queue Management

    /// Enqueue decoded frames for playback
    func enqueueFrames(_ frames: [DecodedFrame], forChunk chunkIndex: Int) {
        queueLock.lock()
        defer { queueLock.unlock() }

        frameQueue.append(contentsOf: frames)

        // Sort by sequence index
        frameQueue.sort { $0.sequenceIndex < $1.sequenceIndex }

        // Start playback if we have enough buffered
        if frameQueue.count >= bufferThreshold && !isPlaying {
            isPlaying = true
            mode = .talking
        }
    }

    /// Add a chunk to the queue
    func enqueueChunk(_ chunk: AnimationChunk) {
        chunkLock.lock()
        defer { chunkLock.unlock() }

        chunkQueue.append(chunk)
        chunkQueue.sort { $0.chunkIndex < $1.chunkIndex }
    }

    /// Mark a chunk as ready
    func markChunkReady(chunkIndex: Int) {
        chunkLock.lock()
        defer { chunkLock.unlock() }

        if let index = chunkQueue.firstIndex(where: { $0.chunkIndex == chunkIndex }) {
            chunkQueue[index].isReady = true
        }
    }

    /// Set the overlay position for lip sync
    func setOverlayPosition(_ position: CGPoint) {
        overlayPosition = position
    }

    /// Set the base frame
    func setBaseFrame(_ frame: UIImage?) {
        baseFrame = frame
    }

    /// Set base frame manager for idle animations
    func setBaseFrameManager(_ manager: BaseFrameManager?) {
        baseFrameManager = manager
    }

    /// Set animation mode
    func setMode(_ newMode: LegacyAnimationMode) {
        mode = newMode
    }

    /// Clear all queued frames
    func clearQueue() {
        queueLock.lock()
        frameQueue.removeAll()
        currentFrameIndex = 0
        queueLock.unlock()

        chunkLock.lock()
        chunkQueue.removeAll()
        chunkLock.unlock()

        isPlaying = false
    }

    /// Transition to idle
    func transitionToIdle() {
        mode = .idle
        // Keep current frames if any for smooth transition
    }

    // MARK: - Frame Retrieval

    /// Get the next frame for rendering (called by display link at 60fps)
    func getNextFrame() -> RenderFrame? {
        let currentTime = CACurrentMediaTime()

        // Check if enough time has passed for next frame based on mode
        let elapsed = currentTime - lastFrameTime
        guard elapsed >= mode.frameInterval else {
            // Return current frame without advancing
            return getCurrentRenderFrame(timestamp: currentTime)
        }

        lastFrameTime = currentTime

        // Handle idle mode with base frame manager
        if mode == .idle {
            return getIdleFrame(timestamp: currentTime)
        }

        queueLock.lock()
        defer { queueLock.unlock() }

        // Get current base frame from manager
        var currentBaseFrame = baseFrame
        if let manager = baseFrameManager {
            currentBaseFrame = manager.getCurrentIdleFrame()
        }

        // Get current overlay frame
        var overlayImage: UIImage? = nil

        if !frameQueue.isEmpty {
            if currentFrameIndex < frameQueue.count {
                overlayImage = frameQueue[currentFrameIndex].image
                currentFrameIndex += 1
            }

            // Handle end of queue
            if currentFrameIndex >= frameQueue.count {
                if mode == .talking {
                    // Talking done, check for more chunks or transition to idle
                    if hasMoreChunks() {
                        loadNextChunk()
                    } else {
                        // Stay on last frame briefly, then transition
                        currentFrameIndex = frameQueue.count - 1
                        overlayImage = frameQueue[currentFrameIndex].image
                    }
                }
            }
        }

        return RenderFrame(
            baseImage: currentBaseFrame,
            overlayImage: overlayImage,
            overlayPosition: overlayPosition,
            timestamp: currentTime
        )
    }

    /// Get frame for idle animation from base frame manager
    private func getIdleFrame(timestamp: CFTimeInterval) -> RenderFrame? {
        guard let manager = baseFrameManager else {
            // Fallback to static base frame
            return RenderFrame(
                baseImage: baseFrame,
                overlayImage: nil,
                overlayPosition: .zero,
                timestamp: timestamp
            )
        }

        // Advance and get next idle frame (10fps handled by mode.frameInterval)
        let idleFrame = manager.advanceFrame()

        return RenderFrame(
            baseImage: idleFrame ?? baseFrame,
            overlayImage: nil,
            overlayPosition: .zero,
            timestamp: timestamp
        )
    }

    /// Get current frame without advancing
    private func getCurrentRenderFrame(timestamp: CFTimeInterval) -> RenderFrame? {
        queueLock.lock()
        defer { queueLock.unlock() }

        var overlayImage: UIImage? = nil

        if !frameQueue.isEmpty && currentFrameIndex < frameQueue.count {
            overlayImage = frameQueue[currentFrameIndex].image
        } else if !frameQueue.isEmpty && currentFrameIndex > 0 {
            // Return last frame if we've gone past
            overlayImage = frameQueue[frameQueue.count - 1].image
        }

        return RenderFrame(
            baseImage: baseFrame,
            overlayImage: overlayImage,
            overlayPosition: overlayPosition,
            timestamp: timestamp
        )
    }

    // MARK: - Chunk Management

    private func hasMoreChunks() -> Bool {
        chunkLock.lock()
        defer { chunkLock.unlock() }
        return !chunkQueue.isEmpty && chunkQueue.first?.isReady == true
    }

    private func loadNextChunk() {
        chunkLock.lock()
        guard !chunkQueue.isEmpty, let chunk = chunkQueue.first, chunk.isReady else {
            chunkLock.unlock()
            return
        }

        let nextChunk = chunkQueue.removeFirst()
        chunkLock.unlock()

        queueLock.lock()
        // Keep some overlap for smooth transition
        let overlapFrames = min(5, frameQueue.count)
        if overlapFrames > 0 {
            frameQueue = Array(frameQueue.suffix(overlapFrames))
            currentFrameIndex = 0
        } else {
            frameQueue.removeAll()
            currentFrameIndex = 0
        }

        frameQueue.append(contentsOf: nextChunk.frames)
        overlayPosition = nextChunk.overlayPosition
        currentAnimationName = nextChunk.animationName
        queueLock.unlock()

        onChunkComplete?(nextChunk.chunkIndex)
    }

    // MARK: - Buffer Status

    /// Check if we have enough frames buffered to start playback
    var hasBufferedFrames: Bool {
        queueLock.lock()
        defer { queueLock.unlock() }
        return frameQueue.count >= minimumBufferFrames
    }

    /// Number of frames in queue
    var queuedFrameCount: Int {
        queueLock.lock()
        defer { queueLock.unlock() }
        return frameQueue.count
    }

    /// Number of chunks waiting
    var pendingChunkCount: Int {
        chunkLock.lock()
        defer { chunkLock.unlock() }
        return chunkQueue.count
    }

    /// Current playback progress (0.0 to 1.0)
    var playbackProgress: Float {
        queueLock.lock()
        defer { queueLock.unlock() }
        guard !frameQueue.isEmpty else { return 0 }
        return Float(currentFrameIndex) / Float(frameQueue.count)
    }

    // MARK: - Playback Control

    /// Start playback
    func play() {
        isPlaying = true
    }

    /// Pause playback
    func pause() {
        isPlaying = false
    }

    /// Reset to beginning
    func reset() {
        queueLock.lock()
        currentFrameIndex = 0
        queueLock.unlock()
        lastFrameTime = 0
    }

    /// Whether currently playing
    var isCurrentlyPlaying: Bool {
        return isPlaying
    }
}

// MARK: - Debug Helpers

extension AnimationEngine {
    /// Debug description of current state
    var debugDescription: String {
        return """
        AnimationEngine:
          Mode: \(mode)
          Playing: \(isPlaying)
          Frame: \(currentFrameIndex)/\(queuedFrameCount)
          Chunks pending: \(pendingChunkCount)
          Animation: \(currentAnimationName)
        """
    }
}
