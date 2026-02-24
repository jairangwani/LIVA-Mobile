// @know entity AgentConfig_iOS
//
//  AgentConfig.swift
//  LIVAAnimation
//
//  Agent configuration model.
//

import Foundation

/// Agent configuration from backend
public struct AgentConfig: Codable {
    public let id: String
    public let name: String
    public let description: String?
    public let voiceId: String?
    public let status: String

    enum CodingKeys: String, CodingKey {
        case id = "agent_id"
        case name
        case description
        case voiceId = "voice_id"
        case status
    }
}
