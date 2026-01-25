//
//  AudioSyncManager.swift
//  LIVAAnimation
//
//  Coordinates audio playback with animation timing.
//

import Foundation

/// Synchronizes audio playback with frame rendering
final class AudioSyncManager {

    // MARK: - Properties

    private weak var audioPlayer: AudioPlayer?
    private weak var animationEngine: AnimationEngine?

    /// Current playback position in frames
    private var currentFrame: Int = 0

    /// Target frames per audio chunk
    private let framesPerChunk: Int = 45

    // MARK: - Initialization

    init(audioPlayer: AudioPlayer, animationEngine: AnimationEngine) {
        self.audioPlayer = audioPlayer
        self.animationEngine = animationEngine
    }

    // MARK: - Synchronization

    /// Start synchronized playback
    func startSync() {
        currentFrame = 0
        animationEngine?.setMode(.talking)
    }

    /// Handle chunk completion
    func onChunkComplete(chunkIndex: Int) {
        // Calculate expected frame position
        let expectedFrame = (chunkIndex + 1) * framesPerChunk

        // Adjust animation timing if needed
        // TODO: Implement sync adjustment
    }

    /// Stop synchronized playback
    func stopSync() {
        animationEngine?.setMode(.idle)
        currentFrame = 0
    }

    /// Called when audio ends
    func onAudioEnd() {
        // Transition to idle after short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.animationEngine?.setMode(.idle)
        }
    }
}
