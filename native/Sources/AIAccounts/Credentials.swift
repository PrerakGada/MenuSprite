import CryptoKit
import Darwin
import Foundation

/// JSON helpers that never drop keys MenuSprite does not model.
public enum CredentialJSON {
    /// Parses a JSON object. Also accepts the hex text `security find-generic-password -w` prints
    /// when a stored payload contains non-printable bytes.
    public static func object(from text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let object = decode(Data(trimmed.utf8)) { return object }
        guard !trimmed.isEmpty, trimmed.count % 2 == 0, trimmed.allSatisfy(\.isHexDigit),
              let bytes = hexData(trimmed) else { return nil }
        return decode(bytes)
    }

    public static func text(from object: [String: Any], pretty: Bool = false) -> String? {
        var options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes]
        if pretty { options.formUnion([.prettyPrinted, .sortedKeys]) }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: options) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func hex(_ text: String) -> String {
        Data(text.utf8).map { String(format: "%02x", $0) }.joined()
    }

    public static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    static func date(iso8601 text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func decode(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func hexData(_ text: String) -> Data? {
        var data = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

public enum JWT {
    /// The unverified claims of a JWT. Used only to name an account, never to trust one.
    public static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum TokenFingerprint {
    static func of(_ parts: String...) -> String {
        var hasher = SHA256()
        for part in parts { hasher.update(data: Data(part.utf8)); hasher.update(data: Data([0])) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Claude Code's keychain payload (`{"claudeAiOauth": {...}, "mcpOAuth": {...}}`).
public struct ClaudeCredential: Sendable, Equatable {
    /// The complete payload as normalized JSON, so unmodelled keys such as `mcpOAuth` and
    /// `refreshTokenExpiresAt` survive every rewrite.
    public let rawJSON: String
    public let accessToken: String
    public let refreshToken: String?
    /// Milliseconds since 1970, as Claude Code stores it.
    public let expiresAtMilliseconds: Double?
    public let subscriptionType: String?
    public let rateLimitTier: String?
    public let scopes: [String]?

    public init?(json: String) {
        guard let object = CredentialJSON.object(from: json),
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let access = CredentialJSON.nonEmpty(oauth["accessToken"]),
              let raw = CredentialJSON.text(from: object) else { return nil }
        rawJSON = raw
        accessToken = access
        refreshToken = CredentialJSON.nonEmpty(oauth["refreshToken"])
        expiresAtMilliseconds = CredentialJSON.number(oauth["expiresAt"])
        subscriptionType = CredentialJSON.nonEmpty(oauth["subscriptionType"])
        rateLimitTier = CredentialJSON.nonEmpty(oauth["rateLimitTier"])
        scopes = oauth["scopes"] as? [String]
    }

    /// Credentials predating the scopes field are assumed able to read usage.
    public var canReadUsage: Bool {
        guard let scopes, !scopes.isEmpty else { return true }
        return scopes.contains("user:profile")
    }

    public func expires(within seconds: TimeInterval, now: Date = Date()) -> Bool {
        guard let expiresAtMilliseconds else { return false }
        return expiresAtMilliseconds - now.timeIntervalSince1970 * 1000 <= seconds * 1000
    }

    /// A copy carrying rotated tokens with every other key preserved.
    public func rotated(accessToken: String, refreshToken: String?, expiresInSeconds: Double?, now: Date = Date()) -> ClaudeCredential? {
        guard var object = CredentialJSON.object(from: rawJSON), var oauth = object["claudeAiOauth"] as? [String: Any] else { return nil }
        oauth["accessToken"] = accessToken
        if let refreshToken, !refreshToken.isEmpty { oauth["refreshToken"] = refreshToken }
        if let expiresInSeconds { oauth["expiresAt"] = Int64((now.timeIntervalSince1970 + expiresInSeconds) * 1000) }
        object["claudeAiOauth"] = oauth
        return CredentialJSON.text(from: object).flatMap(ClaudeCredential.init(json:))
    }

    /// Identifies the token pair without retaining another copy of either token.
    public var tokenFingerprint: String { TokenFingerprint.of(accessToken, refreshToken ?? "") }
}

/// The Codex CLI's `auth.json` payload.
public struct CodexCredential: Sendable, Equatable {
    public let rawJSON: String
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    /// `tokens.account_id`, else the id token's ChatGPT account claim — the value Codex sends as `ChatGPT-Account-Id`.
    public let accountID: String?
    public let email: String?
    public let plan: String?
    public let accessTokenExpiresAt: Date?
    public let lastRefresh: Date?

    public init?(json: String) {
        guard let object = CredentialJSON.object(from: json),
              let tokens = object["tokens"] as? [String: Any],
              let access = CredentialJSON.nonEmpty(tokens["access_token"]),
              let raw = CredentialJSON.text(from: object) else { return nil }
        rawJSON = raw
        accessToken = access
        refreshToken = CredentialJSON.nonEmpty(tokens["refresh_token"])
        idToken = CredentialJSON.nonEmpty(tokens["id_token"])
        let claims = idToken.flatMap(JWT.payload)
        let auth = claims?["https://api.openai.com/auth"] as? [String: Any]
        accountID = CredentialJSON.nonEmpty(tokens["account_id"])
            ?? CredentialJSON.nonEmpty(auth?["chatgpt_account_id"])
            ?? CredentialJSON.nonEmpty(claims?["chatgpt_account_id"])
        email = CredentialJSON.nonEmpty(claims?["email"])
        plan = CredentialJSON.nonEmpty(auth?["chatgpt_plan_type"])
        accessTokenExpiresAt = CredentialJSON.number(JWT.payload(access)?["exp"]).map(Date.init(timeIntervalSince1970:))
        lastRefresh = CredentialJSON.nonEmpty(object["last_refresh"]).flatMap(CredentialJSON.date(iso8601:))
    }

    /// Uses the access token's own `exp`, as the Codex CLI does; the 8-day age is only a fallback
    /// for tokens without a readable expiry.
    public func expires(within seconds: TimeInterval, now: Date = Date()) -> Bool {
        if let accessTokenExpiresAt { return accessTokenExpiresAt.timeIntervalSince(now) <= seconds }
        guard let lastRefresh else { return false }
        return now.timeIntervalSince(lastRefresh) > 8 * 24 * 60 * 60
    }

    public func rotated(accessToken: String, refreshToken: String?, idToken: String?, now: Date = Date()) -> CodexCredential? {
        guard var object = CredentialJSON.object(from: rawJSON), var tokens = object["tokens"] as? [String: Any] else { return nil }
        tokens["access_token"] = accessToken
        if let refreshToken, !refreshToken.isEmpty { tokens["refresh_token"] = refreshToken }
        if let idToken, !idToken.isEmpty { tokens["id_token"] = idToken }
        object["tokens"] = tokens
        object["last_refresh"] = CredentialJSON.iso8601(now)
        return CredentialJSON.text(from: object).flatMap(CodexCredential.init(json:))
    }

    /// Pretty, sorted JSON for `auth.json`; compact JSON for keychain copies.
    public func formatted(pretty: Bool) -> String {
        CredentialJSON.object(from: rawJSON).flatMap { CredentialJSON.text(from: $0, pretty: pretty) } ?? rawJSON
    }

    public var tokenFingerprint: String { TokenFingerprint.of(accessToken, refreshToken ?? "") }
}

/// Reads Claude Code's state file. Writing `oauthAccount` belongs to account switching.
public enum ClaudeState {
    /// The `oauthAccount` object as JSON text, or nil when the file or key is absent.
    public static func oauthAccountJSON(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let object = (try JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = object["oauthAccount"] as? [String: Any] else { return nil }
        return CredentialJSON.text(from: account)
    }

    public static func email(inOAuthAccount json: String) -> String? {
        CredentialJSON.object(from: json).flatMap { CredentialJSON.nonEmpty($0["emailAddress"]) }
    }
}

/// Replaces a file so readers only ever see the old or the new complete contents.
public enum AtomicFile {
    /// - Parameter permissions: explicit mode; nil keeps the destination's current mode, else 0600.
    public static func write(_ data: Data, to url: URL, permissions: mode_t? = nil) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mode = permissions ?? existingMode(url) ?? 0o600
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).menusprite-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode)
        guard descriptor >= 0 else { throw posixError() }
        var published = false
        defer { if !published { unlink(temporary.path) } }
        do {
            guard fchmod(descriptor, mode) == 0 else { throw posixError() }
            try data.withUnsafeBytes { buffer in
                guard var pointer = buffer.baseAddress else { return }
                var remaining = buffer.count
                while remaining > 0 {
                    let written = Darwin.write(descriptor, pointer, remaining)
                    if written < 0 { if errno == EINTR { continue }; throw posixError() }
                    pointer = pointer.advanced(by: written); remaining -= written
                }
            }
            guard fsync(descriptor) == 0 else { throw posixError() }
        } catch {
            close(descriptor)
            throw error
        }
        guard close(descriptor) == 0 else { throw posixError() }
        guard rename(temporary.path, url.path) == 0 else { throw posixError() }
        published = true
    }

    private static func existingMode(_ url: URL) -> mode_t? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return info.st_mode & 0o777
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
