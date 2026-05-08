import Foundation

/// Generic mail provider protocol implemented by Gmail, Outlook, etc.
protocol MailProvider {
    var accountID: String { get }
    var displayName: String { get }
    var providerType: MailProviderType { get }

    func fetchInbox(page: Int) async throws -> [MailThread]
    func fetchThread(id: String) async throws -> MailThread
    func sendMessage(_ message: ComposeMessage) async throws
    func searchMessages(query: String) async throws -> [Email]
    func moveToTrash(messageId: String) async throws
    func archiveMessage(messageId: String) async throws
    func getLabels() async throws -> [EmailLabel]
}

enum MailProviderType: String, Codable {
    case gmail
    case outlook
}

/// Errors used by mail providers
enum MailProviderError: Error {
    case notImplemented
    case networkError(Error)
}
