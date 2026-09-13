import Foundation
import Security

public enum KeychainError: Error, Sendable, Equatable, LocalizedError {
    /// macOS would have to show an access prompt, or the keychain is locked. MenuSprite never prompts.
    case interactionRequired(OSStatus)
    case readFailed(OSStatus)
    case toolFailed(String)
    /// The write command ran but the item did not read back with the written value.
    case notStored(String)
    case unsafeName(String)

    public var errorDescription: String? {
        switch self {
        case .interactionRequired: "The keychain is locked or would ask for permission."
        case .readFailed(let status): "Keychain read failed (\(status))."
        case .toolFailed(let message): "Keychain command failed: \(message)"
        case .notStored(let service): "Keychain did not store \(service)."
        case .unsafeName(let name): "Unsupported keychain name: \(name)"
        }
    }
}

public protocol KeychainStoring: Sendable {
    /// The item's secret, or nil when no item exists. Never shows UI.
    func readPassword(service: String, account: String?) throws -> String?
    /// The `acct` attribute of the first matching item.
    func accountName(service: String) throws -> String?
    /// Creates or updates the item the way Claude Code does, so the CLIs keep reading it without a prompt.
    func writePassword(service: String, account: String, value: String) throws
    /// Removes every item for the service (duplicates can exist) and returns how many were removed.
    @discardableResult func deleteAll(service: String) throws -> Int
}

/// Reads through the Security framework (verified prompt-free for the CLIs' items with MenuSprite's
/// signing identity). Mutations go through `/usr/bin/security` exactly as Claude Code 2.1 performs
/// them: `security -i` over stdin for lines up to 4032 bytes. Larger payloads use the Security
/// framework, preserving existing access lists and trusting the CLI's security tool on new items.
/// Secrets never enter process arguments; longer interactive lines would silently be truncated.
public struct SystemKeychain: KeychainStoring {
    static let interactiveLineLimit = 4032
    private static let securityTool = "/usr/bin/security"
    private static let itemNotFoundExit: Int32 = 44
    private let keychainPath: String?

    /// A separate keychain is useful for isolated integration tests. Normal app use leaves this nil.
    public init(keychainPath: String? = nil) { self.keychainPath = keychainPath }

    public func readPassword(service: String, account: String?) throws -> String? {
        var query = try query(service: service, account: account)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            guard let text = String(data: data, encoding: .utf8) else { throw KeychainError.readFailed(errSecDecode) }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw KeychainError.interactionRequired(status)
        default:
            throw KeychainError.readFailed(status)
        }
    }

    public func accountName(service: String) throws -> String? {
        var query = try query(service: service, account: nil)
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return (result as? [String: Any])?[kSecAttrAccount as String] as? String
        case errSecItemNotFound: return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled: throw KeychainError.interactionRequired(status)
        default: throw KeychainError.readFailed(status)
        }
    }

    public func writePassword(service: String, account: String, value: String) throws {
        try Self.requireSafe(service)
        try Self.requireSafe(account)
        let hex = CredentialJSON.hex(value)
        if let keychainPath { try Self.requireSafe(keychainPath) }
        let keychainArgument = keychainPath.map { " \"\($0)\"" } ?? ""
        let line = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\(keychainArgument)\n"
        if line.utf8.count > Self.interactiveLineLimit {
            try writeLargePassword(service: service, account: account, value: value)
        } else {
            let result = try Self.runSecurity(["-i"], input: line)
            guard result.status == 0 else {
                // Never surface tool stderr: a failed interactive command can echo its input.
                throw KeychainError.toolFailed("security exited with status \(result.status)")
            }
        }
        // `security -i` exits 0 even when its command fails; only a read-back proves the write.
        let stored = try? readPassword(service: service, account: account)
        guard stored == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw KeychainError.notStored(service)
        }
    }

    private func writeLargePassword(service: String, account: String, value: String) throws {
        var query = try query(service: service, account: account)
        query.removeValue(forKey: kSecMatchLimit as String)
        let attributes = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            // Trust only this application and the CLI's security tool for newly created items.
            var securityApp: SecTrustedApplication?, thisApp: SecTrustedApplication?
            guard SecTrustedApplicationCreateFromPath(Self.securityTool, &securityApp) == errSecSuccess,
                  SecTrustedApplicationCreateFromPath(nil, &thisApp) == errSecSuccess,
                  let securityApp, let thisApp else {
                throw KeychainError.toolFailed("Unable to create keychain access policy")
            }
            var access: SecAccess?
            status = SecAccessCreate(service as CFString, [securityApp, thisApp] as CFArray, &access)
            guard status == errSecSuccess, let access else {
                throw KeychainError.toolFailed("Keychain access policy failed (\(status))")
            }
            query[kSecValueData as String] = Data(value.utf8)
            query[kSecAttrAccess as String] = access
            if let keychain = try openKeychain() {
                query.removeValue(forKey: kSecMatchSearchList as String)
                query[kSecUseKeychain as String] = keychain
            }
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            if [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status) {
                throw KeychainError.interactionRequired(status)
            }
            throw KeychainError.toolFailed("Keychain write failed (\(status))")
        }
    }

    @discardableResult public func deleteAll(service: String) throws -> Int {
        try Self.requireSafe(service)
        var removed = 0
        for _ in 0..<32 {
            let result = try Self.runSecurity(["delete-generic-password", "-s", service] + (keychainPath.map { [$0] } ?? []), input: nil)
            if result.status == Self.itemNotFoundExit { return removed }
            guard result.status == 0 else { throw KeychainError.toolFailed(result.stderr) }
            removed += 1
        }
        return removed
    }

    private func query(service: String, account: String?) throws -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if let keychain = try openKeychain() { query[kSecMatchSearchList as String] = [keychain] }
        return query
    }

    private func openKeychain() throws -> SecKeychain? {
        guard let keychainPath else { return nil }
        var keychain: SecKeychain?
        let status = SecKeychainOpen(keychainPath, &keychain)
        guard status == errSecSuccess else { throw KeychainError.readFailed(status) }
        return keychain
    }

    private static func requireSafe(_ name: String) throws {
        guard !name.isEmpty, name.count <= 512, !name.contains(where: { $0 == "\"" || $0 == "\\" || $0.isNewline }) else {
            throw KeychainError.unsafeName(name)
        }
    }

    private struct ToolResult { let status: Int32; let stderr: String }

    private static func runSecurity(_ arguments: [String], input: String?) throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityTool)
        process.arguments = arguments
        process.environment = [:]
        let stdin = Pipe(), stderr = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { throw KeychainError.toolFailed(error.localizedDescription) }
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        guard finished.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            throw KeychainError.toolFailed("security timed out")
        }
        let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return ToolResult(status: process.terminationStatus, stderr: message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// A keychain double for tests and sandboxed validation; never touches the real keychain.
public final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    public struct Item: Sendable, Equatable {
        public var account: String
        public var value: String
        public init(account: String, value: String) { self.account = account; self.value = value }
    }

    private let lock = NSLock()
    private var items: [String: Item]

    public init(_ items: [String: Item] = [:]) { self.items = items }

    public func readPassword(service: String, account: String?) throws -> String? {
        lock.withLock {
            guard let item = items[service], account == nil || item.account == account else { return nil }
            return item.value
        }
    }

    public func accountName(service: String) throws -> String? {
        lock.withLock { items[service]?.account }
    }

    public func writePassword(service: String, account: String, value: String) throws {
        lock.withLock { items[service] = Item(account: account, value: value) }
    }

    @discardableResult public func deleteAll(service: String) throws -> Int {
        lock.withLock { items.removeValue(forKey: service) == nil ? 0 : 1 }
    }

    public var snapshot: [String: Item] { lock.withLock { items } }
}
