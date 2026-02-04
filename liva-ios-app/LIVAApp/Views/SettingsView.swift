import SwiftUI

struct SettingsView: View {
    @ObservedObject var authVM: AuthViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var serverURL: String = AppConfig.shared.serverURL
    @State private var userId: String = AppConfig.shared.userId
    @State private var instanceId: String = AppConfig.shared.instanceId
    @State private var resolution: String = AppConfig.shared.resolution

    var body: some View {
        NavigationView {
            Form {
                Section("Server") {
                    TextField("Server URL", text: $serverURL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                }

                Section("User") {
                    TextField("User ID", text: $userId)
                        .autocapitalization(.none)
                    Text("Logged in as: \(authVM.userId)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Session") {
                    TextField("Instance ID", text: $instanceId)
                        .autocapitalization(.none)
                    Picker("Resolution", selection: $resolution) {
                        Text("512").tag("512")
                        Text("1024").tag("1024")
                    }
                }

                Section {
                    Button("Save") {
                        AppConfig.shared.serverURL = serverURL
                        AppConfig.shared.userId = userId
                        AppConfig.shared.instanceId = instanceId
                        AppConfig.shared.resolution = resolution
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                }

                Section {
                    Button("Logout", role: .destructive) {
                        authVM.logout()
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
