import Foundation

public enum SwitchingError: Error, Sendable, Equatable, LocalizedError {
    case invalidEmail(String)
    case accountNotSaved(AIProvider, String)
    case savedCredentialMissing(AIProvider, String)
    case savedCredentialUnreadable(AIProvider, String)
    case liveLoginMissing(AIProvider)
    case liveLoginUnreadable(AIProvider)
    case liveIdentityUnknown(AIProvider)
    case liveIdentityUnconfirmed(String)
    case liveLoginExpired
    case activeAccountRemoval(AIProvider, String)
    case codexKeyringMode
    case codexSessionExpired(String)
    case cliNotFound(AIProvider)
    case configUnreadable(String)
    case stateFileUnreadable(String)
    case restoredAfterFailure(String)
    case restoreFailed(String)
    case file(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEmail(let email): "“\(email)” is not a usable account email."
        case .accountNotSaved(let provider, let email): "\(email) is not a saved \(provider.title) account."
        case .savedCredentialMissing(let provider, let email): "No saved \(provider.title) login for \(email). Sign in and save it again."
        case .savedCredentialUnreadable(let provider, let email): "The saved \(provider.title) login for \(email) is unreadable. Sign in and save it again."
        case .liveLoginMissing(let provider): "No signed-in \(provider.title) login to save."
        case .liveLoginUnreadable(let provider):
            provider == .claude
                ? "The live Claude Code keychain item is not a login MenuSprite can save, so nothing was changed."
                : "~/.codex/auth.json is not a ChatGPT login MenuSprite can save, so nothing was changed."
        case .liveIdentityUnknown(let provider):
            "Can't tell which \(provider.title) account is signed in, so its login can't be saved before switching. Sign in again, then use Save current login."
        case .liveIdentityUnconfirmed(let reason): "\(reason) Nothing was changed."
        case .liveLoginExpired: "The signed-in Claude login has expired. Use Add account… to sign in again."
        case .activeAccountRemoval(let provider, let email): "\(email) is the signed-in \(provider.title) account. Switch to another account before removing it."
        case .codexKeyringMode:
            #"Codex keyring credential storage is not supported yet. Set cli_auth_credentials_store = "file" in ~/.codex/config.toml and run codex login."#
        case .codexSessionExpired(let email): "The saved Codex session for \(email) expired. Use Add account… to sign in again."
        case .cliNotFound(let provider): provider == .claude ? "Claude Code (claude) was not found." : "Codex CLI (codex) was not found."
        case .configUnreadable(let reason): "Could not read Claude Switcher's accounts.json: \(reason)"
        case .stateFileUnreadable(let reason): "Could not read ~/.claude.json: \(reason)"
        case .restoredAfterFailure(let reason): "Switch failed and the previous login was restored: \(reason)"
        case .restoreFailed(let reason): "Switch failed and restoring the previous login also failed: \(reason)"
        case .file(let reason): reason
        }
    }
}

/// The login a CLI is using right now. Never carries a token.
public struct LiveLogin: Sendable, Equatable {
    public let provider: AIProvider
    /// From an identical saved copy, else Claude's state file or the Codex id token.
    public let email: String?
    public let plan: String?
    public let tokenFingerprint: String
}

public struct SwitchOutcome: Sendable, Equatable {
    public let provider: AIProvider
    public let email: String
    /// The target was already the live login; only its saved copy and flags were refreshed.
    public let alreadyActive: Bool
    /// The account the replaced live login was saved under.
    public let backedUpEmail: String?
    public let notes: [String]
}

public struct AccountsOverview: Sendable, Equatable {
    public var config: SwitcherConfig
    public var live: [AIProvider: LiveLogin]
    /// `SwitcherAccount.id`s whose saved keychain copy exists and parses.
    public var savedCredentials: Set<String>
    public var codexUsesKeyring: Bool
    public var problems: [String]

    public init(config: SwitcherConfig = SwitcherConfig(), live: [AIProvider: LiveLogin] = [:],
                savedCredentials: Set<String> = [], codexUsesKeyring: Bool = false, problems: [String] = []) {
        self.config = config; self.live = live; self.savedCredentials = savedCredentials
        self.codexUsesKeyring = codexUsesKeyring; self.problems = problems
    }

    public func liveEmail(_ provider: AIProvider) -> String? { live[provider]?.email }

    /// The live identity when known; the switcher's active flag only when a login exists but names no account.
    public func activeEmail(_ provider: AIProvider) -> String? {
        guard let login = live[provider] else { return nil }
        return login.email ?? config.active(provider)?.email
    }

    public func isLiveLoginSaved(_ provider: AIProvider) -> Bool {
        guard let email = liveEmail(provider), let account = config.account(provider, email: email) else { return false }
        return savedCredentials.contains(account.id)
    }
}

/// Claude Switcher–compatible switching. Saved copies live in `claude-switcher:<email>` /
/// `codex-switcher:<email>` and the list in `accounts.json`, so saved accounts work in both apps.
/// Every mutation runs inside the credential gate.
public struct AccountSwitcher: Sendable {
    public let paths: AIAccountPaths
    public let keychain: any KeychainStoring
    public let usage: (any UsageFetching)?
    /// Confirms the live Claude login's account with Anthropic before it is filed under an email.
    /// Without one the profile in `~/.claude.json` is trusted (tests and sandboxed runs).
    public let http: (any HTTPTransport)?
    let gate: CredentialGate

    public init(paths: AIAccountPaths = .standard, keychain: any KeychainStoring = SystemKeychain(),
                usage: (any UsageFetching)? = nil, http: (any HTTPTransport)? = nil, gate: CredentialGate = .shared) {
        self.paths = paths; self.keychain = keychain; self.usage = usage; self.http = http; self.gate = gate
    }

    // MARK: Reading

    public func loadConfig() throws -> SwitcherConfig { try SwitcherConfig.load(from: paths.switcherConfig) }

    /// Everything the accounts board shows, read without touching any credential.
    public func overview() -> AccountsOverview {
        var result = AccountsOverview()
        do { result.config = try loadConfig() } catch { result.problems.append(error.localizedDescription) }
        for account in result.config.accounts where savedCredential(account.provider, email: account.email) != nil {
            result.savedCredentials.insert(account.id)
        }
        for provider in AIProvider.allCases {
            do { result.live[provider] = try liveLogin(provider, config: result.config) } catch { result.problems.append(error.localizedDescription) }
        }
        result.codexUsesKeyring = codexUsesKeyring()
        return result
    }

    public func liveLogin(_ provider: AIProvider, config: SwitcherConfig? = nil) throws -> LiveLogin? {
        let config = try config ?? loadConfig()
        switch provider {
        case .claude:
            guard let raw = try readLiveClaude(), let credential = ClaudeCredential(json: raw) else { return nil }
            let state = try? ClaudeState.oauthAccountJSON(at: paths.claudeState)
            return LiveLogin(provider: .claude, email: claudeIdentity(of: credential, config: config, stateAccountJSON: state),
                             plan: credential.subscriptionType, tokenFingerprint: credential.tokenFingerprint)
        case .codex:
            guard let raw = try readLiveCodex(), let credential = CodexCredential(json: raw) else { return nil }
            return LiveLogin(provider: .codex, email: credential.email, plan: credential.plan, tokenFingerprint: credential.tokenFingerprint)
        }
    }

    /// Codex's `cli_auth_credentials_store = "keyring"` keeps the login out of `auth.json`, which the
    /// switcher cannot swap either.
    public func codexUsesKeyring() -> Bool {
        let url = paths.codexAuth.deletingLastPathComponent().appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { return false }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "cli_auth_credentials_store" {
                return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) == "keyring"
            }
        }
        return false
    }

    // MARK: Switching

    public func switchAccount(_ provider: AIProvider, to email: String) async throws -> SwitchOutcome {
        guard AIAccountPaths.isUsableEmail(email) else { throw SwitchingError.invalidEmail(email) }
        switch provider {
        case .claude:
            let identity = await confirmLiveClaudeIdentity()
            return try await gate.run { try self.switchClaude(to: email, identity: identity) }
        case .codex:
            guard !codexUsesKeyring() else { throw SwitchingError.codexKeyringMode }
            let config = try loadConfig()
            guard config.account(.codex, email: email) != nil else { throw SwitchingError.accountNotSaved(.codex, email) }
            guard savedCredential(.codex, email: email) != nil else { throw savedCopyError(.codex, email: email) }
            if (try? liveLogin(.codex, config: config))?.email != email, let usage {
                // Outside the gate on purpose: the usage service persists a rotated saved token under the
                // same (non-reentrant) gate.
                if case .failure(.sessionExpired) = await usage.savedUsage(.codex, email: email, force: true) {
                    throw SwitchingError.codexSessionExpired(email)
                }
            }
            return try await gate.run { try self.switchCodex(to: email) }
        }
    }

    func switchClaude(to email: String, identity: LiveClaudeIdentity? = nil) throws -> SwitchOutcome {
        var config = try loadConfig()
        guard let target = config.account(.claude, email: email) else { throw SwitchingError.accountNotSaved(.claude, email) }
        guard let targetRaw = try keychain.readPassword(service: paths.savedService(.claude, email: email), account: nil) else {
            throw SwitchingError.savedCredentialMissing(.claude, email)
        }
        guard let targetCredential = ClaudeCredential(json: targetRaw) else { throw SwitchingError.savedCredentialUnreadable(.claude, email) }
        let liveRaw = try readLiveClaude()
        let liveCredential = liveRaw.flatMap(ClaudeCredential.init(json:))
        if liveRaw != nil, liveCredential == nil { throw SwitchingError.liveLoginUnreadable(.claude) }
        let stateAccountJSON = try? ClaudeState.oauthAccountJSON(at: paths.claudeState)
        let stateEmail = stateAccountJSON.flatMap(ClaudeState.email(inOAuthAccount:))
        let owner = try liveCredential.map { try claudeOwner(of: $0, config: config, stateAccountJSON: stateAccountJSON, identity: identity) }
        let liveEmail: String? = if case .account(let account)? = owner { account } else { nil }
        var notes: [String] = []
        if owner == .expired { notes.append("The signed-in Claude login had expired, so it was not saved.") }

        if let liveCredential, liveEmail == email {
            // Already signed in. The live login may be newer than the saved copy, so refresh the copy instead.
            try writeSaved(.claude, email: email, account: savedAccountName(target), value: liveCredential.rawJSON)
            config.setActive(.claude, email: email)
            try config.save(to: paths.switcherConfig)
            return SwitchOutcome(provider: .claude, email: email, alreadyActive: true, backedUpEmail: email, notes: [])
        }

        var backedUp: String?
        if let liveCredential, owner != .expired {
            guard let ownerEmail = liveEmail ?? config.active(.claude)?.email else { throw SwitchingError.liveIdentityUnknown(.claude) }
            guard AIAccountPaths.isUsableEmail(ownerEmail) else { throw SwitchingError.invalidEmail(ownerEmail) }
            if case .verified(_, _)? = identity, let stateEmail, stateEmail != ownerEmail {
                notes.append("~/.claude.json still named \(stateEmail); Anthropic confirmed the signed-in login is \(ownerEmail).")
            }
            let existing = config.account(.claude, email: ownerEmail)
            var entry = existing ?? SwitcherAccount(
                email: ownerEmail, subscriptionType: liveCredential.subscriptionType ?? "unknown",
                orgName: (stateEmail == ownerEmail ? Self.organizationName(stateAccountJSON) : nil) ?? "",
                active: true, keychainAccount: paths.keychainAccount, provider: .claude)
            if existing == nil { notes.append("Saved the signed-in login \(ownerEmail) before switching.") }
            if stateEmail == ownerEmail, let stateAccountJSON { entry.oauthAccountJSON = stateAccountJSON }
            try writeSaved(.claude, email: ownerEmail, account: savedAccountName(entry), value: liveCredential.rawJSON)
            config.upsert(entry)
            try config.save(to: paths.switcherConfig)
            backedUp = ownerEmail
        }

        try keychain.writePassword(service: paths.claudeLiveService, account: paths.keychainAccount, value: targetCredential.rawJSON)
        do {
            if let profile = target.oauthAccountJSON {
                switch try ClaudeStateWriter.replaceOAuthAccount(with: profile, at: paths.claudeState) {
                case .replaced: break
                case .fileMissing: notes.append("~/.claude.json was not found, so the Claude profile was not updated.")
                case .unparsable: notes.append("~/.claude.json could not be parsed, so the Claude profile was not updated.")
                }
            } else {
                notes.append("No Claude profile is saved for \(email), so ~/.claude.json was left unchanged.")
            }
        } catch let stateError {
            do {
                if let liveRaw {
                    try keychain.writePassword(service: paths.claudeLiveService, account: paths.keychainAccount, value: liveRaw)
                } else {
                    try keychain.deleteAll(service: paths.claudeLiveService)
                }
            } catch let restoreError {
                throw SwitchingError.restoreFailed("\(stateError.localizedDescription) · \(restoreError.localizedDescription)")
            }
            throw SwitchingError.restoredAfterFailure(stateError.localizedDescription)
        }

        config.setActive(.claude, email: email)
        do { try config.save(to: paths.switcherConfig) } catch {
            notes.append("Switched, but accounts.json could not be updated: \(error.localizedDescription)")
        }
        return SwitchOutcome(provider: .claude, email: email, alreadyActive: false, backedUpEmail: backedUp, notes: notes)
    }

    func switchCodex(to email: String) throws -> SwitchOutcome {
        var config = try loadConfig()
        guard var target = config.account(.codex, email: email) else { throw SwitchingError.accountNotSaved(.codex, email) }
        guard let targetRaw = try keychain.readPassword(service: paths.savedService(.codex, email: email), account: nil) else {
            throw SwitchingError.savedCredentialMissing(.codex, email)
        }
        guard let targetCredential = CodexCredential(json: targetRaw) else { throw SwitchingError.savedCredentialUnreadable(.codex, email) }
        let liveRaw = try readLiveCodex()
        let liveCredential = liveRaw.flatMap(CodexCredential.init(json:))
        if let liveRaw, liveCredential == nil, !liveRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SwitchingError.liveLoginUnreadable(.codex)
        }
        var notes: [String] = []

        if let liveCredential, liveCredential.email == email {
            try writeSaved(.codex, email: email, account: savedAccountName(target), value: liveCredential.formatted(pretty: false))
            config.setActive(.codex, email: email)
            try config.save(to: paths.switcherConfig)
            return SwitchOutcome(provider: .codex, email: email, alreadyActive: true, backedUpEmail: email, notes: [])
        }

        var backedUp: String?
        if let liveCredential {
            guard let owner = liveCredential.email ?? config.active(.codex)?.email else { throw SwitchingError.liveIdentityUnknown(.codex) }
            guard AIAccountPaths.isUsableEmail(owner) else { throw SwitchingError.invalidEmail(owner) }
            let existing = config.account(.codex, email: owner)
            let entry = existing ?? SwitcherAccount(email: owner, subscriptionType: liveCredential.plan ?? "chatgpt", orgName: "",
                                                     active: true, keychainAccount: owner, provider: .codex)
            if existing == nil { notes.append("Saved the signed-in login \(owner) before switching.") }
            try writeSaved(.codex, email: owner, account: savedAccountName(entry), value: liveCredential.formatted(pretty: false))
            config.upsert(entry)
            try config.save(to: paths.switcherConfig)
            backedUp = owner
        }

        try AtomicFile.write(Data(targetCredential.formatted(pretty: true).utf8), to: paths.codexAuth, permissions: 0o600)
        if let plan = targetCredential.plan { target.subscriptionType = plan; config.upsert(target) }
        config.setActive(.codex, email: email)
        do { try config.save(to: paths.switcherConfig) } catch {
            notes.append("Switched, but accounts.json could not be updated: \(error.localizedDescription)")
        }
        return SwitchOutcome(provider: .codex, email: email, alreadyActive: false, backedUpEmail: backedUp, notes: notes)
    }

    // MARK: Saving, removing, settings

    /// Saves the live login as a switcher account and marks it active.
    @discardableResult
    public func saveCurrentLogin(_ provider: AIProvider) async throws -> SwitcherAccount {
        if provider == .codex, codexUsesKeyring() { throw SwitchingError.codexKeyringMode }
        let identity: LiveClaudeIdentity? = if provider == .claude { await confirmLiveClaudeIdentity() } else { nil }
        return try await gate.run { try self.importLiveLogin(provider, identity: identity) }
    }

    func importLiveLogin(_ provider: AIProvider, identity: LiveClaudeIdentity? = nil) throws -> SwitcherAccount {
        var config = try loadConfig()
        var account: SwitcherAccount
        switch provider {
        case .claude:
            guard let raw = try readLiveClaude() else { throw SwitchingError.liveLoginMissing(.claude) }
            guard let credential = ClaudeCredential(json: raw) else { throw SwitchingError.liveLoginUnreadable(.claude) }
            let state: String?
            do { state = try ClaudeState.oauthAccountJSON(at: paths.claudeState) } catch {
                throw SwitchingError.stateFileUnreadable(error.localizedDescription)
            }
            let email: String
            switch try claudeOwner(of: credential, config: config, stateAccountJSON: state, identity: identity) {
            case .account(let owner): email = owner
            case .expired: throw SwitchingError.liveLoginExpired
            case .unknown: throw SwitchingError.liveIdentityUnknown(.claude)
            }
            guard AIAccountPaths.isUsableEmail(email) else { throw SwitchingError.invalidEmail(email) }
            account = config.account(.claude, email: email) ?? SwitcherAccount(
                email: email, subscriptionType: "unknown", orgName: "", active: true,
                keychainAccount: paths.keychainAccount, provider: .claude)
            if let plan = credential.subscriptionType { account.subscriptionType = plan }
            if let state, ClaudeState.email(inOAuthAccount: state) == email {
                account.oauthAccountJSON = state
                if let organization = Self.organizationName(state) { account.orgName = organization }
            }
            try writeSaved(.claude, email: email, account: savedAccountName(account), value: credential.rawJSON)
        case .codex:
            guard let raw = try readLiveCodex() else { throw SwitchingError.liveLoginMissing(.codex) }
            guard let credential = CodexCredential(json: raw) else { throw SwitchingError.liveLoginUnreadable(.codex) }
            guard let email = credential.email else { throw SwitchingError.liveIdentityUnknown(.codex) }
            guard AIAccountPaths.isUsableEmail(email) else { throw SwitchingError.invalidEmail(email) }
            account = config.account(.codex, email: email) ?? SwitcherAccount(
                email: email, subscriptionType: "chatgpt", orgName: "", active: true, keychainAccount: email, provider: .codex)
            if let plan = credential.plan { account.subscriptionType = plan }
            try writeSaved(.codex, email: email, account: savedAccountName(account), value: credential.formatted(pretty: false))
        }
        config.upsert(account)
        config.setActive(provider, email: account.email)
        try config.save(to: paths.switcherConfig)
        return config.account(provider, email: account.email) ?? account
    }

    /// Deletes a saved account's keychain copy and list entry. The signed-in account cannot be removed.
    public func removeAccount(_ provider: AIProvider, email: String) async throws {
        try await gate.run {
            var config = try self.loadConfig()
            guard let account = config.account(provider, email: email) else { throw SwitchingError.accountNotSaved(provider, email) }
            let liveEmail = (try? self.liveLogin(provider, config: config))?.email
            guard !account.active, liveEmail != email else { throw SwitchingError.activeAccountRemoval(provider, email) }
            try self.keychain.deleteAll(service: self.paths.savedService(provider, email: email))
            config.remove(provider, email: email)
            try config.save(to: self.paths.switcherConfig)
        }
    }

    /// Writes the shared flag, so Claude Switcher sees the same setting.
    public func setAutoSwitch(_ provider: AIProvider, enabled: Bool) async throws {
        try await gate.run {
            var config = try self.loadConfig()
            config.autoSwitch[provider.rawValue] = enabled
            try config.save(to: self.paths.switcherConfig)
        }
    }

    // MARK: Adding an account

    /// Opens Terminal with the CLI's own sign-in. Nothing is logged out or deleted first; the CLI
    /// replaces the live login itself when sign-in completes. Returns the script to delete afterwards.
    public func launchSignIn(_ provider: AIProvider) throws -> URL {
        if provider == .codex, codexUsesKeyring() { throw SwitchingError.codexKeyringMode }
        guard let binary = Self.findExecutable(provider == .claude ? "claude" : "codex") else { throw SwitchingError.cliNotFound(provider) }
        let quoted = "'" + binary.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        let command = provider == .claude ? "\(quoted) auth login" : #"\#(quoted) login -c 'cli_auth_credentials_store="file"'"#
        let script = """
        #!/bin/zsh
        echo "MenuSprite — \(provider.title) sign-in"
        echo ""
        echo "Complete the sign-in in this window. MenuSprite saves the new account when it finishes."
        echo ""
        \(command)
        result=$?
        echo ""
        if [ $result -eq 0 ]; then
          echo "Sign-in finished. You can close this window."
        else
          echo "Sign-in failed or was cancelled. You can close this window."
        fi
        echo ""
        read -k 1 "?Press any key to close..."
        exit $result

        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("menusprite-\(provider.rawValue)-sign-in-\(UUID().uuidString).command")
        try Data(script.utf8).write(to: url, options: .atomic)
        guard chmod(url.path, 0o700) == 0 else { throw SwitchingError.file("Could not prepare the sign-in script.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SwitchingError.file("Could not open Terminal for sign-in.") }
        return url
    }

    /// Polls the live store until the CLI writes a different login, then saves it.
    /// Returns nil when the timeout passes without a new login. Honors task cancellation.
    public func waitForSignIn(_ provider: AIProvider, replacing previous: LiveLogin?, timeout: TimeInterval = 300,
                              interval: Duration = .seconds(2)) async throws -> SwitcherAccount? {
        let start = Date()
        var changedAt: Date?
        while Date().timeIntervalSince(start) < timeout {
            try await Task.sleep(for: interval)
            guard let login = try? liveLogin(provider), login.tokenFingerprint != previous?.tokenFingerprint, login.email != nil else { continue }
            if provider == .claude, let previousEmail = previous?.email, login.email == previousEmail {
                // Claude Code writes the keychain before ~/.claude.json. Give the profile time to follow
                // before treating this as a fresh sign-in to the same account.
                let first = changedAt ?? Date()
                changedAt = first
                if Date().timeIntervalSince(first) < 10 { continue }
            }
            return try await saveCurrentLogin(provider)
        }
        return nil
    }

    // MARK: Helpers

    func readLiveClaude() throws -> String? {
        try keychain.readCLIOwnedPassword(service: paths.claudeLiveService, account: paths.keychainAccount)
    }

    func readLiveCodex() throws -> String? {
        guard FileManager.default.fileExists(atPath: paths.codexAuth.path) else { return nil }
        do { return try String(contentsOf: paths.codexAuth, encoding: .utf8) } catch {
            throw SwitchingError.file("Could not read ~/.codex/auth.json: \(error.localizedDescription)")
        }
    }

    /// The saved copy's text when it exists and parses.
    func savedCredential(_ provider: AIProvider, email: String) -> String? {
        guard let raw = try? keychain.readPassword(service: paths.savedService(provider, email: email), account: nil) else { return nil }
        switch provider {
        case .claude: return ClaudeCredential(json: raw) == nil ? nil : raw
        case .codex: return CodexCredential(json: raw) == nil ? nil : raw
        }
    }

    private func savedCopyError(_ provider: AIProvider, email: String) -> SwitchingError {
        (try? keychain.readPassword(service: paths.savedService(provider, email: email), account: nil)) == nil
            ? .savedCredentialMissing(provider, email) : .savedCredentialUnreadable(provider, email)
    }

    /// A Claude login is identified by an identical saved copy first (exact tokens), then by the state
    /// file's profile. After Claude Code rotates tokens only the profile still names the account.
    /// Best guess for display. Filing a login under an email goes through `claudeOwner` instead.
    func claudeIdentity(of live: ClaudeCredential, config: SwitcherConfig, stateAccountJSON: String?) -> String? {
        exactSavedOwner(of: live, config: config) ?? VerifiedClaudeLogins.shared.email(forFingerprint: live.tokenFingerprint)
            ?? stateAccountJSON.flatMap(ClaudeState.email(inOAuthAccount:))
    }

    enum ClaudeOwner: Sendable, Equatable { case account(String), expired, unknown }

    /// Who the live login belongs to before it is filed under an email: an identical saved copy first;
    /// then Anthropic's answer when a verifier is configured, never falling back to a guess; the state
    /// file only when no verifier is configured.
    func claudeOwner(of live: ClaudeCredential, config: SwitcherConfig, stateAccountJSON: String?,
                     identity: LiveClaudeIdentity?) throws -> ClaudeOwner {
        if let email = exactSavedOwner(of: live, config: config) { return .account(email) }
        guard http != nil else {
            return stateAccountJSON.flatMap(ClaudeState.email(inOAuthAccount:)).map(ClaudeOwner.account) ?? .unknown
        }
        switch identity {
        case .verified(let fingerprint, let email)? where fingerprint == live.tokenFingerprint: return .account(email)
        case .expired(let fingerprint)? where fingerprint == live.tokenFingerprint: return .expired
        case .unconfirmed(let reason)?: throw SwitchingError.liveIdentityUnconfirmed(reason)
        default: throw SwitchingError.liveIdentityUnconfirmed("The signed-in Claude login changed while it was being checked. Try again.")
        }
    }

    private func exactSavedOwner(of live: ClaudeCredential, config: SwitcherConfig) -> String? {
        config.accounts(for: .claude).first { account in
            guard let raw = try? keychain.readPassword(service: paths.savedService(.claude, email: account.email), account: nil) else { return false }
            return ClaudeCredential(json: raw)?.tokenFingerprint == live.tokenFingerprint
        }?.email
    }

    /// Saved copies are replaced by delete-then-add: the switcher reads them by service only, so a
    /// duplicate under another account name would shadow the new copy.
    func writeSaved(_ provider: AIProvider, email: String, account: String, value: String) throws {
        let service = paths.savedService(provider, email: email)
        try keychain.deleteAll(service: service)
        try keychain.writePassword(service: service, account: account, value: value)
    }

    func savedAccountName(_ account: SwitcherAccount) -> String {
        if !account.keychainAccount.isEmpty { return account.keychainAccount }
        return account.provider == .claude ? paths.keychainAccount : account.email
    }

    static func organizationName(_ accountJSON: String?) -> String? {
        accountJSON.flatMap(CredentialJSON.object(from:)).flatMap { CredentialJSON.nonEmpty($0["organizationName"]) }
    }

    static func findExecutable(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let searchPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in searchPath + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
