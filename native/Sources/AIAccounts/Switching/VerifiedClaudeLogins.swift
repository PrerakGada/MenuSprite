import Foundation

/// Which account Anthropic says a Claude login belongs to, remembered by token fingerprint so a
/// rotated login is asked about once. `~/.claude.json` cannot answer this: the Claude desktop app
/// writes its own account there while the CLI's keychain login belongs to another. The usage
/// service fills it; the accounts board reads it to mark the active account.
public final class VerifiedClaudeLogins: @unchecked Sendable {
    public static let shared = VerifiedClaudeLogins()

    private let lock = NSLock()
    private var emails: [String: String] = [:]

    public init() {}

    public func email(forFingerprint fingerprint: String) -> String? {
        lock.withLock { emails[fingerprint] }
    }

    public func remember(_ email: String, forFingerprint fingerprint: String) {
        lock.withLock {
            if emails.count > 32 { emails.removeAll() }
            emails[fingerprint] = email
        }
    }
}
