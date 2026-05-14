import Foundation
import AppAuth
#if os(macOS)
import AppKit
import AuthenticationServices
import CryptoKit
#elseif os(iOS)
import UIKit
import AuthenticationServices
import CryptoKit
#endif

/// Microsoft identity platform (Azure AD) OAuth for Outlook / Microsoft 365 mail via Microsoft Graph.
@MainActor
final class MicrosoftOAuthService: NSObject {
    static let shared = MicrosoftOAuthService()
    private override init() {}

    #if os(macOS)
    private var redirectHandler: OIDRedirectHTTPHandler?
    #endif

    #if os(macOS)
    func authorize(presentingWindow: NSWindow?) async throws -> AuthToken {
        guard !MicrosoftCredentials.clientID.isEmpty else {
            throw MicrosoftOAuthError.missingConfiguration
        }
        if !MicrosoftCredentials.macOSRedirectURI.isEmpty {
            return try await authorizeMicrosoftPKCE(redirectURI: MicrosoftCredentials.macOSRedirectURI)
        }
        let tenant = MicrosoftCredentials.tenant
        let config = OIDServiceConfiguration(
            authorizationEndpoint: URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/authorize")!,
            tokenEndpoint: URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!
        )

        let handler = OIDRedirectHTTPHandler(successURL: nil)
        self.redirectHandler = handler
        let loopback = handler.startHTTPListener(nil)
        // AppAuth advertises `http://127.0.0.1:port/` but Entra ID expects you to register
        // `http://localhost` (any port). Same socket accepts `localhost`; only the OAuth string changes.
        let redirectURI = Self.microsoftLoopbackRedirectURL(from: loopback)

        let request = OIDAuthorizationRequest(
            configuration: config,
            clientId: MicrosoftCredentials.clientID,
            clientSecret: MicrosoftCredentials.clientSecret,
            scopes: MicrosoftCredentials.scopes,
            redirectURL: redirectURI,
            responseType: OIDResponseTypeCode,
            additionalParameters: ["prompt": "select_account"]
        )

        let window = presentingWindow
            ?? NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first
            ?? NSWindow()

        return try await withCheckedThrowingContinuation { continuation in
            handler.currentAuthorizationFlow = OIDAuthState.authState(
                byPresenting: request,
                presenting: window
            ) { [weak self] authState, error in
                self?.redirectHandler = nil
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard
                    let tokenResponse = authState?.lastTokenResponse,
                    let accessToken = tokenResponse.accessToken,
                    let refreshToken = authState?.refreshToken
                else {
                    continuation.resume(throwing: MicrosoftOAuthError.noRefreshToken)
                    return
                }
                let expiresIn = Int(tokenResponse.accessTokenExpirationDate?.timeIntervalSinceNow ?? 3600)
                continuation.resume(returning: AuthToken(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    expiresIn: max(expiresIn, 1),
                    tokenType: tokenResponse.tokenType ?? "Bearer",
                    scope: tokenResponse.scope ?? ""
                ))
            }
        }
    }

    private static func microsoftLoopbackRedirectURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let h = (components.host ?? "").lowercased()
        if h == "127.0.0.1" || h == "::1" {
            components.host = "localhost"
        }
        return components.url ?? url
    }
    #elseif os(iOS)
    func authorize() async throws -> AuthToken {
        try await authorizeMicrosoftPKCE(redirectURI: MicrosoftCredentials.iOSRedirectURI)
    }
    #endif

    #if os(iOS) || os(macOS)
    private func authorizeMicrosoftPKCE(redirectURI: String) async throws -> AuthToken {
        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.sha256Base64URL(codeVerifier)
        let tenant = MicrosoftCredentials.tenant
        let scopeString = MicrosoftCredentials.scopes.joined(separator: " ")
        var components = URLComponents(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: MicrosoftCredentials.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopeString),
            URLQueryItem(name: "prompt", value: "select_account"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        guard let authURL = components.url else { throw MicrosoftOAuthError.invalidURL }

        let callbackScheme = redirectURI.components(separatedBy: ":").first ?? ""

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { url, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url = url else {
                    continuation.resume(throwing: MicrosoftOAuthError.noAuthCode)
                    return
                }
                continuation.resume(returning: url)
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            session.start()
        }

        guard
            let urlComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            let code = urlComponents.queryItems?.first(where: { $0.name == "code" })?.value
        else { throw MicrosoftOAuthError.noAuthCode }

        var params: [String: String] = [
            "client_id": MicrosoftCredentials.clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier
        ]
        if !MicrosoftCredentials.clientSecret.isEmpty {
            params["client_secret"] = MicrosoftCredentials.clientSecret
        }

        let tokenURL = URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!
        let response: TokenExchangeResponse = try await postForm(url: tokenURL, params: params)
        return AuthToken(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresIn: response.expiresIn,
            tokenType: response.tokenType,
            scope: response.scope ?? scopeString
        )
    }
    #endif

    /// Refreshes a Microsoft-issued access token.
    func refreshToken(_ token: AuthToken) async throws -> AuthToken {
        guard let refresh = token.refreshToken else { throw MicrosoftOAuthError.noRefreshToken }
        let tenant = MicrosoftCredentials.tenant
        let tokenURL = URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!
        var params: [String: String] = [
            "client_id": MicrosoftCredentials.clientID,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
            "scope": MicrosoftCredentials.scopes.joined(separator: " ")
        ]
        if !MicrosoftCredentials.clientSecret.isEmpty {
            params["client_secret"] = MicrosoftCredentials.clientSecret
        }
        let response: TokenExchangeResponse = try await postForm(url: tokenURL, params: params)
        return AuthToken(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? refresh,
            expiresIn: response.expiresIn,
            tokenType: response.tokenType,
            scope: response.scope ?? token.scope
        )
    }

    // MARK: - Graph profile

    struct GraphMe: Decodable {
        let mail: String?
        let userPrincipalName: String
        let displayName: String?
    }

    func fetchPrimaryEmail(accessToken: String) async throws -> (email: String, displayName: String) {
        var req = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw MicrosoftOAuthError.invalidURL }
        guard (200...299).contains(http.statusCode) else {
            let msg = GmailAPIError.googleErrorSummary(from: data) ?? "HTTP \(http.statusCode)"
            throw MicrosoftOAuthError.graph(msg)
        }
        let me = try JSONDecoder().decode(GraphMe.self, from: data)
        let email = (me.mail?.isEmpty == false ? me.mail! : me.userPrincipalName)
            .lowercased()
        let name = me.displayName ?? email
        return (email, name)
    }

    // MARK: - Private

    private func postForm(url: URL, params: [String: String]) async throws -> TokenExchangeResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let detail = GmailAPIError.googleErrorSummary(from: data)
            throw MicrosoftOAuthError.tokenHTTP(status: status, detail: detail)
        }
        return try JSONDecoder().decode(TokenExchangeResponse.self, from: data)
    }

    #if os(iOS) || os(macOS)
    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sha256Base64URL(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    #endif
}

#if os(iOS) || os(macOS)
extension MicrosoftOAuthService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { self.presentationAnchor(for: session) }
        }
        #if os(iOS)
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #elseif os(macOS)
        return NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first
            ?? NSWindow()
        #endif
    }
}
#endif

// MARK: - DTOs

private struct TokenExchangeResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let tokenType: String
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case scope
    }
}

enum MicrosoftOAuthError: Error, LocalizedError {
    case missingConfiguration
    case invalidURL
    case noAuthCode
    case noRefreshToken
    case graph(String)
    case tokenHTTP(status: Int, detail: String?)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Microsoft sign-in is not configured. Add your Azure client ID and secret in MicrosoftCredentials.swift (see MicrosoftCredentials.swift.example)."
        case .invalidURL: return "Invalid Microsoft OAuth URL"
        case .noAuthCode: return "No authorization code from Microsoft"
        case .noRefreshToken: return "No refresh token from Microsoft"
        case .graph(let s): return s
        case .tokenHTTP(let status, let detail):
            if let detail, !detail.isEmpty { return "Microsoft token error (HTTP \(status)): \(detail)" }
            return "Microsoft token error (HTTP \(status))"
        }
    }
}
