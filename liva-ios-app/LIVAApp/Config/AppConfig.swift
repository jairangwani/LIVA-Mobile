import Foundation

final class AppConfig {
    static let shared = AppConfig()

    private let defaults = UserDefaults.standard

    var serverURL: String {
        get { defaults.string(forKey: "serverURL") ?? "http://localhost:5003" }
        set { defaults.set(newValue, forKey: "serverURL") }
    }

    var userId: String {
        get { defaults.string(forKey: "userId") ?? "test_user_mobile" }
        set { defaults.set(newValue, forKey: "userId") }
    }

    var agentId: String {
        get { defaults.string(forKey: "agentId") ?? "1" }
        set { defaults.set(newValue, forKey: "agentId") }
    }

    var instanceId: String {
        get { defaults.string(forKey: "instanceId") ?? "default" }
        set { defaults.set(newValue, forKey: "instanceId") }
    }

    var resolution: String {
        get { defaults.string(forKey: "resolution") ?? "512" }
        set { defaults.set(newValue, forKey: "resolution") }
    }

    private init() {}
}
