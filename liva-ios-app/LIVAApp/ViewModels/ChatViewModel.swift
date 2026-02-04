import Foundation
import LIVAAnimation

final class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var connectionState: LIVAState = .idle
    @Published var isReady: Bool = false
    @Published var isSending: Bool = false
    @Published var errorMessage: String?

    private var isConfigured = false

    init() {
        setupCallbacks()
    }

    private func setupCallbacks() {
        LIVAClient.shared.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.connectionState = state
            }
        }

        LIVAClient.shared.onReadyStateChange = { [weak self] ready in
            DispatchQueue.main.async {
                self?.isReady = ready
            }
        }

        LIVAClient.shared.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.errorMessage = "\(error)"
            }
        }
    }

    func configure() {
        let config = AppConfig.shared
        let livaConfig = LIVAConfiguration(
            serverURL: config.serverURL,
            userId: config.userId,
            agentId: config.agentId,
            instanceId: config.instanceId,
            resolution: config.resolution
        )
        LIVAClient.shared.configure(livaConfig)
        isConfigured = true
    }

    func connect() {
        guard isConfigured else {
            configure()
            return connect()
        }

        // 5-second delay to let render loop stabilize (matches Flutter pattern)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            LIVAClient.shared.connect()
        }
    }

    func disconnect() {
        LIVAClient.shared.disconnect()
    }

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // CRITICAL: Clear stale overlays before sending
        LIVAClient.shared.forceIdleNow()

        // Add user message to UI
        let userMessage = Message(text: trimmed, isUser: true)
        messages.append(userMessage)

        // Send via HTTP POST
        isSending = true
        let config = AppConfig.shared

        guard let url = URL(string: "\(config.serverURL)/messages") else {
            isSending = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.userId, forHTTPHeaderField: "X-User-ID")

        let body: [String: Any] = [
            "AgentID": config.agentId,
            "message": trimmed,
            "instance_id": config.instanceId,
            "userResolution": config.resolution,
            "readyAnimations": LIVAClient.shared.getLoadedAnimations()
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                self?.isSending = false

                if let error = error {
                    self?.errorMessage = error.localizedDescription
                    return
                }

                if let httpResponse = response as? HTTPURLResponse,
                   !(200...299).contains(httpResponse.statusCode) {
                    self?.errorMessage = "Server error: \(httpResponse.statusCode)"
                }
            }
        }.resume()
    }
}
