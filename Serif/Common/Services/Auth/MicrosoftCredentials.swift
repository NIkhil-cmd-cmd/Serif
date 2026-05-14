import Foundation

/// Azure AD app used for Microsoft 365 / Outlook.com. Replace placeholders (see `MicrosoftCredentials.swift.example`).
///
/// macOS: either register **`http://localhost`** (loopback, `macOSRedirectURI` empty) or use the same custom redirect as Azure (`macOSRedirectURI` + URL scheme in `Info.plist`).
enum MicrosoftCredentials {
    static let tenant = "common"
    static let clientID = "e00c898a-bb06-4e83-b767-c7db99a8f73d"
    static let clientSecret = "655763b8-88ee-495a-8444-de45b9767084"
    static let iOSRedirectURI = "com.serif.outlook.oauth://callback"
    /// Matches Azure “native” redirect when the portal suggests `msauth.<bundle>://auth`.
    static let macOSRedirectURI = "msauth.com.genyus.serif.app.n://auth"
    static let scopes = [
        "offline_access",
        "openid",
        "profile",
        "User.Read",
        "Mail.ReadWrite"
    ]
}
