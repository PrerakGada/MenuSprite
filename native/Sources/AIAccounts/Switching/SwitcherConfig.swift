import Foundation

/// One account in Claude Switcher's `accounts.json` (version 2). Field names and meanings match the
/// switcher, so both apps keep reading and writing the same list.
public struct SwitcherAccount: Sendable, Identifiable {
    public var email: String
    public var subscriptionType: String
    public var orgName: String
    public var active: Bool
    public var keychainAccount: String
    /// Claude's `oauthAccount` profile as JSON text; Codex entries carry none.
    public var oauthAccountJSON: String?
    public var provider: AIProvider
    /// The entry as last read, so keys this model does not know survive a rewrite.
    var originalJSON: String?

    public var id: String { "\(provider.rawValue):\(email)" }

    public init(email: String, subscriptionType: String, orgName: String, active: Bool,
                keychainAccount: String, oauthAccountJSON: String? = nil, provider: AIProvider) {
        self.email = email; self.subscriptionType = subscriptionType; self.orgName = orgName
        self.active = active; self.keychainAccount = keychainAccount
        self.oauthAccountJSON = oauthAccountJSON; self.provider = provider
        originalJSON = nil
    }

    /// Mirrors the switcher's loader: every dataclass field except `oauth_account` is required and
    /// `provider` defaults to Claude. Anything else is kept verbatim as an unmodelled entry.
    init?(object: [String: Any]) {
        guard let email = object["email"] as? String,
              let subscriptionType = object["subscription_type"] as? String,
              let orgName = object["org_name"] as? String,
              let active = object["active"] as? Bool,
              let keychainAccount = object["keychain_account"] as? String,
              let provider = AIProvider(rawValue: (object["provider"] as? String) ?? "claude") else { return nil }
        self.init(email: email, subscriptionType: subscriptionType, orgName: orgName, active: active,
                  keychainAccount: keychainAccount,
                  oauthAccountJSON: (object["oauth_account"] as? [String: Any]).flatMap(SwitcherJSON.compact),
                  provider: provider)
        originalJSON = SwitcherJSON.compact(object)
    }

    func jsonObject() -> [String: Any] {
        var object = originalJSON.flatMap(CredentialJSON.object(from:)) ?? [:]
        object["email"] = email
        object["subscription_type"] = subscriptionType
        object["org_name"] = orgName
        object["active"] = active
        object["keychain_account"] = keychainAccount
        object["oauth_account"] = oauthAccountJSON.flatMap(CredentialJSON.object(from:)) ?? NSNull()
        object["provider"] = provider.rawValue
        return object
    }
}

extension SwitcherAccount: Equatable {
    public static func == (lhs: SwitcherAccount, rhs: SwitcherAccount) -> Bool {
        lhs.email == rhs.email && lhs.subscriptionType == rhs.subscriptionType && lhs.orgName == rhs.orgName
            && lhs.active == rhs.active && lhs.keychainAccount == rhs.keychainAccount
            && lhs.oauthAccountJSON == rhs.oauthAccountJSON && lhs.provider == rhs.provider
    }
}

/// Claude Switcher's shared account list and auto-switch settings.
public struct SwitcherConfig: Sendable, Equatable {
    public static let version = 2
    public var accounts: [SwitcherAccount] = []
    /// Auto-switch flags keyed by provider name, as the switcher stores them.
    public var autoSwitch: [String: Bool] = ["claude": false, "codex": false]
    public var autoSwitchThreshold: Double = 100
    /// The document as last read and entries this model cannot represent, preserved across saves.
    var documentJSON: String?
    var unmodelledAccountsJSON: [String] = []

    public init() {}

    public func accounts(for provider: AIProvider) -> [SwitcherAccount] { accounts.filter { $0.provider == provider } }

    public func account(_ provider: AIProvider, email: String) -> SwitcherAccount? {
        accounts.first { $0.provider == provider && $0.email == email }
    }

    public func active(_ provider: AIProvider) -> SwitcherAccount? { accounts.first { $0.provider == provider && $0.active } }

    public func isAutoSwitchEnabled(_ provider: AIProvider) -> Bool { autoSwitch[provider.rawValue] ?? false }

    /// Replaces an entry in place (keeping its unknown keys) or appends a new one.
    public mutating func upsert(_ account: SwitcherAccount) {
        guard let index = accounts.firstIndex(where: { $0.provider == account.provider && $0.email == account.email }) else {
            accounts.append(account)
            return
        }
        var merged = account
        if merged.originalJSON == nil { merged.originalJSON = accounts[index].originalJSON }
        accounts[index] = merged
    }

    /// Activates one account and deactivates the others of the same provider only.
    public mutating func setActive(_ provider: AIProvider, email: String) {
        for index in accounts.indices where accounts[index].provider == provider {
            accounts[index].active = accounts[index].email == email
        }
    }

    public mutating func remove(_ provider: AIProvider, email: String) {
        accounts.removeAll { $0.provider == provider && $0.email == email }
    }

    /// A missing file is an empty list. An unreadable one throws rather than being treated as empty,
    /// so a damaged list is never silently overwritten.
    public static func load(from url: URL) throws -> SwitcherConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return SwitcherConfig() }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw SwitchingError.configUnreadable(error.localizedDescription) }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> SwitcherConfig {
        guard let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SwitchingError.configUnreadable("accounts.json is not a JSON object")
        }
        var config = SwitcherConfig()
        config.documentJSON = SwitcherJSON.compact(document)
        if let settings = document["settings"] as? [String: Any] {
            for (provider, value) in (settings["auto_switch"] as? [String: Any]) ?? [:] {
                if let enabled = value as? Bool { config.autoSwitch[provider] = enabled }
            }
            if let threshold = CredentialJSON.number(settings["auto_switch_threshold"]) { config.autoSwitchThreshold = threshold }
        }
        for entry in (document["accounts"] as? [Any]) ?? [] {
            guard let object = entry as? [String: Any] else { continue }
            if let account = SwitcherAccount(object: object) {
                config.accounts.append(account)
            } else if let text = SwitcherJSON.compact(object) {
                config.unmodelledAccountsJSON.append(text)
            }
        }
        return config
    }

    public func encoded() throws -> Data {
        var document = documentJSON.flatMap(CredentialJSON.object(from:)) ?? [:]
        document["version"] = Self.version
        var settings = (document["settings"] as? [String: Any]) ?? [:]
        var flags = (settings["auto_switch"] as? [String: Any]) ?? [:]
        for (provider, enabled) in autoSwitch { flags[provider] = enabled }
        settings["auto_switch"] = flags
        settings["auto_switch_threshold"] = autoSwitchThreshold
        document["settings"] = settings
        document["accounts"] = accounts.map { $0.jsonObject() } + unmodelledAccountsJSON.compactMap(CredentialJSON.object(from:))
        guard JSONSerialization.isValidJSONObject(document) else { throw SwitchingError.file("accounts.json could not be encoded.") }
        return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Writes with the switcher's permissions: directory 0700, file 0600.
    public func save(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try AtomicFile.write(try encoded(), to: url, permissions: 0o600)
    }
}

enum SwitcherJSON {
    /// Compact JSON with sorted keys, so equal objects always produce equal text.
    static func compact(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
