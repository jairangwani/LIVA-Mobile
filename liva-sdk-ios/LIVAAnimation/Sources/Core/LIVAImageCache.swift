//
//  LIVAImageCache.swift
//  LIVAAnimation
//
//  Created by Claude Code on 2026-01-26.
//  Copyright © 2026 LIVA. All rights reserved.
//

import UIKit

/// Image cache with chunk-based eviction and automatic memory management
class LIVAImageCache {

    // MARK: - Properties

    /// NSCache for automatic memory pressure handling
    private let cache = NSCache<NSString, UIImage>()

    /// Track which images belong to which chunk for batch eviction
    private var chunkImageKeys: [Int: Set<String>] = [:]

    /// Lock for thread-safe access
    private let lock = NSLock()

    // MARK: - Constants

    /// Maximum number of images to cache
    private let maxImageCount = 500

    /// Maximum memory size (50 MB)
    private let maxMemorySize = 50 * 1024 * 1024

    // MARK: - Initialization

    init() {
        cache.countLimit = maxImageCount
        cache.totalCostLimit = maxMemorySize
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

    // MARK: - Public Methods

    /// Set image in cache with chunk tracking
    /// - Parameters:
    ///   - image: Image to cache
    ///   - key: Unique key (format: "chunkIndex_sectionIndex_sequenceIndex")
    ///   - chunkIndex: Chunk index for batch eviction
    func setImage(_ image: UIImage, forKey key: String, chunkIndex: Int) {
        lock.lock()
        defer { lock.unlock() }

        // Track which chunk this image belongs to
        if chunkImageKeys[chunkIndex] == nil {
            chunkImageKeys[chunkIndex] = Set()
        }
        chunkImageKeys[chunkIndex]?.insert(key)

        // Calculate cost (approximate memory size)
        // UIImage size = width * height * scale^2 * 4 bytes per pixel (RGBA)
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)

        cache.setObject(image, forKey: key as NSString, cost: cost)

        #if DEBUG
        print("[LIVAImageCache] Cached image: \(key), cost: \(cost) bytes, chunk: \(chunkIndex)")
        #endif
    }

    /// Get image from cache
    /// - Parameter key: Image key
    /// - Returns: Cached image if available
    func getImage(forKey key: String) -> UIImage? {
        return cache.object(forKey: key as NSString)
    }

    /// Check if image exists in cache
    /// - Parameter key: Image key
    /// - Returns: True if image is cached
    func hasImage(forKey key: String) -> Bool {
        return cache.object(forKey: key as NSString) != nil
    }

    /// Evict all images from specified chunks
    /// - Parameter chunkIndices: Set of chunk indices to evict
    func evictChunks(_ chunkIndices: Set<Int>) {
        lock.lock()
        defer { lock.unlock() }

        var totalEvicted = 0

        for chunkIndex in chunkIndices {
            guard let imageKeys = chunkImageKeys[chunkIndex] else { continue }

            for key in imageKeys {
                cache.removeObject(forKey: key as NSString)
                totalEvicted += 1
            }

            chunkImageKeys.removeValue(forKey: chunkIndex)
        }

        #if DEBUG
        print("[LIVAImageCache] Evicted \(totalEvicted) images from \(chunkIndices.count) chunks")
        #endif
    }

    /// Clear all cached images
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }

        cache.removeAllObjects()
        chunkImageKeys.removeAll()

        #if DEBUG
        print("[LIVAImageCache] Cleared all cached images")
        #endif
    }

    /// Get cache statistics
    /// - Returns: Dictionary with cache stats
    func getStats() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        let totalImages = chunkImageKeys.values.reduce(0) { $0 + $1.count }
        let totalChunks = chunkImageKeys.count

        return [
            "totalImages": totalImages,
            "totalChunks": totalChunks,
            "countLimit": cache.countLimit,
            "totalCostLimit": cache.totalCostLimit
        ]
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
