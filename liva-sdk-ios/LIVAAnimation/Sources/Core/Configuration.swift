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

    /// Initialize configuration
    /// - Parameters:
    ///   - serverURL: Backend server URL
    ///   - userId: User identifier
    ///   - agentId: Agent identifier
    ///   - instanceId: Session instance ID (default: "default")
    ///   - resolution: Canvas resolution (default: "512")
    public init(
        serverURL: String,
        userId: String,
        agentId: String,
        instanceId: String = "default",
        resolution: String = "512"
    ) {
        self.serverURL = serverURL
        self.userId = userId
        self.agentId = agentId
        self.instanceId = instanceId
        self.resolution = resolution
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
