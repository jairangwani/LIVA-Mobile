//
//  Configuration.swift
//  LIVAAnimation
//
//  SDK configuration types.
//

import Foundation

/// Configuration for LIVA Animation SDK
public struct LIVAConfiguration {

    /// Backend server URL
    public let serverURL: String

    /// User identifier
    public let userId: String

    /// Agent identifier
    public let agentId: String

    /// Session instance identifier
    public var instanceId: String

    /// Canvas resolution (e.g., "512", "1024")
    public var resolution: String

    // MARK: - Performance Tuning

    /// Minimum frames required in buffer before starting playback (default: 30)
    public var minFramesBeforeStart: Int = 30

    /// Maximum number of images to cache (default: 2000)
    public var maxCachedImages: Int = 2000

    /// Maximum cache memory in MB (default: 200 MB)
    public var maxCacheMemoryMB: Int = 200

    /// Enable verbose logging (default: false)
    public var verboseLogging: Bool = false

    /// Initialize configuration
    /// - Parameters:
    ///   - serverURL: Backend server URL
    ///   - userId: User identifier
    ///   - agentId: Agent identifier
    ///   - instanceId: Session instance ID (default: "default")
    ///   - resolution: Canvas resolution (default: "512")
    ///   - minFramesBeforeStart: Minimum frames before playback (default: 30)
    ///   - maxCachedImages: Max cached images (default: 2000)
    ///   - maxCacheMemoryMB: Max cache memory MB (default: 200)
    ///   - verboseLogging: Enable verbose logging (default: false)
    public init(
        serverURL: String,
        userId: String,
        agentId: String,
        instanceId: String = "default",
        resolution: String = "512",
        minFramesBeforeStart: Int = 30,
        maxCachedImages: Int = 2000,
        maxCacheMemoryMB: Int = 200,
        verboseLogging: Bool = false
    ) {
        self.serverURL = serverURL
        self.userId = userId
        self.agentId = agentId
        self.instanceId = instanceId
        self.resolution = resolution
        self.minFramesBeforeStart = minFramesBeforeStart
        self.maxCachedImages = maxCachedImages
        self.maxCacheMemoryMB = maxCacheMemoryMB
        self.verboseLogging = verboseLogging
    }
}

/// SDK connection state
public enum LIVAState: Equatable {
    case idle
    case connecting
    case connected
    case animating
    case error(LIVAError)
}

/// SDK errors
public enum LIVAError: Error, Equatable {
    case notConfigured
    case connectionFailed(String)
    case socketDisconnected
    case frameDecodingFailed
    case audioPlaybackFailed
    case unknown(String)
}
