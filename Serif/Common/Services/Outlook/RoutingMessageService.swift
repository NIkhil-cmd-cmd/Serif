import Foundation

/// Routes `MessageFetching` calls to Gmail or Microsoft Graph based on `AccountStore` provider.
@MainActor
final class RoutingMessageService: MessageFetching {
    static let shared = RoutingMessageService()
    private let gmail = GmailMessageService.shared
    private let graph = MicrosoftGraphMessageService.shared
    private init() {}

    private func provider(for accountID: String) -> MailProviderType {
        AccountStore.shared.accounts.first(where: { $0.id == accountID })?.provider ?? .gmail
    }

    func listMessages(
        accountID: String,
        labelIDs: [String],
        query: String?,
        pageToken: String?,
        maxResults: Int
    ) async throws -> GmailMessageListResponse {
        switch provider(for: accountID) {
        case .gmail: return try await gmail.listMessages(accountID: accountID, labelIDs: labelIDs, query: query, pageToken: pageToken, maxResults: maxResults)
        case .outlook: return try await graph.listMessages(accountID: accountID, labelIDs: labelIDs, query: query, pageToken: pageToken, maxResults: maxResults)
        }
    }

    func getMessage(id: String, accountID: String, format: String) async throws -> GmailMessage {
        switch provider(for: accountID) {
        case .gmail: return try await gmail.getMessage(id: id, accountID: accountID, format: format)
        case .outlook: return try await graph.getMessage(id: id, accountID: accountID, format: format)
        }
    }

    func getMessages(ids: [String], accountID: String, format: String) async throws -> [GmailMessage] {
        switch provider(for: accountID) {
        case .gmail: return try await gmail.getMessages(ids: ids, accountID: accountID, format: format)
        case .outlook: return try await graph.getMessages(ids: ids, accountID: accountID, format: format)
        }
    }

    func listHistory(
        accountID: String,
        startHistoryId: String,
        labelId: String?,
        pageToken: String?,
        maxResults: Int
    ) async throws -> GmailHistoryListResponse {
        switch provider(for: accountID) {
        case .gmail: return try await gmail.listHistory(accountID: accountID, startHistoryId: startHistoryId, labelId: labelId, pageToken: pageToken, maxResults: maxResults)
        case .outlook: throw GraphMailError.historyUnsupported
        }
    }

    func markAsRead(id: String, accountID: String) async throws {
        switch provider(for: accountID) {
        case .gmail: try await gmail.markAsRead(id: id, accountID: accountID)
        case .outlook: try await graph.markAsRead(id: id, accountID: accountID)
        }
    }

    func setStarred(_ starred: Bool, id: String, accountID: String) async throws {
        switch provider(for: accountID) {
        case .gmail: try await gmail.setStarred(starred, id: id, accountID: accountID)
        case .outlook: try await graph.setStarred(starred, id: id, accountID: accountID)
        }
    }

    func trashMessage(id: String, accountID: String) async throws {
        switch provider(for: accountID) {
        case .gmail: try await gmail.trashMessage(id: id, accountID: accountID)
        case .outlook: try await graph.trashMessage(id: id, accountID: accountID)
        }
    }

    func trashThread(id: String, accountID: String) async throws {
        switch provider(for: accountID) {
        case .gmail: try await gmail.trashThread(id: id, accountID: accountID)
        case .outlook: try await graph.trashThread(id: id, accountID: accountID)
        }
    }

    func archiveMessage(id: String, accountID: String) async throws {
        switch provider(for: accountID) {
        case .gmail: try await gmail.archiveMessage(id: id, accountID: accountID)
        case .outlook: try await graph.archiveMessage(id: id, accountID: accountID)
        }
    }

    func markAsUnread(id: String, accountID: String) async throws {
        switch provider(for: accountID) {
        case .gmail: try await gmail.markAsUnread(id: id, accountID: accountID)
        case .outlook: try await graph.markAsUnread(id: id, accountID: accountID)
        }
    }

    func untrashMessage(id: String, accountID: String) async throws {
        switch provider(for: accountID) {
        case .gmail: try await gmail.untrashMessage(id: id, accountID: accountID)
        case .outlook: try await graph.untrashMessage(id: id, accountID: accountID)
        }
    }

    func deleteMessagePermanently(id: String, accountID: String) async throws {
        switch provider(for: accountID) {
        case .gmail: try await gmail.deleteMessagePermanently(id: id, accountID: accountID)
        case .outlook: try await graph.deleteMessagePermanently(id: id, accountID: accountID)
        }
    }

    func spamMessage(id: String, accountID: String) async throws {
        switch provider(for: accountID) {
        case .gmail: try await gmail.spamMessage(id: id, accountID: accountID)
        case .outlook: try await graph.spamMessage(id: id, accountID: accountID)
        }
    }

    func modifyLabels(id: String, add: [String], remove: [String], accountID: String) async throws -> GmailMessage {
        switch provider(for: accountID) {
        case .gmail: return try await gmail.modifyLabels(id: id, add: add, remove: remove, accountID: accountID)
        case .outlook: return try await graph.modifyLabels(id: id, add: add, remove: remove, accountID: accountID)
        }
    }

    func getThread(id: String, accountID: String) async throws -> GmailThread {
        switch provider(for: accountID) {
        case .gmail: return try await gmail.getThread(id: id, accountID: accountID)
        case .outlook: return try await graph.getThread(id: id, accountID: accountID)
        }
    }

    func getAttachment(messageID: String, attachmentID: String, accountID: String) async throws -> Data {
        switch provider(for: accountID) {
        case .gmail: return try await gmail.getAttachment(messageID: messageID, attachmentID: attachmentID, accountID: accountID)
        case .outlook: return try await graph.getAttachment(messageID: messageID, attachmentID: attachmentID, accountID: accountID)
        }
    }

    func emptyTrash(accountID: String) async throws {
        switch provider(for: accountID) {
        case .gmail: try await gmail.emptyTrash(accountID: accountID)
        case .outlook: try await graph.emptyTrash(accountID: accountID)
        }
    }

    func emptySpam(accountID: String) async throws {
        switch provider(for: accountID) {
        case .gmail: try await gmail.emptySpam(accountID: accountID)
        case .outlook: try await graph.emptySpam(accountID: accountID)
        }
    }

    /// Loads raw RFC 822 source (Gmail) or MIME stream (Outlook) as a `GmailMessage` with `raw` populated.
    func getRawMessage(id: String, accountID: String) async throws -> GmailMessage {
        switch provider(for: accountID) {
        case .gmail: return try await GmailMessageService.shared.getRawMessage(id: id, accountID: accountID)
        case .outlook: return try await MicrosoftGraphMessageService.shared.getRawMessage(id: id, accountID: accountID)
        }
    }
}

enum GraphMailError: Error, LocalizedError {
    case historyUnsupported

    var errorDescription: String? {
        switch self {
        case .historyUnsupported:
            return "Outlook accounts do not support Gmail-style history sync."
        }
    }
}
