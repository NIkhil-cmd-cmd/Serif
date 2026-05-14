import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Manages account sign-in, sign-out, and the list of connected mail accounts (Gmail and Outlook).
@MainActor
final class AuthViewModel: ObservableObject {
    @Published var accounts: [GmailAccount] = []
    @Published var isSigningIn = false
    @Published var error: String?

    init() {
        accounts = AccountStore.shared.accounts
    }

    // MARK: - Sign In

    func signIn() async {
        isSigningIn = true
        error = nil
        defer { isSigningIn = false }

        do {
            // 1. OAuth flow → tokens
            #if os(macOS)
            let window = NSApplication.shared.windows.first
            let token = try await OAuthService.shared.authorize(presentingWindow: window)
            #else
            let token = try await OAuthService.shared.authorize()
            #endif

            // 2. Fetch user identity
            let userInfo = try await GmailProfileService.shared.getUserInfo(accessToken: token.accessToken)

            // 3. Save token to Keychain
            try TokenStore.shared.save(token, for: userInfo.email)

            // 4. Fetch Gmail profile (message counts)
            let profile = try await GmailProfileService.shared.getProfile(accountID: userInfo.email)

            // 5. Fetch signature (best-effort)
            let signature = try? await GmailProfileService.shared.getSignature(accountID: userInfo.email)

            // 6. Persist account metadata
            let account = GmailAccount(
                email:             userInfo.email,
                displayName:       userInfo.name ?? userInfo.email,
                profilePictureURL: userInfo.picture.flatMap { URL(string: $0) },
                messagesTotal:     profile.messagesTotal,
                threadsTotal:      profile.threadsTotal,
                signature:         signature,
                unreadCount:       0,
                historyId:         profile.historyId,
                accentColor:       nil,
                provider:          .gmail
            )
            AccountStore.shared.add(account)
            accounts = AccountStore.shared.accounts

        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Microsoft 365 / Outlook.com via Microsoft Graph.
    func signInOutlook() async {
        isSigningIn = true
        error = nil
        defer { isSigningIn = false }

        do {
            #if os(macOS)
            let window = NSApplication.shared.windows.first
            let token = try await MicrosoftOAuthService.shared.authorize(presentingWindow: window)
            #else
            let token = try await MicrosoftOAuthService.shared.authorize()
            #endif

            let identity = try await MicrosoftOAuthService.shared.fetchPrimaryEmail(accessToken: token.accessToken)
            try TokenStore.shared.save(token, for: identity.email)

            let account = GmailAccount(
                email:             identity.email,
                displayName:       identity.displayName,
                profilePictureURL: nil,
                messagesTotal:     0,
                threadsTotal:      0,
                signature:         nil,
                unreadCount:       0,
                historyId:         nil,
                accentColor:       nil,
                provider:          .outlook
            )
            AccountStore.shared.add(account)
            accounts = AccountStore.shared.accounts
        } catch {
            self.error = error.localizedDescription
        }
    }

    func signOut(_ account: GmailAccount) {
        // Unregister from push notifications before removing the account
        #if os(iOS)
        Task {
            await PushNotificationService.shared.unregister(email: account.email)
        }
        #endif

        AttachmentDatabase.shared.deleteByAccountID(account.email)
        AccountStore.shared.remove(id: account.id)
        accounts = AccountStore.shared.accounts

        // If no accounts remain, clear the signed-in flag to return to onboarding
        if accounts.isEmpty {
            UserDefaults.standard.set(false, forKey: "isSignedIn")
        }
    }

    // MARK: - Helpers

    func reloadAccounts() {
        accounts = AccountStore.shared.accounts
    }

    var primaryAccount: GmailAccount? { accounts.first }
    var hasAccounts: Bool { !accounts.isEmpty }
}
