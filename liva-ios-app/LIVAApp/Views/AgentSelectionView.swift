import SwiftUI

private struct DarkNavBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbarBackground(Color.black, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        } else {
            content
        }
    }
}

struct AgentSelectionView: View {
    @ObservedObject var agentVM: AgentViewModel
    @ObservedObject var authVM: AuthViewModel

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                if agentVM.isLoading {
                    ProgressView("Loading agents...")
                        .foregroundColor(.white)
                        .tint(.white)
                } else if let error = agentVM.errorMessage {
                    VStack(spacing: 16) {
                        Text("Failed to load agents")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(Color.white.opacity(0.5))
                        Button("Retry") { agentVM.fetchAgents() }
                            .buttonStyle(.bordered)
                            .tint(.white)
                        Button("Use Default (Anna)") {
                            agentVM.selectAgent(Agent(id: "1", name: "Anna"))
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(agentVM.agents) { agent in
                                Button(action: { agentVM.selectAgent(agent) }) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(agent.name)
                                                .font(.headline)
                                                .foregroundColor(.white)
                                            Text("Agent \(agent.id)")
                                                .font(.caption)
                                                .foregroundColor(Color.white.opacity(0.5))
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundColor(Color.white.opacity(0.3))
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 16)
                                    .background(Color.white.opacity(0.08))
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .navigationTitle("Select Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Logout") { authVM.logout() }
                        .foregroundColor(.white)
                }
            }
            .modifier(DarkNavBarModifier())
        }
        .preferredColorScheme(.dark)
        .onAppear { agentVM.fetchAgents() }
    }
}
