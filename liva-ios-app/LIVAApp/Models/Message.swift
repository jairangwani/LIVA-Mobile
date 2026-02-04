import Foundation

struct Message: Identifiable {
    let id: UUID
    let text: String
    let isUser: Bool
    let timestamp: Date

    init(text: String, isUser: Bool) {
        self.id = UUID()
        self.text = text
        self.isUser = isUser
        self.timestamp = Date()
    }
}
