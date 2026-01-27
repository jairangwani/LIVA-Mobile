//
//  LIVASessionLogger.swift
//  LIVAAnimation
//
//  Session-based logging for LIVA animation testing.
//  Logs are sent to backend and saved to LIVA-TESTS/logs/sessions/{session_id}/
//

import Foundation

/// Session logger for LIVA animation debugging
/// Sends frame and event logs to backend for centralized storage.
public final class LIVASessionLogger {

    /// Shared singleton instance
    public static let shared = LIVASessionLogger()

    /// Current session ID (nil if no session active)
    private(set) var sessionId: String?

    /// Backend server URL
    private var serverUrl: String = ""

    /// Whether logging is enabled
    public var isEnabled: Bool = true

    /// Serial queue for thread-safe logging
    private let queue = DispatchQueue(label: "com.liva.sessionLogger", qos: .utility)

    /// URLSession for HTTP requests
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - Public Methods

    /// Configure the logger with server URL
    /// - Parameter serverUrl: Backend server URL (e.g., "http://localhost:5003")
    public func configure(serverUrl: String) {
        self.serverUrl = serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Start a new logging session
    /// - Parameters:
    ///   - userId: Optional user identifier
    ///   - agentId: Optional agent identifier
    ///   - completion: Callback with session ID or error
    public func startSession(
        userId: String = "",
        agentId: String = "",
        completion: ((String?) -> Void)? = nil
    ) {
        guard isEnabled, !serverUrl.isEmpty else {
            completion?(nil)
            return
        }

        let payload: [String: Any] = [
            "platform": "ios",
            "user_id": userId,
            "agent_id": agentId
        ]

        postJSON(endpoint: "/api/log/session/start", payload: payload) { [weak self] data in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionId = json["session_id"] as? String else {
                completion?(nil)
                return
            }

            self?.sessionId = sessionId
            livaLog("[LIVASessionLogger] Started session: \(sessionId)", category: .client)
            completion?(sessionId)
        }
    }

    /// Log a rendered frame
    /// - Parameters:
    ///   - chunk: Chunk index
    ///   - seq: Sequence index within chunk
    ///   - anim: Animation name
    ///   - baseFrame: Base frame index
    ///   - overlayKey: Overlay cache key
    ///   - syncStatus: "SYNC" or "DESYNC"
    ///   - fps: Current FPS
    public func logFrame(
        chunk: Int,
        seq: Int,
        anim: String,
        baseFrame: Int,
        overlayKey: String,
        syncStatus: String,
        fps: Double
    ) {
        guard isEnabled, let sessionId = sessionId else { return }

        let payload: [String: Any] = [
            "session_id": sessionId,
            "source": "IOS",
            "chunk": chunk,
            "seq": seq,
            "anim": anim,
            "base_frame": baseFrame,
            "overlay_key": overlayKey,
            "sync_status": syncStatus,
            "fps": fps
        ]

        // Fire and forget - don't wait for response
        postJSON(endpoint: "/api/log/frame", payload: payload, completion: nil)
    }

    /// Log an important event
    /// - Parameters:
    ///   - eventType: Event name (e.g., "CHUNK_START", "TRANSITION", "ERROR")
    ///   - details: Event details dictionary
    public func logEvent(_ eventType: String, details: [String: Any] = [:]) {
        guard isEnabled, let sessionId = sessionId else { return }

        let payload: [String: Any] = [
            "session_id": sessionId,
            "source": "IOS",
            "event_type": eventType,
            "details": details
        ]

        // Fire and forget
        postJSON(endpoint: "/api/log/event", payload: payload, completion: nil)
    }

    /// End the current logging session
    /// - Parameter completion: Callback when session is ended
    public func endSession(completion: (() -> Void)? = nil) {
        guard let sessionId = sessionId else {
            completion?()
            return
        }

        let payload: [String: Any] = [
            "session_id": sessionId
        ]

        postJSON(endpoint: "/api/log/session/end", payload: payload) { [weak self] _ in
            livaLog("[LIVASessionLogger] Ended session: \(sessionId)", category: .client)
            self?.sessionId = nil
            completion?()
        }
    }

    /// Check if a session is active
    public var isSessionActive: Bool {
        return sessionId != nil
    }

    // MARK: - Private Methods

    private func postJSON(
        endpoint: String,
        payload: [String: Any],
        completion: ((Data?) -> Void)?
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }

            guard let url = URL(string: self.serverUrl + endpoint) else {
                completion?(nil)
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            } catch {
                completion?(nil)
                return
            }

            let task = self.urlSession.dataTask(with: request) { data, response, error in
                if let error = error {
                    // Silently ignore errors - logging should not affect app functionality
                    #if DEBUG
                    livaLog("[LIVASessionLogger] HTTP error: \(error.localizedDescription)", category: .client)
                    #endif
                }
                completion?(data)
            }
            task.resume()
        }
    }
}
