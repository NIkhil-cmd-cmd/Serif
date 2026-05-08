import Foundation

/// Merges inboxes from multiple `MailProvider`s and provides unified lists.
@MainActor
final class UnifiedInboxService {
    static let shared = UnifiedInboxService()
    private init() {}

    private var providers: [MailProvider] = []

    func registerProvider(_ provider: MailProvider) {
        if !providers.contains(where: { $0.accountID == provider.accountID }) {
            providers.append(provider)
        }
    }

    func unregisterProvider(accountID: String) {
        providers.removeAll { $0.accountID == accountID }
    }

    /// Fetches inbox threads from all providers and returns a single sorted list.
    func fetchUnifiedInbox(page: Int = 0) async throws -> [MailThread] {
        var allThreads: [MailThread] = []

        try await withThrowingTaskGroup(of: [MailThread].self) { group in
            for provider in providers {
                group.addTask { try await provider.fetchInbox(page: page) }
            }

            for try await threads in group {
                allThreads.append(contentsOf: threads)
            }
        }

        // Sort by most recent message date across providers
        allThreads.sort { $0.date > $1.date }
        return allThreads
    }

    /// Convenience: fetch single thread by searching providers for matching id.
    func fetchThread(id: String) async throws -> MailThread {
        for provider in providers {
            do {
                let thread = try await provider.fetchThread(id: id)
                return thread
            } catch {
                continue
            }
        }
        throw MailProviderError.notImplemented
    }
}
