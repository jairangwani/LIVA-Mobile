//
//  BaseFrameManager.swift
//  LIVAAnimation
//
//  Manages base animation frame loading, caching, and retrieval.
//

import UIKit

/// Animation loading PRIORITY order (determines which animations load first)
/// NOTE: The actual list of animations comes from the server manifest via
/// request_base_animations_manifest socket event. This list is used for:
/// 1. Priority ordering (animations listed here load before unlisted ones)
/// 2. Fallback when manifest isn't available yet (cache loading at startup)
/// The server manifest is the SOURCE OF TRUTH for which animations exist.
let ANIMATION_LOAD_ORDER: [String] = [
    // Idle animations (highest priority - unlocks UI)
    "idle_1_s_idle_1_e",           // First priority - unlocks UI
    "idle_1_e_idle_1_s",           // Idle loop pair

    // Talking_1 animations
    "idle_1_e_talking_1_s",        // Transition: idle -> talking_1
    "talking_1_s_talking_1_e",     // Main talking_1 animation
    "talking_1_e_idle_1_s",        // Transition: talking_1 -> idle
    "talking_1_e_talking_1_s",     // Talking_1 loop

    // Talking_2 animations (backend may use these based on TALKING_VARIANTS config)
    "idle_1_e_talking_2_s",        // Transition: idle -> talking_2
    "talking_2_s_talking_2_e",     // Main talking_2 animation
    "talking_2_e_idle_1_s",        // Transition: talking_2 -> idle
    "talking_2_e_talking_2_s",     // Talking_2 loop

    // Cross-variant transitions (backend may switch between talking_1 and talking_2)
    "talking_1_e_talking_2_s",     // Transition: talking_1 -> talking_2
    "talking_2_e_talking_1_s",     // Transition: talking_2 -> talking_1

    // Hi animations (optional)
    "idle_1_e_hi_1_s",             // Transition: idle -> hi
    "hi_1_s_hi_1_e",               // Hi animation
    "hi_1_e_idle_1_s"              // Transition: hi -> idle
]

/// Base animation frame data
struct BaseAnimationFrame {
    let animationName: String
    let frameIndex: Int
    let image: UIImage
}

/// Base animation with all frames
struct BaseAnimation {
    let name: String
    var frames: [UIImage]
    var totalFrames: Int
    var isComplete: Bool

    init(name: String, totalFrames: Int) {
        self.name = name
        self.frames = Array(repeating: UIImage(), count: totalFrames)
        self.totalFrames = totalFrames
        self.isComplete = false
    }

    mutating func setFrame(_ image: UIImage, at index: Int) {
        guard index >= 0 && index < frames.count else { return }
        frames[index] = image
    }

    func getFrame(at index: Int) -> UIImage? {
        guard index >= 0 && index < frames.count else { return nil }
        let frame = frames[index]
        // Check if frame is a valid image (not placeholder)
        return frame.size.width > 0 ? frame : nil
    }

    var loadedFrameCount: Int {
        return frames.filter { $0.size.width > 0 }.count
    }

    var loadProgress: Float {
        guard totalFrames > 0 else { return 0 }
        return Float(loadedFrameCount) / Float(totalFrames)
    }
}

/// Manages base animation frames
final class BaseFrameManager {

    // MARK: - Properties

    /// All loaded base animations
    private var animations: [String: BaseAnimation] = [:]
    private let animationLock = NSLock()

    /// Current animation being played
    private(set) var currentAnimationName: String = "idle_1_s_idle_1_e"

    /// Current frame index in the animation
    private var currentFrameIndex: Int = 0

    /// Loading state
    private var loadingAnimations: Set<String> = []
    private var loadedAnimations: Set<String> = []

    /// Cache directory for persistent storage
    private let cacheDirectory: URL?

    // MARK: - Callbacks

    var onAnimationLoaded: ((String) -> Void)?
    var onLoadProgress: ((String, Float) -> Void)?
    var onFirstIdleFrameReady: (() -> Void)?

    // MARK: - Initialization

    init() {
        // Set up cache directory
        if let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            cacheDirectory = cacheDir.appendingPathComponent("LIVABaseFrames", isDirectory: true)
            createCacheDirectoryIfNeeded()
        } else {
            cacheDirectory = nil
        }
    }

    private func createCacheDirectoryIfNeeded() {
        guard let cacheDir = cacheDirectory else { return }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Animation Management

    /// Register an animation with its total frame count
    func registerAnimation(name: String, totalFrames: Int) {
        animationLock.lock()
        defer { animationLock.unlock() }

        if animations[name] == nil {
            animations[name] = BaseAnimation(name: name, totalFrames: totalFrames)
            loadingAnimations.insert(name)
        }
    }

    /// Add a frame to an animation
    func addFrame(_ image: UIImage, animationName: String, frameIndex: Int) {
        animationLock.lock()

        guard var animation = animations[animationName] else {
            animationLock.unlock()
            return
        }

        animation.setFrame(image, at: frameIndex)
        animations[animationName] = animation

        let progress = animation.loadProgress
        let isComplete = animation.loadedFrameCount == animation.totalFrames
        let isFirstIdleFrame = animationName == "idle_1_s_idle_1_e" && frameIndex == 0

        if isComplete {
            animation.isComplete = true
            animations[animationName] = animation
            loadingAnimations.remove(animationName)
            loadedAnimations.insert(animationName)
        }

        animationLock.unlock()

        // Notify progress
        onLoadProgress?(animationName, progress)

        // Check if first idle frame ready
        if isFirstIdleFrame {
            onFirstIdleFrameReady?()
        }

        // Notify completion
        if isComplete {
            onAnimationLoaded?(animationName)

            // Cache to disk
            cacheAnimationToDisk(name: animationName)
        }
    }

    /// Get the current frame for idle playback
    func getCurrentIdleFrame() -> UIImage? {
        animationLock.lock()
        defer { animationLock.unlock() }

        guard let animation = animations[currentAnimationName],
              animation.loadedFrameCount > 0 else {
            return nil
        }

        return animation.getFrame(at: currentFrameIndex)
    }

    /// Advance to next frame (for idle looping)
    func advanceFrame() -> UIImage? {
        animationLock.lock()
        defer { animationLock.unlock() }

        guard let animation = animations[currentAnimationName],
              animation.loadedFrameCount > 0 else {
            return nil
        }

        currentFrameIndex += 1
        if currentFrameIndex >= animation.totalFrames {
            currentFrameIndex = 0 // Loop
        }

        return animation.getFrame(at: currentFrameIndex)
    }

    /// Get frame at specific index
    func getFrame(animationName: String, frameIndex: Int) -> UIImage? {
        animationLock.lock()
        defer { animationLock.unlock() }

        return animations[animationName]?.getFrame(at: frameIndex)
    }

    /// Switch to a different animation
    func switchAnimation(to name: String, startFrame: Int = 0) {
        animationLock.lock()
        defer { animationLock.unlock() }

        guard animations[name] != nil else { return }
        currentAnimationName = name
        currentFrameIndex = startFrame
    }

    /// Get the base frame for a specific animation mode
    func getBaseFrame(for animationName: String, frameIndex: Int) -> UIImage? {
        animationLock.lock()
        defer { animationLock.unlock() }

        return animations[animationName]?.getFrame(at: frameIndex)
    }

    // MARK: - Loading State

    /// Check if an animation is loaded
    func isAnimationLoaded(_ name: String) -> Bool {
        animationLock.lock()
        defer { animationLock.unlock()  }
        return loadedAnimations.contains(name)
    }

    /// Check if idle animation is ready
    var isIdleReady: Bool {
        return isAnimationLoaded("idle_1_s_idle_1_e")
    }

    /// Check if we have at least one idle frame
    var hasFirstIdleFrame: Bool {
        animationLock.lock()
        defer { animationLock.unlock() }

        guard let animation = animations["idle_1_s_idle_1_e"] else { return false }
        return animation.getFrame(at: 0) != nil
    }

    /// Get all animations that need loading
    func getAnimationsToLoad() -> [String] {
        animationLock.lock()
        defer { animationLock.unlock() }

        return ANIMATION_LOAD_ORDER.filter { !loadedAnimations.contains($0) }
    }

    /// Total frame count for an animation
    func totalFrames(for animationName: String) -> Int {
        animationLock.lock()
        defer { animationLock.unlock() }
        return animations[animationName]?.totalFrames ?? 0
    }

    /// Get all frames for an animation (NEW - for LIVAAnimationEngine)
    func getFrames(for animationName: String) -> [UIImage] {
        animationLock.lock()
        defer { animationLock.unlock() }
        return animations[animationName]?.frames.filter { $0.size.width > 0 } ?? []
    }

    /// Get total frames (alias for compatibility)
    func getTotalFrames(for animationName: String) -> Int {
        return totalFrames(for: animationName)
    }

    // MARK: - Disk Cache

    private func cacheAnimationToDisk(name: String) {
        guard let cacheDir = cacheDirectory else { return }

        animationLock.lock()
        guard let animation = animations[name] else {
            animationLock.unlock()
            return
        }
        let frames = animation.frames
        animationLock.unlock()

        DispatchQueue.global(qos: .background).async {
            let animationDir = cacheDir.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: animationDir, withIntermediateDirectories: true)

            for (index, frame) in frames.enumerated() {
                guard frame.size.width > 0,
                      let data = frame.pngData() else { continue }

                let fileName = String(format: "frame_%04d.png", index)
                let fileURL = animationDir.appendingPathComponent(fileName)
                try? data.write(to: fileURL)
            }
        }
    }

    /// Load animation from disk cache
    func loadFromCache(animationName: String) -> Bool {
        guard let cacheDir = cacheDirectory else { return false }

        let animationDir = cacheDir.appendingPathComponent(animationName, isDirectory: true)

        guard FileManager.default.fileExists(atPath: animationDir.path) else {
            return false
        }

        // Get all frame files
        guard let files = try? FileManager.default.contentsOfDirectory(at: animationDir, includingPropertiesForKeys: nil) else {
            return false
        }

        let frameFiles = files.filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !frameFiles.isEmpty else { return false }

        // Register and load
        registerAnimation(name: animationName, totalFrames: frameFiles.count)

        for (index, fileURL) in frameFiles.enumerated() {
            if let data = try? Data(contentsOf: fileURL),
               let rawImage = UIImage(data: data) {
                // CRITICAL: Force image decompression at load time
                // UIImage defers JPEG/PNG decompression until first draw, which
                // causes freezes during animation. Pre-decode on startup so base
                // frames are ready to render immediately. Force decompression.
                let image = forceImageDecompression(rawImage)
                addFrame(image, animationName: animationName, frameIndex: index)
            }
        }

        return isAnimationLoaded(animationName)
    }

    /// Clear all cached frames
    func clearCache() {
        guard let cacheDir = cacheDirectory else { return }
        try? FileManager.default.removeItem(at: cacheDir)
        createCacheDirectoryIfNeeded()

        animationLock.lock()
        animations.removeAll()
        loadingAnimations.removeAll()
        loadedAnimations.removeAll()
        currentFrameIndex = 0
        animationLock.unlock()
    }

    // MARK: - Debug

    var debugDescription: String {
        animationLock.lock()
        defer { animationLock.unlock() }

        var desc = "BaseFrameManager:\n"
        desc += "  Current: \(currentAnimationName) @ frame \(currentFrameIndex)\n"
        desc += "  Loaded: \(loadedAnimations.count) animations\n"
        desc += "  Loading: \(loadingAnimations.count) animations\n"

        for (name, anim) in animations {
            desc += "  - \(name): \(anim.loadedFrameCount)/\(anim.totalFrames) frames"
            if anim.isComplete { desc += " [complete]" }
            desc += "\n"
        }

        return desc
    }
}
