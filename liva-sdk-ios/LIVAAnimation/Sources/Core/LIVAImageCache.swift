//
//  LIVAImageCache.swift
//  LIVAAnimation
//
//  Created by Claude Code on 2026-01-26.
//  Copyright © 2026 LIVA. All rights reserved.
//

import UIKit
import QuartzCore

/// Image cache with chunk-based eviction and automatic memory management
class LIVAImageCache {

    // MARK: - Properties

    /// NSCache for automatic memory pressure handling
    private let cache = NSCache<NSString, UIImage>()

    /// Track which images belong to which chunk for batch eviction
    private var chunkImageKeys: [Int: Set<String>] = [:]

    /// Track which images are fully decoded (not just cached)
    /// This distinguishes between "in cache" and "ready to render"
    /// Web frontend uses similar pattern with img._decoded flag
    private var decodedKeys: Set<String> = []

    /// Lock for thread-safe access (minimal locking for cache operations)
    private let lock = NSLock()

    // MARK: - Background Processing (Performance Optimization)

    /// Background queue for Base64 decoding and UIImage creation
    /// This prevents blocking the main/render thread when new chunks arrive
    private let processingQueue = DispatchQueue(
        label: "com.liva.imageProcessing",
        qos: .userInitiated,
        attributes: .concurrent  // Allow parallel decoding of multiple frames
    )

    /// Track pending operations per chunk for batch completion tracking
    private var pendingOperations: [Int: Int] = [:]

    /// Callbacks when all images for a chunk are processed
    private var chunkCompletionCallbacks: [Int: () -> Void] = [:]

    // MARK: - Initialization

    init() {
        // Default cache limits (can be configured via LIVAConfiguration)
        cache.countLimit = 2000  // maxCachedImages
        cache.totalCostLimit = 200 * 1024 * 1024  // 200 MB
        cache.name = "LIVAOverlayImageCache"

        // Listen for memory warnings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Async Processing (Non-blocking)

    /// Process and cache image data asynchronously (NON-BLOCKING)
    /// This moves Base64 decoding and UIImage creation to background thread
    /// to prevent FPS drops when new chunks arrive during playback
    /// - Parameters:
    ///   - base64Data: Base64 encoded image string
    ///   - key: Cache key (format: "chunkIndex-sectionIndex-sequenceIndex")
    ///   - chunkIndex: Chunk index for batch tracking
    ///   - completion: Optional callback when image is cached (called on main queue)
    func processAndCacheAsync(
        base64Data: String,
        key: String,
        chunkIndex: Int,
        completion: ((Bool) -> Void)? = nil
    ) {
        // Increment pending count for this chunk
        lock.withLock {
            pendingOperations[chunkIndex, default: 0] += 1
        }

        // Process on background queue (non-blocking!)
        let startTime = CACurrentMediaTime()
        processingQueue.async { [weak self] in
            guard let self = self else {
                completion?(false)
                return
            }

            let decodeStart = CACurrentMediaTime()

            // Base64 decode on background thread (previously blocking main thread)
            guard let data = Data(base64Encoded: base64Data) else {
                self.decrementPendingAndNotify(chunkIndex: chunkIndex)
                completion?(false)
                return
            }

            let base64Time = CACurrentMediaTime() - decodeStart
            let imageStart = CACurrentMediaTime()

            // UIImage creation on background thread (previously blocking main thread)
            guard let rawImage = UIImage(data: data) else {
                self.decrementPendingAndNotify(chunkIndex: chunkIndex)
                completion?(false)
                return
            }

            let imageTime = CACurrentMediaTime() - imageStart
            let forceDecodeStart = CACurrentMediaTime()

            // CRITICAL FIX: Force image decompression on background thread
            // UIImage defers JPEG/PNG decompression until first draw, which was
            // causing 100-270ms freezes when chunk 0 starts. By pre-rendering
            // on background thread, we avoid blocking the render thread.
            //
            // Force decompression on background thread to prevent render thread blocking
            let image = forceImageDecompression(rawImage)

            let forceDecodeTime = CACurrentMediaTime() - forceDecodeStart
            let totalTime = CACurrentMediaTime() - startTime

            // Log slow processing (> 10ms)
            if totalTime > 0.010 {
                print("[LIVAImageCache] ⏱️ Slow async process: key=\(key) total=\(String(format: "%.1f", totalTime * 1000))ms (base64=\(String(format: "%.1f", base64Time * 1000))ms, image=\(String(format: "%.1f", imageTime * 1000))ms, forceDecode=\(String(format: "%.1f", forceDecodeTime * 1000))ms)")
            }

            // Store in cache (fast - minimal lock time)
            self.setImageInternal(image, forKey: key, chunkIndex: chunkIndex)

            // Mark as decoded (image is fully ready for rendering)
            self.lock.lock()
            self.decodedKeys.insert(key)
            self.lock.unlock()

            // NOTE: Removed forceCoreAnimationCache() - was causing main thread blocking
            // when many images decode simultaneously (batch processing)

            // Decrement pending and check if chunk is complete
            self.decrementPendingAndNotify(chunkIndex: chunkIndex)

            // Call completion on main queue
            if let completion = completion {
                DispatchQueue.main.async {
                    completion(true)
                }
            }
        }
    }

    /// Decrement pending operations and trigger callback if chunk is complete
    private func decrementPendingAndNotify(chunkIndex: Int) {
        let callback = lock.withLock { () -> (() -> Void)? in
            pendingOperations[chunkIndex, default: 1] -= 1
            let remaining = pendingOperations[chunkIndex] ?? 0
            return remaining == 0 ? chunkCompletionCallbacks.removeValue(forKey: chunkIndex) : nil
        }

        // Trigger callback on main queue if chunk is complete
        if let callback = callback {
            DispatchQueue.main.async { callback() }
        }
    }

    /// Register callback when all images for a chunk are processed
    /// - Parameters:
    ///   - chunkIndex: Chunk index to monitor
    ///   - callback: Called when all images for this chunk are cached
    func onChunkComplete(chunkIndex: Int, callback: @escaping () -> Void) {
        let isComplete = lock.withLock { () -> Bool in
            let pending = pendingOperations[chunkIndex, default: 0]
            if pending == 0 {
                return true  // Already complete
            } else {
                chunkCompletionCallbacks[chunkIndex] = callback
                return false
            }
        }

        if isComplete {
            DispatchQueue.main.async { callback() }
        }
    }

    /// Process and cache raw image data asynchronously (FAST PATH - no base64)
    /// This skips base64 decoding and goes straight to UIImage creation
    /// - Parameters:
    ///   - imageData: Raw image data (webp/png/jpg)
    ///   - key: Cache key (format: "chunkIndex-sectionIndex-sequenceIndex")
    ///   - chunkIndex: Chunk index for batch tracking
    ///   - completion: Optional callback when image is cached (called on main queue)
    func processAndCacheAsync(
        imageData: Data,
        key: String,
        chunkIndex: Int,
        completion: ((Bool) -> Void)? = nil
    ) {
        // Increment pending count for this chunk
        lock.withLock {
            pendingOperations[chunkIndex, default: 0] += 1
        }

        // Process on background queue (non-blocking!)
        let startTime = CACurrentMediaTime()
        processingQueue.async { [weak self] in
            guard let self = self else {
                completion?(false)
                return
            }

            let imageStart = CACurrentMediaTime()

            // UIImage creation on background thread (no base64 decode needed!)
            guard let rawImage = UIImage(data: imageData) else {
                self.decrementPendingAndNotify(chunkIndex: chunkIndex)
                completion?(false)
                return
            }

            let imageTime = CACurrentMediaTime() - imageStart
            let forceDecodeStart = CACurrentMediaTime()

            // CRITICAL FIX: Force image decompression on background thread
            let image = forceImageDecompression(rawImage)

            let forceDecodeTime = CACurrentMediaTime() - forceDecodeStart
            let totalTime = CACurrentMediaTime() - startTime

            // Log slow processing (> 10ms)
            if totalTime > 0.010 {
                print("[LIVAImageCache] ⏱️ Slow async process (raw): key=\(key) total=\(String(format: "%.1f", totalTime * 1000))ms (image=\(String(format: "%.1f", imageTime * 1000))ms, forceDecode=\(String(format: "%.1f", forceDecodeTime * 1000))ms)")
            }

            // Store in cache (fast - minimal lock time)
            self.setImageInternal(image, forKey: key, chunkIndex: chunkIndex)

            // Mark as decoded (image is fully ready for rendering)
            self.lock.lock()
            self.decodedKeys.insert(key)
            self.lock.unlock()

            // Decrement pending and check if chunk is complete
            self.decrementPendingAndNotify(chunkIndex: chunkIndex)

            // Call completion on main queue
            if let completion = completion {
                DispatchQueue.main.async {
                    completion(true)
                }
            }
        }
    }

    // MARK: - Public Methods (Synchronous - for compatibility)

    /// Set image in cache with chunk tracking (synchronous version)
    /// Use processAndCacheAsync() for better performance when processing incoming frames
    /// - Parameters:
    ///   - image: Image to cache
    ///   - key: Unique key (format: "chunkIndex-sectionIndex-sequenceIndex")
    ///   - chunkIndex: Chunk index for batch eviction
    func setImage(_ image: UIImage, forKey key: String, chunkIndex: Int) {
        setImageInternal(image, forKey: key, chunkIndex: chunkIndex)

        // CRITICAL: Also mark as decoded (UIImage is ready immediately)
        // This fixes the bug where receive_frame_image path didn't mark as decoded
        lock.withLock {
            decodedKeys.insert(key)
        }
    }

    /// Internal method to set image (called from both sync and async paths)
    private func setImageInternal(_ image: UIImage, forKey key: String, chunkIndex: Int) {
        lock.withLock {
            // Check if key already exists (potential overwrite issue)
            let existingImage = cache.object(forKey: key as NSString)
            if existingImage != nil {
                print("[LIVAImageCache] ⚠️ OVERWRITING existing image at key: \(key), chunk: \(chunkIndex)")
            }

            // Track which chunk this image belongs to
            if chunkImageKeys[chunkIndex] == nil {
                chunkImageKeys[chunkIndex] = Set()
            }
            chunkImageKeys[chunkIndex]?.insert(key)

            // Calculate cost (approximate memory size)
            // UIImage size = width * height * scale^2 * 4 bytes per pixel (RGBA)
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)

            cache.setObject(image, forKey: key as NSString, cost: cost)

            // DIAGNOSTICS: Record cache store
            LIVAPerformanceTracker.shared.recordFrameCached(key: key, chunk: chunkIndex)
            let totalImages = chunkImageKeys.values.reduce(0) { $0 + $1.count }

            // Log first few cached images to debug key format (increased to 20 for better debugging)
            if totalImages <= 20 {
                print("[LIVAImageCache] ✅ STORE key='\(key)', chunk=\(chunkIndex), size=\(image.size), total=\(totalImages)")
            }
        }
    }

    /// Get image from cache
    /// - Parameter key: Image key
    /// - Returns: Cached image if available
    func getImage(forKey key: String) -> UIImage? {
        let image = cache.object(forKey: key as NSString)

        // DIAGNOSTICS: Record cache lookup
        LIVAPerformanceTracker.shared.recordFrameLookup(key: key, found: image != nil, chunk: -1)

        return image
    }

    /// Check if image exists in cache
    /// - Parameter key: Image key
    /// - Returns: True if image is cached
    func hasImage(forKey key: String) -> Bool {
        return cache.object(forKey: key as NSString) != nil
    }

    /// Check if image is fully decoded and ready for rendering
    /// This is the key distinction from hasImage() - an image may be in cache
    /// but not yet fully decoded (race condition during async processing)
    /// - Parameter key: Image key
    /// - Returns: True if image is decoded and ready for rendering
    func isImageDecoded(forKey key: String) -> Bool {
        return lock.withLock {
            decodedKeys.contains(key)
        }
    }

    /// Check if frame is fully ready for rendering (SINGLE SOURCE OF TRUTH)
    /// - Parameter key: Image key
    /// - Returns: True if frame is BOTH cached AND decoded
    ///
    /// **This is the authoritative readiness check used throughout the SDK.**
    /// A frame must be both cached and decoded to be considered ready for rendering.
    func isFrameReady(forKey key: String) -> Bool {
        return lock.withLock {
            let cached = cache.object(forKey: key as NSString) != nil
            let decoded = decodedKeys.contains(key)
            return cached && decoded
        }
    }

    /// Check if first N frames are ready for rendering (for buffer readiness)
    /// - Parameters:
    ///   - keys: Array of frame keys in sequence order
    ///   - minimumCount: Minimum number of sequential ready frames required
    /// - Returns: True if at least minimumCount sequential frames from start are ready
    ///
    /// **Used to determine if animation can start playing.**
    /// Frames must be sequentially ready from the beginning (no gaps allowed).
    func areFirstFramesReady(keys: [String], minimumCount: Int) -> Bool {
        return lock.withLock {
            let checkCount = min(keys.count, minimumCount)
            var readyCount = 0

            for i in 0..<checkCount {
                let key = keys[i]
                let cached = cache.object(forKey: key as NSString) != nil
                let decoded = decodedKeys.contains(key)
                if cached && decoded {
                    readyCount += 1
                } else {
                    break  // Must be sequential - stop at first gap
                }
            }

            return readyCount >= minimumCount
        }
    }

    /// Evict all images from specified chunks
    /// - Parameter chunkIndices: Set of chunk indices to evict
    func evictChunks(_ chunkIndices: Set<Int>) {
        lock.withLock {
            var totalEvicted = 0

            for chunkIndex in chunkIndices {
                guard let imageKeys = chunkImageKeys[chunkIndex] else { continue }

                for key in imageKeys {
                    cache.removeObject(forKey: key as NSString)
                    decodedKeys.remove(key)  // Also remove from decoded tracking
                    totalEvicted += 1
                }

                chunkImageKeys.removeValue(forKey: chunkIndex)
            }

            #if DEBUG
            print("[LIVAImageCache] Evicted \(totalEvicted) images from \(chunkIndices.count) chunks")
            #endif
        }
    }

    /// Clear all cached images
    func clearAll() {
        lock.withLock {
            cache.removeAllObjects()
            chunkImageKeys.removeAll()
            decodedKeys.removeAll()  // Clear decode tracking

            #if DEBUG
            print("[LIVAImageCache] Cleared all cached images")
            #endif
        }
    }

    /// Get cache statistics
    /// - Returns: Dictionary with cache stats
    func getStats() -> [String: Any] {
        return lock.withLock {
            let totalImages = chunkImageKeys.values.reduce(0) { $0 + $1.count }
            let totalChunks = chunkImageKeys.count

            return [
                "totalImages": totalImages,
                "totalChunks": totalChunks,
                "countLimit": cache.countLimit,
                "totalCostLimit": cache.totalCostLimit
            ]
        }
    }

    /// Get total number of cached images
    var count: Int {
        return lock.withLock {
            chunkImageKeys.values.reduce(0) { $0 + $1.count }
        }
    }

    /// Get all cached keys for a chunk
    func keysForChunk(_ chunkIndex: Int) -> [String] {
        return lock.withLock {
            Array(chunkImageKeys[chunkIndex] ?? [])
        }
    }

    /// Get count of images per chunk (for diagnostics)
    func getChunkCounts() -> [Int: Int] {
        return lock.withLock {
            var counts: [Int: Int] = [:]
            for (chunk, keys) in chunkImageKeys {
                counts[chunk] = keys.count
            }
            return counts
        }
    }

    /// Get count of decoded images (for diagnostics)
    var decodedCount: Int {
        return lock.withLock {
            decodedKeys.count
        }
    }

    // MARK: - Private Methods

    @objc private func handleMemoryWarning() {
        #if DEBUG
        print("[LIVAImageCache] ⚠️ Memory warning - NSCache will automatically evict objects")
        #endif

        // NSCache handles this automatically, but we can help by clearing oldest chunks
        // if we're tracking timestamps in the future
    }
}
