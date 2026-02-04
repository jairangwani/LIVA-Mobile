import SwiftUI

struct ContentView: View {
    @StateObject private var authVM = AuthViewModel()
    @StateObject private var agentVM = AgentViewModel()

    var body: some View {
        NavigationView {
            if !authVM.isLoggedIn {
                LoginView(authVM: authVM)
            } else if agentVM.selectedAgent == nil {
                AgentSelectionView(agentVM: agentVM, authVM: authVM)
            } else {
                ChatView(
                    authVM: authVM,
                    agentVM: agentVM
                )
            }
        }
    }
}
