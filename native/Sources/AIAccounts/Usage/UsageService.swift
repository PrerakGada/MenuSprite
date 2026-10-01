import Foundation

/// How long a fetched usage snapshot stays fresh before the next request goes to the provider. Chosen
/// in the AI Accounts board; the menu-bar readings and the board both follow it. Shorter than five
/// minutes is Prerak's call, not OpenUsage's: a provider that answers 429 puts the account in a
/// cooldown and the last good values are shown with a notice meanwhile.
///
/// **Auto** (the default, saved as 0) lets `UsageAutoPacer` decide: two minutes while usage is moving,
/// backing off towards an hour while nothing changes, a minute when the 5-hour session is nearly full.
public enum UsageRefreshInterval {
    public static let key = "MenuSprite.AIUsageRefreshSeconds"
    /// The saved value that means "Auto".
    public static let auto: TimeInterval = 0
    public static let options: [TimeInterval] = [60, 120, 300, 600, 900, 1800]
    /// Everything the board offers, Auto first.
    public static let choices: [TimeInterval] = [auto] + options
    public static let standard: TimeInterval = 300

    public static var current: TimeInterval {
        get {
            guard let saved = UserDefaults.standard.object(forKey: key) as? Double else { return auto }
            return options.contains(saved) ? saved : auto
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Fetches Claude and Codex limits from the providers' own usage endpoints, the way OpenUsage does.
/// Results are cached per login for the chosen refresh interval (five minutes unless changed); a changed login (a switch, or the CLI rotating its
/// token) is noticed on the next call and fetched at once. Tokens never leave this actor except in
/// request headers and verified write-backs.
///
/// **The live login is read-only.** The token the Claude Code and Codex CLIs are signed in with is never
/// refreshed and never written back from here: a refresh token is single-use, so a refresh whose
/// write-back fails (a keychain that would prompt, a concurrent CLI rewrite) leaves the CLI holding a
/// dead one and signs it out, and a keychain item recreated by MenuSprite is locked to MenuSprite's team
/// and makes every other tool prompt. An expired live token is reported as `awaitingCLIRenewal` and the
/// board keeps its last figures until the CLI renews it. Only switcher-saved copies of accounts the CLI
/// is not using are rotated, and only into their own saved copy.
public actor UsageService: UsageFetching {
    public static let shared = UsageService(refreshInterval: { UsageRefreshInterval.current }, verifiesLiveIdentity: true)

    /// OpenUsage's cadence, the default when no interval has been chosen.
    public static let freshness: TimeInterval = UsageRefreshInterval.standard
    /// Rotate a token this close to expiry — the CLIs' own slack.
    static let refreshWindow: TimeInterval = 300
    static let rateLimitCooldown: TimeInterval = 300
    /// A request that never reached the server can be retried before the freshness interval.
    static let connectionRetry: TimeInterval = 60
    /// How long the token-to-account match for the live login is reused before the saved copies are read again.
    static let liveOwnerLifetime: TimeInterval = 60

    enum Source: Hashable, Sendable {
        case live
        case saved(String)

        var savedEmail: String? {
            if case .saved(let email) = self { return email }
            return nil
        }

        /// The CLI's own login: read, never refreshed, never written.
        var isLive: Bool {
            if case .live = self { return true }
            return false
        }
    }

    private struct Key: Hashable, Sendable {
        let provider: AIProvider
        let source: Source
    }

    private struct CooldownKey: Hashable, Sendable {
        let provider: AIProvider
        let identity: String
    }

    private struct Entry {
        /// Fingerprint of the token pair the store held when this result was produced.
        let fingerprint: String
        /// The account behind it, so last-good values are never shown for a different account.
        let identity: String
        let result: Result<UsageSnapshot, UsageError>
        let attemptedAt: Date
        let validFor: TimeInterval
        /// Ordinary results follow the chosen refresh interval, read at lookup so a change applies at
        /// once; rate-limit cooldowns and connection retries keep their own fixed length.
        let followsRefreshInterval: Bool
        /// What Auto decided for this result; used only while the chosen interval is Auto.
        let autoInterval: TimeInterval?
        let lastGood: UsageSnapshot?
    }

    private enum PersistOutcome: Sendable { case written, storeChanged, failed }

    private let paths: AIAccountPaths
    private let keychain: any KeychainStoring
    private let http: any HTTPTransport
    private let now: @Sendable () -> Date
    private let refreshInterval: @Sendable () -> TimeInterval
    /// Ask Anthropic which account the live Claude login is when no saved copy matches it. Off in tests
    /// and sandboxed runs, where the state file is trusted.
    private let verifiesLiveIdentity: Bool
    private let verifiedLogins: VerifiedClaudeLogins
    private var entries: [Key: Entry] = [:]
    private var cooldowns: [CooldownKey: Date] = [:]
    private var pacers: [Key: UsageAutoPacer] = [:]
    private var liveOwner: (fingerprint: String, email: String?, at: Date)?
    private var inFlight: [Key: Task<Result<UsageSnapshot, UsageError>, Never>] = [:]
    private var claudeStateStamp: (modified: Date, size: Int, email: String?)?

    public init(paths: AIAccountPaths = .standard, keychain: any KeychainStoring = SystemKeychain(),
                http: any HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = Date.init,
                refreshInterval: @escaping @Sendable () -> TimeInterval = { UsageService.freshness },
                verifiesLiveIdentity: Bool = false, verifiedLogins: VerifiedClaudeLogins = .shared) {
        self.verifiesLiveIdentity = verifiesLiveIdentity
        self.verifiedLogins = verifiedLogins
        self.paths = paths
        self.keychain = keychain
        self.http = http
        self.now = now
        self.refreshInterval = refreshInterval
    }

    public func activeUsage(_ provider: AIProvider, force: Bool) async -> Result<UsageSnapshot, UsageError> {
        await coalesced(Key(provider: provider, source: .live), force: force)
    }

    public func savedUsage(_ provider: AIProvider, email: String, force: Bool) async -> Result<UsageSnapshot, UsageError> {
        guard AIAccountPaths.isUsableEmail(email) else { return .failure(.notLoggedIn) }
        // The saved copy of the account the CLI is using now can hold a refresh token the CLI has
        // since rotated; spending it could revoke the live session. Read the live login instead.
        if let live = await liveEmail(provider), live.caseInsensitiveCompare(email) == .orderedSame {
            return await activeUsage(provider, force: force)
        }
        return await coalesced(Key(provider: provider, source: .saved(email)), force: force)
    }

    public func invalidate(_ provider: AIProvider) {
        entries = entries.filter { $0.key.provider != provider }
    }

    // MARK: - Flow

    private func coalesced(_ key: Key, force: Bool) async -> Result<UsageSnapshot, UsageError> {
        if let running = inFlight[key] { return await running.value }
        // Unstructured on purpose: a caller's cancellation must not record a half-finished fetch as a failure.
        let task = Task { await self.load(key, force: force, reloadsRemaining: 1) }
        inFlight[key] = task
        let result = await task.value
        if inFlight[key] == task { inFlight[key] = nil }
        return result
    }

    private func load(_ key: Key, force: Bool, reloadsRemaining: Int) async -> Result<UsageSnapshot, UsageError> {
        switch key.provider {
        case .claude: return await loadClaude(key, force: force, reloadsRemaining: reloadsRemaining)
        case .codex: return await loadCodex(key, force: force, reloadsRemaining: reloadsRemaining)
        }
    }

    private func loadClaude(_ key: Key, force: Bool, reloadsRemaining: Int) async -> Result<UsageSnapshot, UsageError> {
        let credential: ClaudeCredential
        do {
            guard let found = try Self.readClaude(key.source, paths: paths, keychain: keychain) else { return .failure(.notLoggedIn) }
            credential = found
        } catch {
            return .failure(.keychainUnavailable(error.localizedDescription))
        }
        let email = if let saved = key.source.savedEmail { saved } else { await claudeLiveEmail(for: credential) }
        let identity = email?.lowercased() ?? credential.tokenFingerprint
        if let cached = cachedResult(key, fingerprint: credential.tokenFingerprint, force: force) { return cached }
        if let blocked = cooldownResult(key, identity: identity) { return blocked }
        guard credential.canReadUsage else { return .failure(.missingProfileScope) }

        var working = credential
        var storedFingerprint = credential.tokenFingerprint
        do {
            if key.source.isLive {
                if working.expires(within: 0, now: now()) { throw UsageError.awaitingCLIRenewal }
            } else if working.expires(within: Self.refreshWindow, now: now()), let refreshToken = working.refreshToken {
                let refreshed = try await refreshClaude(working, refreshToken: refreshToken, source: key.source)
                working = refreshed.credential
                if refreshed.persisted { storedFingerprint = working.tokenFingerprint }
            }
            var response = try await send(ClaudeUsageAPI.usageRequest(accessToken: working.accessToken))
            if Self.isAuthFailure(response) {
                guard !key.source.isLive else { throw UsageError.awaitingCLIRenewal }
                guard let refreshToken = working.refreshToken else { throw UsageError.sessionExpired }
                let refreshed = try await refreshClaude(working, refreshToken: refreshToken, source: key.source)
                working = refreshed.credential
                if refreshed.persisted { storedFingerprint = working.tokenFingerprint }
                response = try await send(ClaudeUsageAPI.usageRequest(accessToken: working.accessToken))
                if Self.isAuthFailure(response) { throw UsageError.sessionExpired }
            }
            if response.statusCode == 429 {
                return rateLimited(key, fingerprint: storedFingerprint, identity: identity, response: response)
            }
            guard response.isSuccess else { throw UsageError.requestFailed(status: response.statusCode) }
            let snapshot = try ClaudeUsageAPI.snapshot(from: response, credential: working, email: email, now: now())
            return remember(key, fingerprint: storedFingerprint, identity: identity, result: .success(snapshot))
        } catch UsageError.credentialsChanged where reloadsRemaining > 0 {
            return await loadClaude(key, force: true, reloadsRemaining: reloadsRemaining - 1)
        } catch {
            return failed(key, fingerprint: storedFingerprint, identity: identity, error: error as? UsageError ?? .invalidResponse)
        }
    }

    private func loadCodex(_ key: Key, force: Bool, reloadsRemaining: Int) async -> Result<UsageSnapshot, UsageError> {
        let credential: CodexCredential
        do {
            guard let found = try Self.readCodex(key.source, paths: paths, keychain: keychain) else { return .failure(.notLoggedIn) }
            credential = found
        } catch {
            return .failure(.keychainUnavailable(error.localizedDescription))
        }
        let identity = credential.accountID?.lowercased() ?? credential.email?.lowercased()
            ?? key.source.savedEmail?.lowercased() ?? credential.tokenFingerprint
        if let cached = cachedResult(key, fingerprint: credential.tokenFingerprint, force: force) { return cached }
        if let blocked = cooldownResult(key, identity: identity) { return blocked }

        var working = credential
        var storedFingerprint = credential.tokenFingerprint
        do {
            if working.expires(within: Self.refreshWindow, now: now()),
               let reread = try? Self.readCodex(key.source, paths: paths, keychain: keychain),
               reread.tokenFingerprint != working.tokenFingerprint {
                // The CLI rotated the token after it was read: adopt it rather than spend a used refresh token.
                working = reread
                storedFingerprint = reread.tokenFingerprint
            }
            if key.source.isLive {
                if working.expires(within: 0, now: now()) { throw UsageError.awaitingCLIRenewal }
            } else if working.expires(within: Self.refreshWindow, now: now()), let refreshToken = working.refreshToken {
                let refreshed = try await refreshCodex(working, refreshToken: refreshToken, source: key.source)
                working = refreshed.credential
                if refreshed.persisted { storedFingerprint = working.tokenFingerprint }
            }
            var response = try await send(CodexUsageAPI.usageRequest(accessToken: working.accessToken, accountID: working.accountID))
            if Self.isAuthFailure(response) {
                guard !key.source.isLive else { throw UsageError.awaitingCLIRenewal }
                guard let refreshToken = working.refreshToken else { throw UsageError.sessionExpired }
                let refreshed = try await refreshCodex(working, refreshToken: refreshToken, source: key.source)
                working = refreshed.credential
                if refreshed.persisted { storedFingerprint = working.tokenFingerprint }
                response = try await send(CodexUsageAPI.usageRequest(accessToken: working.accessToken, accountID: working.accountID))
                if Self.isAuthFailure(response) { throw UsageError.sessionExpired }
            }
            if response.statusCode == 429 {
                return rateLimited(key, fingerprint: storedFingerprint, identity: identity, response: response)
            }
            guard response.isSuccess else { throw UsageError.requestFailed(status: response.statusCode) }
            // Only worth a second request when the account actually holds reset credits: that endpoint's
            // only extra information is each credit's expiry. Best effort — it never fails the refresh.
            var resetCredits: HTTPResponse?
            if let count = CodexUsageAPI.embeddedResetCreditCount(response), count > 0 {
                resetCredits = try? await send(CodexUsageAPI.resetCreditsRequest(accessToken: working.accessToken,
                                                                                accountID: working.accountID))
            }
            let snapshot = try CodexUsageAPI.snapshot(from: response, credential: working, fallbackEmail: key.source.savedEmail,
                                                      resetCredits: resetCredits, now: now())
            return remember(key, fingerprint: storedFingerprint, identity: identity, result: .success(snapshot))
        } catch UsageError.credentialsChanged where reloadsRemaining > 0 {
            return await loadCodex(key, force: true, reloadsRemaining: reloadsRemaining - 1)
        } catch {
            return failed(key, fingerprint: storedFingerprint, identity: identity, error: error as? UsageError ?? .invalidResponse)
        }
    }

    // MARK: - Token rotation

    private func refreshClaude(_ credential: ClaudeCredential, refreshToken: String, source: Source) async throws -> (credential: ClaudeCredential, persisted: Bool) {
        let response = try await send(ClaudeUsageAPI.refreshRequest(refreshToken: refreshToken))
        let tokens: ClaudeTokenResponse
        do {
            tokens = try ClaudeUsageAPI.parseRefresh(response)
        } catch UsageError.sessionExpired where storeMoved(.claude, source: source, from: credential.tokenFingerprint) {
            // Claude Code or OpenUsage rotated this login first and spent the refresh token read here.
            throw UsageError.credentialsChanged
        }
        guard let rotated = credential.rotated(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
                                               expiresInSeconds: tokens.expiresIn, now: now()) else { throw UsageError.invalidResponse }
        let persisted = try await persist(.claude, source: source, rawJSON: rotated.rawJSON, replacing: credential.tokenFingerprint)
        return (rotated, persisted)
    }

    private func refreshCodex(_ credential: CodexCredential, refreshToken: String, source: Source) async throws -> (credential: CodexCredential, persisted: Bool) {
        let response = try await send(CodexUsageAPI.refreshRequest(refreshToken: refreshToken))
        let tokens: CodexTokenResponse
        do {
            tokens = try CodexUsageAPI.parseRefresh(response)
        } catch UsageError.sessionExpired where storeMoved(.codex, source: source, from: credential.tokenFingerprint) {
            // The Codex CLI or OpenUsage rotated this login first and spent the refresh token read here.
            throw UsageError.credentialsChanged
        }
        guard let rotated = credential.rotated(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
                                               idToken: tokens.idToken, now: now()) else { throw UsageError.invalidResponse }
        let persisted = try await persist(.codex, source: source, rawJSON: rotated.rawJSON, replacing: credential.tokenFingerprint)
        return (rotated, persisted)
    }

    /// Writes a rotated pair back to the store it came from, only while that store still holds the pair
    /// that was refreshed. A concurrent change throws `credentialsChanged` so the caller reloads; any
    /// other write failure returns false and the refreshed token still serves this request.
    private func persist(_ provider: AIProvider, source: Source, rawJSON: String, replacing expected: String) async throws -> Bool {
        let paths = self.paths
        let keychain = self.keychain
        let outcome = try await CredentialGate.shared.run {
            Self.writeBack(provider, source: source, rawJSON: rawJSON, replacing: expected, paths: paths, keychain: keychain)
        }
        switch outcome {
        case .written: return true
        case .failed: return false
        case .storeChanged: throw UsageError.credentialsChanged
        }
    }

    private static func writeBack(_ provider: AIProvider, source: Source, rawJSON: String, replacing expected: String,
                                  paths: AIAccountPaths, keychain: any KeychainStoring) -> PersistOutcome {
        do {
            switch provider {
            case .claude:
                guard try readClaude(source, paths: paths, keychain: keychain)?.tokenFingerprint == expected else { return .storeChanged }
                switch source {
                case .live:
                    return .failed // the CLI owns the live login
                case .saved(let email):
                    let service = paths.savedService(.claude, email: email)
                    let account = try keychain.accountName(service: service) ?? paths.keychainAccount
                    try keychain.writePassword(service: service, account: account, value: rawJSON)
                }
            case .codex:
                guard try readCodex(source, paths: paths, keychain: keychain)?.tokenFingerprint == expected else { return .storeChanged }
                switch source {
                case .live:
                    return .failed // the CLI owns the live login
                case .saved(let email):
                    let service = paths.savedService(.codex, email: email)
                    let account = try keychain.accountName(service: service) ?? email
                    try keychain.writePassword(service: service, account: account, value: rawJSON)
                }
            }
            return .written
        } catch {
            return .failed
        }
    }

    /// Whether the store now holds a different token pair than the one a refresh started from. Other
    /// clients refresh the same live login, so a rejected refresh is only a dead session if nothing moved.
    private func storeMoved(_ provider: AIProvider, source: Source, from fingerprint: String) -> Bool {
        switch provider {
        case .claude: (try? Self.readClaude(source, paths: paths, keychain: keychain))?.tokenFingerprint != fingerprint
        case .codex: (try? Self.readCodex(source, paths: paths, keychain: keychain))?.tokenFingerprint != fingerprint
        }
    }

    // MARK: - Stores

    private static func readClaude(_ source: Source, paths: AIAccountPaths, keychain: any KeychainStoring) throws -> ClaudeCredential? {
        let text: String?
        switch source {
        case .live:
            if let exact = try keychain.readCLIOwnedPassword(service: paths.claudeLiveService, account: paths.keychainAccount) {
                text = exact
            } else {
                text = try keychain.readCLIOwnedPassword(service: paths.claudeLiveService, account: nil)
            }
        case .saved(let email):
            text = try keychain.readPassword(service: paths.savedService(.claude, email: email), account: nil)
        }
        return text.flatMap(ClaudeCredential.init(json:))
    }

    private static func readCodex(_ source: Source, paths: AIAccountPaths, keychain: any KeychainStoring) throws -> CodexCredential? {
        switch source {
        case .live:
            let text: String
            do {
                text = try String(contentsOf: paths.codexAuth, encoding: .utf8)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return nil
            }
            return CodexCredential(json: text)
        case .saved(let email):
            return try keychain.readPassword(service: paths.savedService(.codex, email: email), account: nil)
                .flatMap(CodexCredential.init(json:))
        }
    }

    private func liveEmail(_ provider: AIProvider) async -> String? {
        switch provider {
        case .claude: return await claudeLiveEmail(for: (try? Self.readClaude(.live, paths: paths, keychain: keychain)) ?? nil)
        case .codex: return (try? Self.readCodex(.live, paths: paths, keychain: keychain))?.email
        }
    }

    /// Whose login the Claude CLI holds. An identical saved copy names it exactly, the rule the account
    /// switcher uses. Once Claude Code has rotated its tokens no copy matches, and then Anthropic's own
    /// answer decides. `~/.claude.json` is the last resort: the Claude desktop app writes its own account
    /// there, so it can name a different account than the CLI's keychain login, and then both rows of the
    /// board would read the same login's usage.
    private func claudeLiveEmail(for credential: ClaudeCredential?) async -> String? {
        guard let credential else { return claudeStateEmail() }
        let fingerprint = credential.tokenFingerprint
        if let owner = liveOwner, owner.fingerprint == fingerprint,
           now().timeIntervalSince(owner.at) < Self.liveOwnerLifetime {
            return owner.email ?? claudeStateEmail()
        }
        var resolved = (try? SwitcherConfig.load(from: paths.switcherConfig))?.accounts(for: .claude).first { account in
            guard let raw = try? keychain.readPassword(service: paths.savedService(.claude, email: account.email), account: nil) else { return false }
            return ClaudeCredential(json: raw)?.tokenFingerprint == fingerprint
        }?.email
        if resolved == nil { resolved = verifiedLogins.email(forFingerprint: fingerprint) }
        if resolved == nil, verifiesLiveIdentity, case .email(let email) = await ClaudeProfileAPI.answer(credential, http: http) {
            verifiedLogins.remember(email, forFingerprint: fingerprint)
            resolved = email
        }
        liveOwner = (fingerprint, resolved, now())
        return resolved ?? claudeStateEmail()
    }

    /// Claude Code rewrites its 200+ KB state file often; parse it only when it actually changed.
    private func claudeStateEmail() -> String? {
        let url = paths.claudeState
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.intValue else { return nil }
        if let stamp = claudeStateStamp, stamp.modified == modified, stamp.size == size { return stamp.email }
        let email = (try? ClaudeState.oauthAccountJSON(at: url)).flatMap(ClaudeState.email(inOAuthAccount:))
        claudeStateStamp = (modified, size, email)
        return email
    }

    // MARK: - Cache

    private func cachedResult(_ key: Key, fingerprint: String, force: Bool) -> Result<UsageSnapshot, UsageError>? {
        guard !force, let entry = entries[key], entry.fingerprint == fingerprint,
              now().timeIntervalSince(entry.attemptedAt) < lifetime(of: entry)
        else { return nil }
        return entry.result
    }

    /// How long an entry may be served: its own length for cooldowns and retries, otherwise the chosen
    /// interval, or what Auto decided when the choice is Auto.
    private func lifetime(of entry: Entry) -> TimeInterval {
        guard entry.followsRefreshInterval else { return entry.validFor }
        let chosen = refreshInterval()
        return chosen > 0 ? chosen : (entry.autoInterval ?? Self.freshness)
    }

    /// When the earliest cached figure goes stale, so the open board can ask again at that moment.
    public func nextRefreshDate() async -> Date? {
        entries.values.map { $0.attemptedAt.addingTimeInterval(lifetime(of: $0)) }.min()
    }

    /// ⌘R: Auto starts its ladder again from the shortest wait.
    public func restartAutoPacing() async {
        for key in Array(pacers.keys) { pacers[key]?.restart() }
    }

    private func cooldownResult(_ key: Key, identity: String) -> Result<UsageSnapshot, UsageError>? {
        let cooldownKey = CooldownKey(provider: key.provider, identity: identity)
        guard let until = cooldowns[cooldownKey] else { return nil }
        let remaining = Int(until.timeIntervalSince(now()).rounded(.up))
        guard remaining > 0 else {
            cooldowns[cooldownKey] = nil
            return nil
        }
        return lastGood(key, identity: identity, notice: Self.rateLimitNotice(remaining))
            ?? .failure(.rateLimited(retryAfterSeconds: remaining))
    }

    private func rateLimited(_ key: Key, fingerprint: String, identity: String, response: HTTPResponse) -> Result<UsageSnapshot, UsageError> {
        let retryAfter = UsageParse.retryAfterSeconds(response, now: now())
        let cooldown = retryAfter.map { TimeInterval($0) } ?? Self.rateLimitCooldown
        cooldowns[CooldownKey(provider: key.provider, identity: identity)] = now().addingTimeInterval(cooldown)
        let result = lastGood(key, identity: identity, notice: Self.rateLimitNotice(retryAfter))
            ?? .failure(.rateLimited(retryAfterSeconds: retryAfter))
        store(key, fingerprint: fingerprint, identity: identity, result: result, validFor: max(1, cooldown),
              followsRefreshInterval: false, lastGood: previousGood(key, identity: identity))
        return result
    }

    private func remember(_ key: Key, fingerprint: String, identity: String, result: Result<UsageSnapshot, UsageError>) -> Result<UsageSnapshot, UsageError> {
        var good = previousGood(key, identity: identity)
        var auto: TimeInterval?
        if case .success(let snapshot) = result {
            good = snapshot
            cooldowns[CooldownKey(provider: key.provider, identity: identity)] = nil
            var pacer = pacers[key] ?? UsageAutoPacer()
            auto = pacer.observe(snapshot, now: now())
            pacers[key] = pacer
        }
        store(key, fingerprint: fingerprint, identity: identity, result: result, validFor: Self.freshness,
              followsRefreshInterval: true, autoInterval: auto, lastGood: good)
        return result
    }

    /// Like OpenUsage, a failed refresh never wipes good values: transient failures keep serving the
    /// last snapshot for the same account with a notice. Login problems are reported as they are.
    private func failed(_ key: Key, fingerprint: String, identity: String, error: UsageError) -> Result<UsageSnapshot, UsageError> {
        let transient: Bool
        switch error {
        case .connectionFailed, .requestFailed, .invalidResponse, .awaitingCLIRenewal: transient = true
        default: transient = false
        }
        let result = (transient ? lastGood(key, identity: identity, notice: "Couldn't refresh · \(error.localizedDescription)") : nil)
            ?? .failure(error)
        store(key, fingerprint: fingerprint, identity: identity, result: result,
              validFor: error == .connectionFailed ? Self.connectionRetry : Self.freshness,
              followsRefreshInterval: error != .connectionFailed, lastGood: previousGood(key, identity: identity))
        return result
    }

    private func previousGood(_ key: Key, identity: String) -> UsageSnapshot? {
        guard let entry = entries[key], entry.identity == identity else { return nil }
        return entry.lastGood
    }

    private func lastGood(_ key: Key, identity: String, notice: String) -> Result<UsageSnapshot, UsageError>? {
        previousGood(key, identity: identity).map { .success($0.withNotice(notice)) }
    }

    private func store(_ key: Key, fingerprint: String, identity: String, result: Result<UsageSnapshot, UsageError>,
                       validFor: TimeInterval, followsRefreshInterval: Bool, autoInterval: TimeInterval? = nil,
                       lastGood: UsageSnapshot?) {
        entries[key] = Entry(fingerprint: fingerprint, identity: identity, result: result, attemptedAt: now(),
                             validFor: validFor, followsRefreshInterval: followsRefreshInterval,
                             autoInterval: autoInterval, lastGood: lastGood)
    }

    private func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        do { return try await http.send(request) } catch { throw UsageError.connectionFailed }
    }

    private static func isAuthFailure(_ response: HTTPResponse) -> Bool {
        response.statusCode == 401 || response.statusCode == 403
    }

    static func rateLimitNotice(_ seconds: Int?) -> String {
        guard let seconds else { return "Rate limited · showing last values" }
        return "Rate limited · retry in ~\(max(1, Int((Double(seconds) / 60).rounded(.up))))m"
    }
}
