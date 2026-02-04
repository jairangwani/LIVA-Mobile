import SwiftUI

struct AgentSelectionView: View {
    @ObservedObject var agentVM: AgentViewModel
    @ObservedObject var authVM: AuthViewModel

    var body: some View {
        VStack {
            if agentVM.isLoading {
                ProgressView("Loading agents...")
            } else if let error = agentVM.errorMessage {
                VStack(spacing: 16) {
                    Text("Failed to load agents")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Retry") { agentVM.fetchAgents() }
                        .buttonStyle(.bordered)
                    Button("Use Default (Anna)") {
                        agentVM.selectAgent(Agent(id: "1", name: "Anna"))
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List(agentVM.agents) { agent in
                    Button(action: { agentVM.selectAgent(agent) }) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(agent.name)
                                    .font(.headline)
                                Text("Agent \(agent.id)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.primary)
                }
            }
        }
        .navigationTitle("Select Agent")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Logout") { authVM.logout() }
            }
        }
        .onAppear { agentVM.fetchAgents() }
    }
}
