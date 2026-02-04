import Foundation

struct Agent: Identifiable, Decodable {
    let id: String
    let name: String
    let voiceId: String?

    enum CodingKeys: String, CodingKey {
        case id = "agent_id"
        case name
        case voiceId = "voice_id"
    }

    init(id: String, name: String, voiceId: String? = nil) {
        self.id = id
        self.name = name
        self.voiceId = voiceId
    }
}

final class AgentViewModel: ObservableObject {
    @Published var agents: [Agent] = []
    @Published var selectedAgent: Agent?
    @Published var isLoading = false
    @Published var errorMessage: String?

    func fetchAgents() {
        guard let url = URL(string: "\(AppConfig.shared.serverURL)/api/agents/list") else { return }
        isLoading = true
        errorMessage = nil

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false

                if let error = error {
                    self?.errorMessage = error.localizedDescription
                    return
                }

                guard let data = data else {
                    self?.errorMessage = "No data received"
                    return
                }

                // Backend returns {"agents": [...]} or just [...]
                if let wrapper = try? JSONDecoder().decode(AgentListResponse.self, from: data) {
                    self?.agents = wrapper.agents
                } else if let list = try? JSONDecoder().decode([Agent].self, from: data) {
                    self?.agents = list
                } else {
                    // Fallback: use default agent
                    self?.agents = [Agent(id: "1", name: "Anna")]
                }

                // Auto-select if only one agent
                if self?.agents.count == 1 {
                    self?.selectedAgent = self?.agents.first
                    if let agent = self?.selectedAgent {
                        AppConfig.shared.agentId = agent.id
                    }
                }
            }
        }.resume()
    }

    func selectAgent(_ agent: Agent) {
        selectedAgent = agent
        AppConfig.shared.agentId = agent.id
    }
}

private struct AgentListResponse: Decodable {
    let agents: [Agent]
}
