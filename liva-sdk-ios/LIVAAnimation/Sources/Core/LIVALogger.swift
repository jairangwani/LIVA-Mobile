//
//  LIVALogger.swift
//  LIVAAnimation
//
//  Created by Claude Code on 2026-01-27.
//  Copyright © 2026 LIVA. All rights reserved.
//
//  Unified logging system for LIVA SDK.
//

import os.log

/// Log categories for different subsystems
public enum LIVALogCategory: String {
    case client = "Client"
    case animation = "Animation"
    case socket = "Socket"
    case cache = "Cache"
    case audio = "Audio"
    case performance = "Performance"
}

/// Unified logging system for LIVA SDK
class LIVALogger {
    static let shared = LIVALogger()

    private let loggers: [LIVALogCategory: OSLog] = [
        .client: OSLog(subsystem: "com.liva.sdk", category: "Client"),
        .animation: OSLog(subsystem: "com.liva.sdk", category: "Animation"),
        .socket: OSLog(subsystem: "com.liva.sdk", category: "Socket"),
        .cache: OSLog(subsystem: "com.liva.sdk", category: "Cache"),
        .audio: OSLog(subsystem: "com.liva.sdk", category: "Audio"),
        .performance: OSLog(subsystem: "com.liva.sdk", category: "Performance")
    ]

    private init() {}

    func log(_ message: String, category: LIVALogCategory, type: OSLogType = .debug) {
        guard let logger = loggers[category] else { return }
        os_log("%{public}@", log: logger, type: type, message)
        
        // Also log to debug system for session tracking
        LIVADebugLog.shared.log("[\(category.rawValue)] \(message)")
    }
}

// MARK: - Convenience Functions

/// Log message to specific category
/// - Parameters:
///   - message: Message to log
///   - category: Log category (default: .client)
///   - type: Log type (default: .debug)
public func livaLog(_ message: String, category: LIVALogCategory = .client, type: OSLogType = .debug) {
    LIVALogger.shared.log(message, category: category, type: type)
}
