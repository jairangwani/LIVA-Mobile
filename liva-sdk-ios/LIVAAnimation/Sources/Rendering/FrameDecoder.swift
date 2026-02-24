// @know entity FrameDecoder_iOS
//
//  FrameDecoder.swift
//  LIVAAnimation
//
//  High-performance base64 image decoding for animation frames.
//

import UIKit

/// Decoded frame ready for rendering
struct DecodedFrame {
    let image: UIImage
    let sequenceIndex: Int
    let sectionIndex: Int
    let frameIndex: Int
    let animationName: String
    let char: String
    let matchedSpriteFrameNumber: Int
}

/// High-performance frame decoder
final class FrameDecoder {

    // MARK: - Properties

    /// Concurrent queue for parallel decoding
    private let decodeQueue = DispatchQueue(
        label: "com.liva.animation.decoder",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Operation queue for managing concurrent operations
    private let operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.liva.animation.decoder.operations"
        queue.maxConcurrentOperationCount = 4 // Limit concurrent decodes
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Cache for recently decoded images (LRU)
    private var imageCache = NSCache<NSString, UIImage>()

    // MARK: - Initialization

    init() {
        // Configure cache
        imageCache.countLimit = 100 // Max 100 images in cache
        imageCache.totalCostLimit = 50 * 1024 * 1024 // ~50MB
    }

    // MARK: - Single Frame Decoding

    /// Decode a single frame synchronously
    func decodeSync(base64String: String) -> UIImage? {
        // Check cache first
        let cacheKey = NSString(string: String(base64String.prefix(100)))
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }

        // Remove data URL prefix if present
        var base64 = base64String
        if let range = base64String.range(of: "base64,") {
            base64 = String(base64String[range.upperBound...])
        }

        // Decode base64 to data
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            return nil
        }

        // Decode image
        guard let image = UIImage(data: data) else {
            return nil
        }

        // Cache the result
        imageCache.setObject(image, forKey: cacheKey)

        return image
    }

    /// Decode a single frame asynchronously
    func decode(base64String: String, completion: @escaping (UIImage?) -> Void) {
        decodeQueue.async { [weak self] in
            let image = self?.decodeSync(base64String: base64String)
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    // MARK: - Batch Decoding

    /// Decode a batch of frames from socket data
    func decodeBatch(
        _ batch: LIVASocketManager.FrameBatch,
        completion: @escaping ([DecodedFrame]) -> Void
    ) {
        decodeQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            var decodedFrames: [DecodedFrame] = []
            let lock = NSLock()

            // Use autoreleasepool to manage memory during batch decode
            autoreleasepool {
                // Decode frames in parallel using DispatchGroup
                let group = DispatchGroup()

                for frameData in batch.frames {
                    group.enter()

                    self.decodeQueue.async {
                        defer { group.leave() }

                        guard let image = self.decodeSync(base64String: frameData.imageData) else {
                            return
                        }

                        let decoded = DecodedFrame(
                            image: image,
                            sequenceIndex: frameData.sequenceIndex,
                            sectionIndex: frameData.sectionIndex,
                            frameIndex: frameData.frameIndex,
                            animationName: frameData.animationName,
                            char: frameData.char,
                            matchedSpriteFrameNumber: frameData.matchedSpriteFrameNumber
                        )

                        lock.lock()
                        decodedFrames.append(decoded)
                        lock.unlock()
                    }
                }

                group.wait()
            }

            // Sort by sequence index to ensure correct order
            decodedFrames.sort { $0.sequenceIndex < $1.sequenceIndex }

            DispatchQueue.main.async {
                completion(decodedFrames)
            }
        }
    }

    /// Decode multiple batches efficiently
    func decodeBatches(
        _ batches: [LIVASocketManager.FrameBatch],
        progress: ((Int, Int) -> Void)? = nil,
        completion: @escaping ([DecodedFrame]) -> Void
    ) {
        decodeQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            var allFrames: [DecodedFrame] = []
            let lock = NSLock()
            let totalBatches = batches.count
            var completedBatches = 0

            let group = DispatchGroup()

            for batch in batches {
                group.enter()

                self.decodeBatch(batch) { frames in
                    lock.lock()
                    allFrames.append(contentsOf: frames)
                    completedBatches += 1
                    lock.unlock()

                    DispatchQueue.main.async {
                        progress?(completedBatches, totalBatches)
                    }

                    group.leave()
                }
            }

            group.notify(queue: .main) {
                // Sort all frames by sequence index
                let sortedFrames = allFrames.sorted { $0.sequenceIndex < $1.sequenceIndex }
                completion(sortedFrames)
            }
        }
    }

    // MARK: - Cache Management

    /// Clear the image cache
    func clearCache() {
        imageCache.removeAllObjects()
    }

    /// Get current cache count
    var cacheCount: Int {
        // NSCache doesn't expose count, so we track externally if needed
        return 0
    }

    // MARK: - Memory Management

    /// Called when receiving memory warning
    func handleMemoryWarning() {
        clearCache()
    }
}

// MARK: - Image Optimization Extension

