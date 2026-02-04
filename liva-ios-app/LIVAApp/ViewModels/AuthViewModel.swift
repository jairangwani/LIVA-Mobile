import Foundation

final class AuthViewModel: ObservableObject {
    @Published var isLoggedIn: Bool = false
    @Published var userId: String = ""
    @Published var email: String = ""
    @Published var password: String = ""

    init() {
        // Auto-login in test mode if userId already stored
        let stored = AppConfig.shared.userId
        if stored != "test_user_mobile" && !stored.isEmpty {
            userId = stored
            isLoggedIn = true
        }
    }

    func loginAsGuest() {
        userId = "guest_\(UUID().uuidString.prefix(8).lowercased())"
        AppConfig.shared.userId = userId
        isLoggedIn = true
    }

    func login() {
        // For test mode, use email as userId
        guard !email.isEmpty else { return }
        userId = email
        AppConfig.shared.userId = userId
        isLoggedIn = true
    }

    func logout() {
        isLoggedIn = false
        userId = ""
        AppConfig.shared.userId = "test_user_mobile"
    }
}
