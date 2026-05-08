import Foundation
import AuthenticationServices

/// Outlook / Microsoft 365 service using IMAP/SMTP via SwiftMail (SPM).
/// This is a skeleton implementation — OAuth and XOAUTH2 wiring goes here.
@MainActor
final class OutlookService: NSObject, MailProvider {
    static let shared = OutlookService()
    private override init() {}

    // MARK: - MailProvider
    let accountID: String = "outlook-default"
    let displayName: String = "Microsoft Outlook"
    let providerType: MailProviderType = .outlook

    func fetchInbox(page: Int = 0) async throws -> [MailThread] {
        // TODO: Implement IMAP LIST/FETCH using SwiftMail.IMAPServer and XOAUTH2
        throw MailProviderError.notImplemented
    }

    func fetchThread(id: String) async throws -> MailThread {
        // TODO: Fetch full thread via IMAP by thread-id or by message-ids
        throw MailProviderError.notImplemented
    }

    func sendMessage(_ message: ComposeMessage) async throws {
        // TODO: Use SwiftMail.SMTPServer with XOAUTH2 to send
        throw MailProviderError.notImplemented
    }

    func searchMessages(query: String) async throws -> [Email] {
        // TODO: IMAP SEARCH implementation
        throw MailProviderError.notImplemented
    }

    func moveToTrash(messageId: String) async throws {
        // TODO: IMAP STORE +MOVE or flagging
        throw MailProviderError.notImplemented
    }

    func archiveMessage(messageId: String) async throws {
        // TODO: Move message out of INBOX
        throw MailProviderError.notImplemented
    }

    func getLabels() async throws -> [EmailLabel] {
        // TODO: Map IMAP folders to EmailLabel
        return []
    }

    // MARK: - OAuth (Microsoft)
    /// Use ASWebAuthenticationSession or AppAuth to implement OAuth 2.0 with PKCE
    /// Register app in Azure AD and request scopes:
    /// - https://outlook.office365.com/IMAP.AccessAsUser.All
    /// - https://outlook.office365.com/SMTP.Send
    /// Store refresh token securely in Keychain via existing TokenStore.
}
