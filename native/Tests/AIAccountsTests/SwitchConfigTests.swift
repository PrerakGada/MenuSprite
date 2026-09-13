import Foundation
import Testing
@testable import AIAccounts

/// Shaped like Claude Switcher's real accounts.json (Python `json.dumps(indent=2)`), with values
/// redacted and a few keys a newer switcher might add.
private let switcherFixture = """
{
  "version": 2,
  "settings": {
    "auto_switch": {
      "claude": true,
      "codex": false
    },
    "auto_switch_threshold": 100.0,
    "future_setting": "keep"
  },
  "accounts": [
    {
      "email": "codex-user@example.com",
      "subscription_type": "pro",
      "org_name": "",
      "active": true,
      "keychain_account": "codex-user@example.com",
      "oauth_account": null,
      "provider": "codex"
    },
    {
      "email": "first@example.com",
      "subscription_type": "max",
      "org_name": "first@example.com's Organization",
      "active": true,
      "keychain_account": "testuser",
      "oauth_account": {
        "accountUuid": "00000000-0000-0000-0000-000000000001",
        "emailAddress": "first@example.com",
        "organizationUuid": "00000000-0000-0000-0000-000000000002",
        "hasExtraUsageEnabled": false,
        "billingType": "stripe_subscription",
        "ccOnboardingFlags": {},
        "seatTier": null,
        "organizationName": "first@example.com's Organization",
        "organizationRateLimitTier": "default_claude_max_20x"
      },
      "provider": "claude",
      "future_field": 7
    },
    {
      "email": "second@example.com",
      "subscription_type": "max",
      "org_name": "second@example.com's Organization",
      "active": false,
      "keychain_account": "testuser",
      "oauth_account": null,
      "provider": "claude"
    },
    {
      "email": "someone@example.com",
      "provider": "gemini",
      "subscription_type": "x",
      "org_name": "",
      "active": false,
      "keychain_account": "k"
    }
  ],
  "future_top_level": {"kept": true}
}
"""

@Test func switcherConfigRoundTripKeepsShapeAndUnknownKeys() throws {
    var config = try SwitcherConfig.decode(Data(switcherFixture.utf8))
    #expect(config.accounts.count == 3)
    #expect(config.unmodelledAccountsJSON.count == 1)
    #expect(config.isAutoSwitchEnabled(.claude))
    #expect(!config.isAutoSwitchEnabled(.codex))
    #expect(config.autoSwitchThreshold == 100)
    #expect(config.active(.claude)?.email == "first@example.com")
    #expect(config.active(.codex)?.email == "codex-user@example.com")
    #expect(config.account(.claude, email: "first@example.com")?.oauthAccountJSON.flatMap(ClaudeState.email(inOAuthAccount:)) == "first@example.com")

    config.setActive(.claude, email: "second@example.com")
    config.autoSwitch["codex"] = true
    let document = try #require(try JSONSerialization.jsonObject(with: config.encoded()) as? [String: Any])
    #expect(document["version"] as? Int == 2)
    #expect((document["future_top_level"] as? [String: Any])?["kept"] as? Bool == true)
    let settings = try #require(document["settings"] as? [String: Any])
    #expect(settings["future_setting"] as? String == "keep")
    #expect((settings["auto_switch"] as? [String: Any])?["codex"] as? Bool == true)
    #expect((settings["auto_switch"] as? [String: Any])?["claude"] as? Bool == true)
    #expect(CredentialJSON.number(settings["auto_switch_threshold"]) == 100)

    let accounts = try #require(document["accounts"] as? [[String: Any]])
    #expect(accounts.count == 4)
    let switcherFields: Set<String> = ["email", "subscription_type", "org_name", "active", "keychain_account", "oauth_account", "provider"]
    for account in accounts where account["provider"] as? String != "gemini" {
        #expect(switcherFields.isSubset(of: Set(account.keys)))
    }
    let first = try #require(accounts.first { $0["email"] as? String == "first@example.com" })
    #expect(first["future_field"] as? Int == 7)
    #expect(first["active"] as? Bool == false)
    #expect((first["oauth_account"] as? [String: Any])?["billingType"] as? String == "stripe_subscription")
    let codex = try #require(accounts.first { $0["provider"] as? String == "codex" })
    #expect(codex["oauth_account"] is NSNull)
    #expect(codex["active"] as? Bool == true)
    #expect(accounts.first { $0["email"] as? String == "second@example.com" }?["active"] as? Bool == true)
    #expect(accounts.contains { $0["provider"] as? String == "gemini" })

    let again = try SwitcherConfig.decode(try config.encoded())
    #expect(again.accounts == config.accounts)
    #expect(again.unmodelledAccountsJSON.count == 1)
}

@Test func switcherConfigSavesPrivatelyAndRefusesCorruptFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("menusprite-switch-config-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("claude-switcher/accounts.json")
    #expect(try SwitcherConfig.load(from: url).accounts.isEmpty)

    var config = SwitcherConfig()
    config.upsert(SwitcherAccount(email: "a@example.com", subscriptionType: "max", orgName: "", active: true,
                                  keychainAccount: "testuser", provider: .claude))
    try config.save(to: url)
    let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    let directoryMode = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
    #expect(fileMode == 0o600)
    #expect(directoryMode == 0o700)
    #expect(try SwitcherConfig.load(from: url).accounts == config.accounts)

    try Data("{broken".utf8).write(to: url)
    #expect(throws: SwitchingError.self) { try SwitcherConfig.load(from: url) }
}

/// Read-only decode of the real list. Prints counts only. Run explicitly:
/// `MENUSPRITE_LIVE_SWITCHER_READ=1 swift test --package-path native --filter switcherConfigDecodesRealFile`
@Test(.enabled(if: ProcessInfo.processInfo.environment["MENUSPRITE_LIVE_SWITCHER_READ"] == "1"))
func switcherConfigDecodesRealFileReadOnly() throws {
    let config = try SwitcherConfig.load(from: AIAccountPaths.standard.switcherConfig)
    let perProvider = AIProvider.allCases.map { "\($0.rawValue)=\(config.accounts(for: $0).count)" }.joined(separator: " ")
    print("accounts.json: \(config.accounts.count) accounts (\(perProvider)), unmodelled \(config.unmodelledAccountsJSON.count)")
    #expect(!config.accounts.isEmpty)
    let again = try SwitcherConfig.decode(try config.encoded())
    #expect(again.accounts == config.accounts)
    #expect(again.autoSwitch == config.autoSwitch)
}
