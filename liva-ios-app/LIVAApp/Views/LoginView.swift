import SwiftUI

struct LoginView: View {
    @ObservedObject var authVM: AuthViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("LIVA")
                .font(.system(size: 48, weight: .bold))

            Text("AI Avatar Chat")
                .font(.title3)
                .foregroundColor(.secondary)

            Spacer()

            VStack(spacing: 16) {
                TextField("Email", text: $authVM.email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)

                SecureField("Password", text: $authVM.password)
                    .textFieldStyle(.roundedBorder)

                Button(action: { authVM.login() }) {
                    Text("Log In")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(authVM.email.isEmpty)
            }

            Divider()

            Button(action: { authVM.loginAsGuest() }) {
                Text("Continue as Guest")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding(.horizontal, 32)
        .navigationBarHidden(true)
    }
}
