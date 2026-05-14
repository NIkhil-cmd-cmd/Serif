import Foundation

/// Microsoft Graph implementation of `MessageFetching`, mapping Graph mail to `GmailMessage` for shared UI.
@MainActor
final class MicrosoftGraphMessageService: MessageFetching {
    static let shared = MicrosoftGraphMessageService()
    private let base = "https://graph.microsoft.com/v1.0/"
    /// Last folder label used in `listMessages` per account (so `getMessage` can attach sensible `labelIds`).
    private var lastListPrimaryLabel: [String: String] = [:]
    private init() {}

    /// Raw MIME (RFC 822) as a `GmailMessage` with `format=raw`-style payload for shared UI.
    func getRawMessage(id: String, accountID: String) async throws -> GmailMessage {
        let token = try await validToken(for: accountID)
        var req = URLRequest(url: URL(string: base + "me/messages/\(id)/$value")!)
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (mimeData, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GmailAPIError.invalidURL }
        guard (200...299).contains(http.statusCode) else {
            throw GmailAPIError.httpError(http.statusCode, mimeData)
        }
        let meta = try await getMessage(id: id, accountID: accountID, format: "metadata")
        let b64 = Self.base64URLEncode(mimeData)
        return GmailMessage(
            id: meta.id,
            threadId: meta.threadId,
            labelIds: meta.labelIds,
            snippet: meta.snippet,
            internalDate: meta.internalDate,
            payload: meta.payload,
            sizeEstimate: mimeData.count,
            historyId: nil,
            raw: b64
        )
    }

    // MARK: - MessageFetching

    func listMessages(
        accountID: String,
        labelIDs: [String],
        query: String?,
        pageToken: String?,
        maxResults: Int
    ) async throws -> GmailMessageListResponse {
        lastListPrimaryLabel[accountID] = resolvedLabel(labelIDs)
        let token = try await validToken(for: accountID)
        let url: URL
        if let pageToken, pageToken.hasPrefix("http") {
            guard let u = URL(string: pageToken) else { throw GmailAPIError.invalidURL }
            url = u
        } else {
            url = try listURL(labelIDs: labelIDs, query: query, maxResults: maxResults)
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        if query != nil, !(query ?? "").isEmpty {
            req.setValue("eventual", forHTTPHeaderField: "ConsistencyLevel")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GmailAPIError.invalidURL }
        guard (200...299).contains(http.statusCode) else {
            throw GmailAPIError.httpError(http.statusCode, data)
        }
        let decoded = try JSONDecoder().decode(GraphMessagePage.self, from: data)
        let refs = decoded.value.map { GmailMessageRef(id: $0.id, threadId: $0.conversationId) }
        return GmailMessageListResponse(
            messages: refs,
            nextPageToken: decoded.nextLink,
            resultSizeEstimate: decoded.value.count
        )
    }

    func getMessage(id: String, accountID: String, format: String) async throws -> GmailMessage {
        let token = try await validToken(for: accountID)
        let select = "$select=id,conversationId,subject,bodyPreview,receivedDateTime,isRead,hasAttachments,body,sender,from,toRecipients,ccRecipients,flag"
        let url = URL(string: base + "me/messages/\(id)?\(select)")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GmailAPIError.invalidURL }
        guard (200...299).contains(http.statusCode) else {
            throw GmailAPIError.httpError(http.statusCode, data)
        }
        let item = try JSONDecoder().decode(GraphMessageItem.self, from: data)
        return Self.mapToGmailMessage(item, formatHint: format, accountID: accountID, folderHint: lastListPrimaryLabel[accountID])
    }

    func getMessages(ids: [String], accountID: String, format: String) async throws -> [GmailMessage] {
        try await withThrowingTaskGroup(of: GmailMessage.self) { group in
            for id in ids {
                group.addTask { try await self.getMessage(id: id, accountID: accountID, format: format) }
            }
            var out: [GmailMessage] = []
            for try await m in group { out.append(m) }
            return out.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }
    }

    func listHistory(
        accountID: String,
        startHistoryId: String,
        labelId: String?,
        pageToken: String?,
        maxResults: Int
    ) async throws -> GmailHistoryListResponse {
        throw GraphMailError.historyUnsupported
    }

    func markAsRead(id: String, accountID: String) async throws {
        try await patchMessage(id: id, accountID: accountID, body: ["isRead": true])
    }

    func setStarred(_ starred: Bool, id: String, accountID: String) async throws {
        let status = starred ? "flagged" : "notFlagged"
        let body: [String: Any] = ["flag": ["flagStatus": status]]
        try await patchMessage(id: id, accountID: accountID, body: body)
    }

    func trashMessage(id: String, accountID: String) async throws {
        try await moveMessage(id: id, accountID: accountID, destinationId: "deleteditems")
    }

    func trashThread(id: String, accountID: String) async throws {
        let msgs = try await messagesInConversation(conversationId: id, accountID: accountID)
        for m in msgs { try await trashMessage(id: m.id, accountID: accountID) }
    }

    func archiveMessage(id: String, accountID: String) async throws {
        try await moveMessage(id: id, accountID: accountID, destinationId: "archive")
    }

    func markAsUnread(id: String, accountID: String) async throws {
        try await patchMessage(id: id, accountID: accountID, body: ["isRead": false])
    }

    func untrashMessage(id: String, accountID: String) async throws {
        try await moveMessage(id: id, accountID: accountID, destinationId: "inbox")
    }

    func deleteMessagePermanently(id: String, accountID: String) async throws {
        let token = try await validToken(for: accountID)
        var req = URLRequest(url: URL(string: base + "me/messages/\(id)")!)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GmailAPIError.invalidURL }
        guard (200...299).contains(http.statusCode) || http.statusCode == 204 else {
            throw GmailAPIError.httpError(http.statusCode, Data())
        }
    }

    func spamMessage(id: String, accountID: String) async throws {
        try await moveMessage(id: id, accountID: accountID, destinationId: "junkemail")
    }

    func modifyLabels(id: String, add: [String], remove: [String], accountID: String) async throws -> GmailMessage {
        if add.contains("STARRED") || remove.contains("STARRED") {
            let starred = add.contains("STARRED")
            try await setStarred(starred, id: id, accountID: accountID)
        }
        if add.contains("UNREAD") { try await markAsUnread(id: id, accountID: accountID) }
        if remove.contains("UNREAD") { try await markAsRead(id: id, accountID: accountID) }
        return try await getMessage(id: id, accountID: accountID, format: "metadata")
    }

    func getThread(id: String, accountID: String) async throws -> GmailThread {
        let msgs = try await messagesInConversation(conversationId: id, accountID: accountID)
        let gmail = try await getMessages(ids: msgs.map(\.id), accountID: accountID, format: "full")
        return GmailThread(id: id, historyId: nil, messages: gmail.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) })
    }

    func getAttachment(messageID: String, attachmentID: String, accountID: String) async throws -> Data {
        let token = try await validToken(for: accountID)
        var req = URLRequest(url: URL(string: base + "me/messages/\(messageID)/attachments/\(attachmentID)/$value")!)
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GmailAPIError.invalidURL }
        guard (200...299).contains(http.statusCode) else {
            throw GmailAPIError.httpError(http.statusCode, data)
        }
        return data
    }

    func emptyTrash(accountID: String) async throws {
        try await emptyFolder(wellKnown: "deleteditems", accountID: accountID)
    }

    func emptySpam(accountID: String) async throws {
        try await emptyFolder(wellKnown: "junkemail", accountID: accountID)
    }

    // MARK: - Token

    private func validToken(for accountID: String) async throws -> AuthToken {
        guard var token = try TokenStore.shared.retrieve(for: accountID) else {
            throw GmailAPIError.unauthorized
        }
        if token.isExpired {
            token = try await MicrosoftOAuthService.shared.refreshToken(token)
            try TokenStore.shared.save(token, for: accountID)
        }
        return token
    }

    // MARK: - Graph HTTP

    private func patchMessage(id: String, accountID: String, body: [String: Any]) async throws {
        let token = try await validToken(for: accountID)
        var req = URLRequest(url: URL(string: base + "me/messages/\(id)")!)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GmailAPIError.invalidURL }
        guard (200...299).contains(http.statusCode) else {
            throw GmailAPIError.httpError(http.statusCode, data)
        }
    }

    private func moveMessage(id: String, accountID: String, destinationId: String) async throws {
        let token = try await validToken(for: accountID)
        var req = URLRequest(url: URL(string: base + "me/messages/\(id)/move")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = ["destinationId": destinationId]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GmailAPIError.invalidURL }
        guard (200...299).contains(http.statusCode) else {
            throw GmailAPIError.httpError(http.statusCode, data)
        }
    }

    private func emptyFolder(wellKnown: String, accountID: String) async throws {
        let token = try await validToken(for: accountID)
        var req = URLRequest(url: URL(string: base + "me/mailFolders/\(wellKnown)/microsoft.graph.empty")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GmailAPIError.invalidURL }
        guard (200...299).contains(http.statusCode) else {
            throw GmailAPIError.httpError(http.statusCode, data)
        }
    }

    private func messagesInConversation(conversationId: String, accountID: String) async throws -> [GraphMessageRefLite] {
        let token = try await validToken(for: accountID)
        let escaped = conversationId.replacingOccurrences(of: "'", with: "''")
        let filter = "$filter=conversationId eq '\(escaped)'&$select=id&$top=100"
        var req = URLRequest(url: URL(string: base + "me/messages?\(filter)")!)
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GmailAPIError.invalidURL }
        guard (200...299).contains(http.statusCode) else {
            throw GmailAPIError.httpError(http.statusCode, data)
        }
        let page = try JSONDecoder().decode(GraphMessageRefPage.self, from: data)
        return page.value
    }

    private func listURL(labelIDs: [String], query: String?, maxResults: Int) throws -> URL {
        let top = min(max(maxResults, 1), 999)
        if let q = query, !q.isEmpty {
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            guard let u = URL(string: base + "me/messages?$search=\"\(encoded)\"&$top=\(top)&$orderby=receivedDateTime desc") else {
                throw GmailAPIError.invalidURL
            }
            return u
        }
        let primary = resolvedLabel(labelIDs)
        switch primary {
        case "STARRED":
            guard let u = URL(string: base + "me/messages?$filter=flag/flagStatus eq 'flagged'&$top=\(top)&$orderby=receivedDateTime desc") else {
                throw GmailAPIError.invalidURL
            }
            return u
        default:
            let folder = graphWellKnownFolder(forLabel: primary)
            guard let u = URL(string: base + "me/mailFolders/\(folder)/messages?$top=\(top)&$orderby=receivedDateTime desc") else {
                throw GmailAPIError.invalidURL
            }
            return u
        }
    }

    private func resolvedLabel(_ labelIDs: [String]) -> String {
        let set = Set(labelIDs)
        if set.contains("STARRED") && labelIDs.count == 1 { return "STARRED" }
        if set.contains("SENT") { return "SENT" }
        if set.contains("DRAFT") { return "DRAFT" }
        if set.contains("TRASH") { return "TRASH" }
        if set.contains("SPAM") { return "SPAM" }
        if set.contains("INBOX") { return "INBOX" }
        return labelIDs.first ?? "INBOX"
    }

    private func graphWellKnownFolder(forLabel: String) -> String {
        switch forLabel {
        case "SENT": return "sentitems"
        case "DRAFT": return "drafts"
        case "TRASH": return "deleteditems"
        case "SPAM": return "junkemail"
        default: return "inbox"
        }
    }

    // MARK: - GmailMessage synthesis

    private static func mapToGmailMessage(
        _ g: GraphMessageItem,
        formatHint: String,
        accountID: String,
        folderHint: String?
    ) -> GmailMessage {
        let labels = labelIds(for: g, folderHint: folderHint)
        let internalMs: String = {
            guard let s = g.receivedDateTime else { return String(Int64(Date().timeIntervalSince1970 * 1000)) }
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fmt.date(from: s) { return String(Int64(d.timeIntervalSince1970 * 1000)) }
            let fmt2 = ISO8601DateFormatter()
            if let d = fmt2.date(from: s) { return String(Int64(d.timeIntervalSince1970 * 1000)) }
            return String(Int64(Date().timeIntervalSince1970 * 1000))
        }()

        let wantBody = formatHint == "full" || formatHint == "raw"
        let html = wantBody ? (g.body?.contentType?.lowercased().contains("html") == true ? g.body?.content : nil) : nil
        let plain = wantBody ? (g.body?.contentType?.lowercased().contains("text") == true && html == nil ? g.body?.content : nil) : nil

        var parts: [GmailMessagePart] = []
        if let html, !html.isEmpty {
            let data = base64URLEncode(Data(html.utf8))
            parts.append(GmailMessagePart(
                partId: "0",
                mimeType: "text/html",
                filename: nil,
                headers: nil,
                body: GmailMessageBody(attachmentId: nil, size: html.utf8.count, data: data),
                parts: nil
            ))
        } else if let plain, !plain.isEmpty {
            let data = base64URLEncode(Data(plain.utf8))
            parts.append(GmailMessagePart(
                partId: "0",
                mimeType: "text/plain",
                filename: nil,
                headers: nil,
                body: GmailMessageBody(attachmentId: nil, size: plain.utf8.count, data: data),
                parts: nil
            ))
        }

        let payload = GmailMessagePart(
            partId: nil,
            mimeType: "multipart/alternative",
            filename: nil,
            headers: headers(for: g),
            body: nil,
            parts: parts.isEmpty ? nil : parts
        )

        return GmailMessage(
            id: g.id,
            threadId: g.conversationId,
            labelIds: labels,
            snippet: g.bodyPreview,
            internalDate: internalMs,
            payload: payload,
            sizeEstimate: nil,
            historyId: nil,
            raw: nil
        )
    }

    private static func labelIds(for g: GraphMessageItem, folderHint: String?) -> [String] {
        var labels: [String] = []
        let folder = folderHint ?? "INBOX"
        switch folder {
        case "SENT": labels.append("SENT")
        case "DRAFT": labels.append("DRAFT")
        case "TRASH": labels.append("TRASH")
        case "SPAM": labels.append("SPAM")
        case "STARRED": labels.append("STARRED")
        default: labels.append("INBOX")
        }
        if g.isRead != true { labels.append("UNREAD") }
        if g.flag?.flagStatus == "flagged", !labels.contains("STARRED") { labels.append("STARRED") }
        return labels
    }

    private static func headers(for g: GraphMessageItem) -> [GmailHeader] {
        var h: [GmailHeader] = []
        if let s = g.subject { h.append(GmailHeader(name: "Subject", value: s)) }
        h.append(GmailHeader(name: "From", value: formatAddress(g.from ?? g.sender)))
        if let to = g.toRecipients, !to.isEmpty {
            h.append(GmailHeader(name: "To", value: to.map { formatAddress($0) }.joined(separator: ", ")))
        }
        if let cc = g.ccRecipients, !cc.isEmpty {
            h.append(GmailHeader(name: "Cc", value: cc.map { formatAddress($0) }.joined(separator: ", ")))
        }
        return h
    }

    private static func formatAddress(_ r: GraphRecipientWrapper?) -> String {
        guard let r, let em = r.emailAddress else { return "" }
        let addr = em.address ?? ""
        let name = (em.name ?? "").trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return addr }
        return "\(name) <\(addr)>"
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Graph DTOs

private struct GraphMessagePage: Decodable {
    let value: [GraphMessageItem]
    let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

private struct GraphMessageRefPage: Decodable {
    let value: [GraphMessageRefLite]
}

private struct GraphMessageRefLite: Decodable {
    let id: String
}

private struct GraphRecipientWrapper: Decodable {
    let emailAddress: GraphEmailAddress?
}

private struct GraphEmailAddress: Decodable {
    let name: String?
    let address: String?
}

private struct GraphBody: Decodable {
    let contentType: String?
    let content: String?
}

private struct GraphFlag: Decodable {
    let flagStatus: String?
}

private struct GraphMessageItem: Decodable {
    let id: String
    let conversationId: String
    let subject: String?
    let bodyPreview: String?
    let receivedDateTime: String?
    let isRead: Bool?
    let hasAttachments: Bool?
    let body: GraphBody?
    let sender: GraphRecipientWrapper?
    let from: GraphRecipientWrapper?
    let toRecipients: [GraphRecipientWrapper]?
    let ccRecipients: [GraphRecipientWrapper]?
    let flag: GraphFlag?
}
