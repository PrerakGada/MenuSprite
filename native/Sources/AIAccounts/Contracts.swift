import Foundation

/// The command-line agents whose live login MenuSprite reads and swaps.
public enum AIProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude, codex
    public var id: String { rawValue }
    public var title: String { self == .claude ? "Claude" : "Codex" }
}

/// One rate-limit window exactly as the provider's server reports it. `usedPercent` is the
/// server's own utilization (0–100); nothing here is estimated from local logs.
public struct UsageWindow: Sendable, Equatable, Codable, Identifiable {
    /// Stable key: `session`, `weekly`, `sonnet`, `fable`, `spark` or `sparkWeekly`.
    public let id: String
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?
    public let windowSeconds: Double?

    public init(id: String, label: String, usedPercent: Double, resetsAt: Date?, windowSeconds: Double?) {
        self.id = id; self.label = label; self.usedPercent = usedPercent
        self.resetsAt = resetsAt; self.windowSeconds = windowSeconds
    }
}

/// One row of Claude's weekly usage breakdown: Claude Code, chats, Cowork, other.
public struct UsageBreakdownRow: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let label: String
    public let percent: Double

    public init(id: String, label: String, percent: Double) {
        self.id = id; self.label = label; self.percent = percent
    }
}

/// Claude's dollar-denominated extra usage exactly as the provider reports it. `enabled` false with
/// `usedDollars` 0 is the normal state for an account that never turned extra usage on.
public struct ExtraUsageSpend: Sendable, Equatable, Codable {
    public let enabled: Bool
    public let usedDollars: Double
    public let limitDollars: Double?
    public let percent: Double?
    /// The provider's own reason when it reports one.
    public let disabledReason: String?

    public init(enabled: Bool, usedDollars: Double, limitDollars: Double? = nil,
                percent: Double? = nil, disabledReason: String? = nil) {
        self.enabled = enabled; self.usedDollars = usedDollars; self.limitDollars = limitDollars
        self.percent = percent; self.disabledReason = disabledReason
    }
}

/// Codex's on-demand rate-limit reset credits: each one clears the five-hour window when claimed.
public struct ResetCredits: Sendable, Equatable, Codable {
    public let available: Int
    /// Expiry of each still-available credit, soonest first.
    public let expiries: [Date]

    public init(available: Int, expiries: [Date] = []) {
        self.available = available; self.expiries = expiries
    }
}

public struct UsageSnapshot: Sendable, Equatable, Codable {
    public let provider: AIProvider
    /// The account the credential belongs to, when the credential or Claude's state file names it.
    public let accountEmail: String?
    public let plan: String?
    public let windows: [UsageWindow]
    /// Claude's extra usage, in dollars, when the payload carries it.
    public let extraUsage: ExtraUsageSpend?
    /// Codex flex credits remaining, and the same balance priced at Codex's own rate.
    public let creditsRemaining: Double?
    public let creditDollars: Double?
    /// Codex rate-limit reset credits.
    public let resetCredits: ResetCredits?
    /// Claude's split of the current weekly window across surfaces.
    public let breakdown: [UsageBreakdownRow]
    public let fetchedAt: Date
    /// A non-fatal note, such as serving the last good values while rate limited.
    public let notice: String?

    public init(provider: AIProvider, accountEmail: String?, plan: String?, windows: [UsageWindow],
                extraUsage: ExtraUsageSpend? = nil, creditsRemaining: Double? = nil, creditDollars: Double? = nil,
                resetCredits: ResetCredits? = nil, breakdown: [UsageBreakdownRow] = [],
                fetchedAt: Date, notice: String? = nil) {
        self.provider = provider; self.accountEmail = accountEmail; self.plan = plan; self.windows = windows
        self.extraUsage = extraUsage; self.creditsRemaining = creditsRemaining; self.creditDollars = creditDollars
        self.resetCredits = resetCredits; self.breakdown = breakdown
        self.fetchedAt = fetchedAt; self.notice = notice
    }

    public func window(_ id: String) -> UsageWindow? { windows.first { $0.id == id } }
}

/// Estimated spend reconstructed from the CLIs' own session logs and published model rates.
/// Never money charged: a subscription plan already covers this work.
public struct SpendSummary: Sendable, Equatable, Codable {
    public struct ModelTotal: Sendable, Equatable, Codable, Identifiable {
        public let id: String
        public let dollars: Double
        public let tokens: Int
        public init(id: String, dollars: Double, tokens: Int) { self.id = id; self.dollars = dollars; self.tokens = tokens }
    }

    public let provider: AIProvider
    public let today: Double
    public let last7Days: Double
    public let last30Days: Double
    public let tokensToday: Int
    public let tokens30Days: Int
    /// Biggest spenders first, for the board.
    public let topModels: [ModelTotal]
    /// Models whose tokens were counted but could not be priced; their tokens are excluded from the dollars.
    public let unpricedModels: [String]
    public let scannedAt: Date
    /// Set while a first or resumed scan is still running, so the UI can say the figure is partial.
    public let partial: Bool

    public init(provider: AIProvider, today: Double, last7Days: Double, last30Days: Double,
                tokensToday: Int, tokens30Days: Int, topModels: [ModelTotal] = [],
                unpricedModels: [String] = [], scannedAt: Date, partial: Bool = false) {
        self.provider = provider; self.today = today; self.last7Days = last7Days; self.last30Days = last30Days
        self.tokensToday = tokensToday; self.tokens30Days = tokens30Days; self.topModels = topModels
        self.unpricedModels = unpricedModels; self.scannedAt = scannedAt; self.partial = partial
    }
}

/// The seam between the log-scanning spend estimator and everything that displays it.
public protocol SpendEstimating: Sendable {
    /// A cached summary, refreshed on its own schedule. `force` re-scans changed files immediately.
    func summary(_ provider: AIProvider, force: Bool) async -> SpendSummary?
}

public enum UsageError: Error, Sendable, Equatable, LocalizedError {
    case notLoggedIn
    /// The login lacks the `user:profile` scope the usage endpoint requires (e.g. a setup-token login).
    case missingProfileScope
    /// The refresh token was rejected; only signing in again restores it.
    case sessionExpired
    case rateLimited(retryAfterSeconds: Int?)
    case requestFailed(status: Int)
    case connectionFailed
    case invalidResponse
    case keychainUnavailable(String)
    /// The live credential changed while a request was in flight; retry reads the new login.
    case credentialsChanged

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Not signed in."
        case .missingProfileScope: "This login cannot read usage. Sign in again with the CLI."
        case .sessionExpired: "Session expired. Sign in again with the CLI."
        case .rateLimited(let seconds): seconds.map { "Rate limited · retry in \(max(1, $0 / 60))m" } ?? "Rate limited · retrying later"
        case .requestFailed(let status): "Usage request failed (HTTP \(status))."
        case .connectionFailed: "Could not reach the usage service."
        case .invalidResponse: "The usage service returned an unexpected response."
        case .keychainUnavailable(let reason): "Keychain unavailable: \(reason)"
        case .credentialsChanged: "Login changed during refresh."
        }
    }
}

/// The seam between usage collection and account switching. `UsageService` implements it;
/// the accounts board and auto-switch consume it.
public protocol UsageFetching: Sendable {
    /// Usage for whichever account the CLI is using right now (the live keychain item or auth file).
    /// May rotate an expiring token and write it back to that live store.
    func activeUsage(_ provider: AIProvider, force: Bool) async -> Result<UsageSnapshot, UsageError>
    /// Usage for a switcher-saved copy. May rotate its token and write it back to that saved copy only.
    func savedUsage(_ provider: AIProvider, email: String, force: Bool) async -> Result<UsageSnapshot, UsageError>
    /// Forget cached results for a provider, e.g. right after a switch.
    func invalidate(_ provider: AIProvider) async
}

/// Serializes every credential mutation MenuSprite performs — token write-back and account
/// switching — so a refresh can never write into an item a switch just replaced. Writers outside
/// MenuSprite (Claude Code, Codex, Claude Switcher) are not covered: re-read and compare before writing.
public actor CredentialGate {
    public static let shared = CredentialGate()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        if held { await withCheckedContinuation { waiters.append($0) } } else { held = true }
        defer { handOff() }
        return try await body()
    }

    private func handOff() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
}

/// Where the live and saved credentials live. `standard` is the real Mac; `sandbox` isolates
/// tests and validation runs from every real login.
public struct AIAccountPaths: Sendable, Equatable {
    /// Claude Code's state file holding `oauthAccount` for the default config directory.
    public var claudeState: URL
    public var codexAuth: URL
    /// Claude Switcher's account list, shared so saved accounts keep working in both apps.
    public var switcherConfig: URL
    /// Claude Code's live keychain item for the default config directory.
    public var claudeLiveService: String
    /// The account attribute Claude Code reads and writes the live item with.
    public var keychainAccount: String
    public var savedClaudePrefix: String
    public var savedCodexPrefix: String

    public init(claudeState: URL, codexAuth: URL, switcherConfig: URL, claudeLiveService: String,
                keychainAccount: String, savedClaudePrefix: String, savedCodexPrefix: String) {
        self.claudeState = claudeState; self.codexAuth = codexAuth; self.switcherConfig = switcherConfig
        self.claudeLiveService = claudeLiveService; self.keychainAccount = keychainAccount
        self.savedClaudePrefix = savedClaudePrefix; self.savedCodexPrefix = savedCodexPrefix
    }

    public func savedService(_ provider: AIProvider, email: String) -> String {
        (provider == .claude ? savedClaudePrefix : savedCodexPrefix) + email
    }

    public static var standard: AIAccountPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return AIAccountPaths(
            claudeState: home.appendingPathComponent(".claude.json"),
            codexAuth: home.appendingPathComponent(".codex/auth.json"),
            switcherConfig: home.appendingPathComponent(".config/claude-switcher/accounts.json"),
            claudeLiveService: "Claude Code-credentials",
            keychainAccount: claudeCodeUserName(),
            savedClaudePrefix: "claude-switcher:",
            savedCodexPrefix: "codex-switcher:")
    }

    public static func sandbox(root: URL, keychainPrefix: String) -> AIAccountPaths {
        AIAccountPaths(
            claudeState: root.appendingPathComponent("claude.json"),
            codexAuth: root.appendingPathComponent("codex/auth.json"),
            switcherConfig: root.appendingPathComponent("claude-switcher/accounts.json"),
            claudeLiveService: "\(keychainPrefix)Claude Code-credentials",
            keychainAccount: claudeCodeUserName(),
            savedClaudePrefix: "\(keychainPrefix)claude-switcher:",
            savedCodexPrefix: "\(keychainPrefix)codex-switcher:")
    }

    /// Mirrors Claude Code: `$USER`, else the login name; unsafe names become `claude-code-user`.
    public static func claudeCodeUserName(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let name = environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
        return name.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil ? name : "claude-code-user"
    }

    /// Emails become keychain service names, so they must be plain addresses (the switcher's rule)
    /// and safe inside a quoted `security -i` argument.
    public static func isUsableEmail(_ email: String) -> Bool {
        email.count <= 254 && email.range(of: #"^[^@\s"\\]+@[^@\s"\\]+\.[^@\s"\\]+$"#, options: .regularExpression) != nil
    }
}
