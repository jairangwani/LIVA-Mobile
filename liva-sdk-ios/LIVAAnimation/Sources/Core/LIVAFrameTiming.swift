//
//  LIVAFrameTiming.swift
//  LIVAAnimation
//
//  Comprehensive frame timing diagnostics to identify freeze root cause
//

import Foundation
import UIKit

/// Detailed timing breakdown for a single frame render
struct FrameTimingBreakdown {
    let frameNumber: Int
    let timestamp: Double

    // Time between frames (should be ~16.67ms for 60fps)
    let deltaFromLastFrame: Double

    // Time spent in each operation (milliseconds)
    let baseImageLookup: Double
    let overlayLookup: Double
    let overlayDecode: Double  // If decode happened this frame
    let metalRender: Double
    let totalDrawTime: Double

    // Context
    let mode: String  // "idle" or "overlay"
    let chunk: Int
    let seq: Int
    let wasSkipped: Bool

    var isSlowFrame: Bool {
        return deltaFromLastFrame > 20.0  // More than 20ms = noticeable stutter
    }

    var bottleneck: String {
        if deltaFromLastFrame < 20.0 {
            return "none"
        }

        // Find which operation took longest
        let times = [
            ("base_lookup", baseImageLookup),
            ("overlay_lookup", overlayLookup),
            ("overlay_decode", overlayDecode),
            ("metal_render", metalRender)
        ]

        let max = times.max { $0.1 < $1.1 }
        return max?.0 ?? "unknown"
    }

    func logDescription() -> String {
        let delta = String(format: "%.1f", deltaFromLastFrame)
        let base = String(format: "%.2f", baseImageLookup)
        let overlay = String(format: "%.2f", overlayLookup)
        let decode = String(format: "%.2f", overlayDecode)
        let render = String(format: "%.2f", metalRender)
        let total = String(format: "%.2f", totalDrawTime)

        return "Frame #\(frameNumber): delta=\(delta)ms total=\(total)ms [base=\(base) overlay=\(overlay) decode=\(decode) render=\(render)] mode=\(mode) chunk=\(chunk) seq=\(seq) skip=\(wasSkipped) bottleneck=\(bottleneck)"
    }
}

/// Frame timing tracker - logs EVERY frame with detailed breakdown
class LIVAFrameTimingTracker {
    static let shared = LIVAFrameTimingTracker()

    private var isEnabled: Bool = true  // Enable for debugging
    private var frameHistory: [FrameTimingBreakdown] = []
    private let maxHistory = 300  // Keep last 300 frames

    private init() {}

    func logFrame(_ timing: FrameTimingBreakdown) {
        guard isEnabled else { return }

        // Add to history
        frameHistory.append(timing)
        if frameHistory.count > maxHistory {
            frameHistory.removeFirst()
        }

        // Log EVERY frame to console (not just slow ones)
        // This gives us complete visibility
        if timing.isSlowFrame {
            print("🔴 SLOW: \(timing.logDescription())")
        } else {
            // Log normal frames less verbosely (every 10th frame)
            if timing.frameNumber % 10 == 0 {
                print("✅ OK: \(timing.logDescription())")
            }
        }

        // Log to session for user visibility
        if timing.isSlowFrame {
            LIVASessionLogger.shared.logEvent("FRAME_TIMING", details: [
                "frame": timing.frameNumber,
                "delta_ms": Int(timing.deltaFromLastFrame),
                "base_ms": timing.baseImageLookup,
                "overlay_ms": timing.overlayLookup,
                "decode_ms": timing.overlayDecode,
                "render_ms": timing.metalRender,
                "total_ms": timing.totalDrawTime,
                "bottleneck": timing.bottleneck,
                "chunk": timing.chunk,
                "seq": timing.seq,
                "mode": timing.mode
            ])
        }
    }

    func getSlowFrames() -> [FrameTimingBreakdown] {
        return frameHistory.filter { $0.isSlowFrame }
    }

    func printSummary() {
        let slowFrames = getSlowFrames()
        let total = frameHistory.count

        print("=== FRAME TIMING SUMMARY ===")
        print("Total frames: \(total)")
        print("Slow frames (>20ms): \(slowFrames.count) (\(String(format: "%.1f", Double(slowFrames.count) / Double(max(total, 1)) * 100))%)")

        if !slowFrames.isEmpty {
            print("\nBottleneck breakdown:")
            let bottlenecks = Dictionary(grouping: slowFrames, by: { $0.bottleneck })
            for (bottleneck, frames) in bottlenecks.sorted(by: { $0.value.count > $1.value.count }) {
                print("  \(bottleneck): \(frames.count) frames")
            }

            print("\nWorst 5 frames:")
            for frame in slowFrames.sorted(by: { $0.deltaFromLastFrame > $1.deltaFromLastFrame }).prefix(5) {
                print("  \(frame.logDescription())")
            }
        }
    }
}
