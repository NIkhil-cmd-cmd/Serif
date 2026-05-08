import Foundation

/// Unified thread model used by MailProvider implementations.
struct MailThread: Identifiable, Hashable {
    let id: String
    let accountID: String
    var subject: String
    var messages: [Email]
    var date: Date {
        messages.first?.date ?? Date()
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
