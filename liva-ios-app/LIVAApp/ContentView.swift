import SwiftUI

struct ContentView: View {
    @StateObject private var authVM = AuthViewModel()
    @StateObject private var agentVM = AgentViewModel()

    var body: some View {
        Group {
            if agentVM.selectedAgent != nil {
                ChatView(authVM: authVM, agentVM: agentVM)
            } else {
                AgentSelectionView(agentVM: agentVM, authVM: authVM)
            }
        }
        .onAppear {
            if !authVM.isLoggedIn {
                authVM.loginAsGuest()
            }
            if agentVM.selectedAgent == nil {
                agentVM.selectAgent(Agent(id: "1", name: "Anna"))
            }
        }
    }
}
