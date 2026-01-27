//
//  LIVAPerformanceTracker.swift
//  LIVAAnimation
//
//  Simple diagnostic tracker for iOS animation pipeline
//  Uses serial queue for thread safety (works on iOS 13+)
//

import Foundation
import QuartzCore
import os.log

/// Simple diagnostic tracker - uses serial queue for thread safety
/// Prints summary to console showing exactly what's happening
final class LIVAPerformanceTracker {

    static let shared = LIVAPerformanceTracker()

    // MARK: - Thread Safety

    private let queue = DispatchQueue(label: "com.liva.performanceTracker", qos: .utility)

    // MARK: - Counters

    private var framesReceived = 0
    private var framesCached = 0
    private var framesLookedUp = 0
    private var cacheHits = 0
    private var cacheMisses = 0
    private var framesRendered = 0
    private var framesSkipped = 0

    private var chunksEnqueued = 0
    private var chunksStarted = 0
    private var chunksCompleted = 0

    // MARK: - Key Tracking (for mismatch detection)

    private var storeKeys: [String] = []
    private var lookupKeys: [String] = []

    // MARK: - Timing

    private var sessionStart: TimeInterval = 0

    // MARK: - Logger

    private let log = OSLog(subsystem: "com.liva.animation", category: "Diagnostics")

    private init() {
        sessionStart = CACurrentMediaTime()
    }

    // MARK: - Reset (call at start of new message)

    func reset() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.framesReceived = 0
            self.framesCached = 0
            self.framesLookedUp = 0
            self.cacheHits = 0
            self.cacheMisses = 0
            self.framesRendered = 0
            self.framesSkipped = 0
            self.chunksEnqueued = 0
            self.chunksStarted = 0
            self.chunksCompleted = 0
            self.storeKeys = []
            self.lookupKeys = []
            self.sessionStart = CACurrentMediaTime()
        }
        os_log(.info, log: log, "🔄 DIAG: Reset counters")
    }

    // MARK: - Frame Tracking

    func recordFrameReceived(chunk: Int, seq: Int) {
        queue.async { [weak self] in
            self?.framesReceived += 1
        }
    }

    /// Batch version - records multiple frames at once (reduces queue dispatch overhead)
    func recordFramesReceivedBatch(chunk: Int, count: Int) {
        queue.async { [weak self] in
            self?.framesReceived += count
        }
    }

    func recordFrameCached(key: String, chunk: Int) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.framesCached += 1
            if self.storeKeys.count < 20 {
                self.storeKeys.append(key)
            }
        }
    }

    func recordFrameLookup(key: String, found: Bool, chunk: Int) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.framesLookedUp += 1
            if found {
                self.cacheHits += 1
            } else {
                self.cacheMisses += 1
            }
            if self.lookupKeys.count < 20 {
                self.lookupKeys.append(key)
            }
        }
    }

    func recordFrameRendered(chunk: Int, seq: Int) {
        queue.async { [weak self] in
            self?.framesRendered += 1
        }
    }

    func recordFrameSkipped(reason: String) {
        queue.async { [weak self] in
            self?.framesSkipped += 1
        }
    }

    // MARK: - Chunk Tracking

    func recordChunkEnqueued(chunk: Int, frames: Int) {
        queue.async { [weak self] in
            self?.chunksEnqueued += 1
        }
        os_log(.info, log: log, "📦 DIAG: Chunk %d enqueued (%d frames)", chunk, frames)
    }

    func recordChunkStarted(chunk: Int) {
        queue.async { [weak self] in
            self?.chunksStarted += 1
        }
        os_log(.info, log: log, "▶️ DIAG: Chunk %d started playing", chunk)
    }

    func recordChunkPlaybackCompleted(chunkIndex: Int) {
        queue.async { [weak self] in
            self?.chunksCompleted += 1
        }
        os_log(.info, log: log, "✅ DIAG: Chunk %d completed", chunkIndex)
    }

    // MARK: - Compatibility stubs (for existing code)

    func recordChunkReady(chunkIndex: Int) {
        os_log(.info, log: log, "📬 DIAG: Chunk %d ready", chunkIndex)
    }

    func logEvent(category: String, event: String, details: [String: Any] = [:]) {
        os_log(.info, log: log, "📝 DIAG: %{public}@.%{public}@", category, event)
    }

    // MARK: - Report

    func printReport() {
        // Synchronously get all values
        queue.sync { [weak self] in
            guard let self = self else { return }

            let duration = CACurrentMediaTime() - self.sessionStart
            let hitRate = (self.cacheHits + self.cacheMisses) > 0
                ? Double(self.cacheHits) / Double(self.cacheHits + self.cacheMisses) * 100
                : 0
            let renderRate = self.framesReceived > 0
                ? Double(self.framesRendered) / Double(self.framesReceived) * 100
                : 0

            print("""

            ╔══════════════════════════════════════════════════════════════╗
            ║               LIVA iOS Animation Diagnostics                 ║
            ╠══════════════════════════════════════════════════════════════╣
            ║ Duration: \(String(format: "%6.1f", duration))s                                            ║
            ╠══════════════════════════════════════════════════════════════╣
            ║ FRAMES                                                       ║
            ║   Received:  \(String(format: "%5d", self.framesReceived))                                           ║
            ║   Cached:    \(String(format: "%5d", self.framesCached))                                           ║
            ║   Rendered:  \(String(format: "%5d", self.framesRendered))  (\(String(format: "%5.1f", renderRate))%)                             ║
            ║   Skipped:   \(String(format: "%5d", self.framesSkipped))                                           ║
            ╠══════════════════════════════════════════════════════════════╣
            ║ CACHE                                                        ║
            ║   Hits:      \(String(format: "%5d", self.cacheHits))                                           ║
            ║   Misses:    \(String(format: "%5d", self.cacheMisses))                                           ║
            ║   Hit Rate:  \(String(format: "%5.1f", hitRate))%                                          ║
            ╠══════════════════════════════════════════════════════════════╣
            ║ CHUNKS                                                       ║
            ║   Enqueued:  \(String(format: "%5d", self.chunksEnqueued))                                           ║
            ║   Started:   \(String(format: "%5d", self.chunksStarted))                                           ║
            ║   Completed: \(String(format: "%5d", self.chunksCompleted))                                           ║
            ╚══════════════════════════════════════════════════════════════╝
            """)

            // Print key samples
            if !self.storeKeys.isEmpty {
                print("STORE KEYS (first 5):")
                for key in self.storeKeys.prefix(5) {
                    print("  - \(key)")
                }
            }

            if !self.lookupKeys.isEmpty {
                print("\nLOOKUP KEYS (first 5):")
                for key in self.lookupKeys.prefix(5) {
                    print("  - \(key)")
                }
            }

            // Key mismatch detection
            if let firstStore = self.storeKeys.first, let firstLookup = self.lookupKeys.first {
                if firstStore != firstLookup {
                    print("\n⚠️ KEY MISMATCH DETECTED!")
                    print("   Store key:  \(firstStore)")
                    print("   Lookup key: \(firstLookup)")
                }
            }

            // Warnings
            if self.framesRendered == 0 && self.framesReceived > 0 {
                print("\n❌ NO FRAMES RENDERED! Check if images are being cached and looked up correctly.")
            }

            if self.chunksCompleted < self.chunksEnqueued && self.chunksEnqueued > 0 {
                print("\n⚠️ NOT ALL CHUNKS COMPLETED: \(self.chunksCompleted)/\(self.chunksEnqueued)")
            }

            print("")
        }
    }

    /// Quick status line
    func getStatus() -> String {
        var result = ""
        queue.sync { [weak self] in
            guard let self = self else { return }
            let hitRate = (self.cacheHits + self.cacheMisses) > 0
                ? Double(self.cacheHits) / Double(self.cacheHits + self.cacheMisses) * 100
                : 0
            result = "Frames:\(self.framesRendered)/\(self.framesReceived) Cache:\(String(format: "%.0f", hitRate))% Chunks:\(self.chunksCompleted)"
        }
        return result
    }
}
