import Foundation
import Security

public enum KeychainError: Error, Sendable, Equatable, LocalizedError {
    /// macOS would have to show an access prompt, or the keychain is locked. The Security framework's
    /// "fail instead of prompting" flag is not honoured for a partition-list mismatch on current macOS, so
    /// reads of items other tools own go through `readCLIOwnedPassword`, which cannot mismatch.
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
    /// The item's secret, or nil when no item exists. Never shows a keychain dialog.
    func readPassword(service: String, account: String?) throws -> String?
    /// Reads an item the Claude Code / Codex CLIs own (their live login) the way they read it: through
    /// `/usr/bin/security`. An item written by those CLIs carries the `apple-tool:` partition, so a direct
    /// Security-framework read from MenuSprite (team partition) would mismatch and macOS would show a
    /// keychain password dialog every time; the tool matches and never prompts.
    func readCLIOwnedPassword(service: String, account: String?) throws -> String?
    /// The `acct` attribute of the first matching item.
    func accountName(service: String) throws -> String?
    /// Creates or updates the item the way Claude Code does, so the CLIs keep reading it without a prompt.
    func writePassword(service: String, account: String, value: String) throws
    /// Removes every item for the service (duplicates can exist) and returns how many were removed.
    @discardableResult func deleteAll(service: String) throws -> Int
}

public extension KeychainStoring {
    func readCLIOwnedPassword(service: String, account: String?) throws -> String? {
        try readPassword(service: service, account: account)
    }
}

/// Secrets are read through `/usr/bin/security` (see `readPassword`); only attribute lookups use the
/// Security framework, which never needs the secret and so never prompts. Mutations go through `/usr/bin/security` exactly as Claude Code 2.1 performs
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

    /// Every item MenuSprite reads was written by `/usr/bin/security` — Claude Code's live login and the
    /// saved copies alike (see `writePassword`) — so each carries the `apple-tool:` partition. A direct
    /// Security-framework read from MenuSprite's team partition mismatches and macOS shows a password
    /// dialog; `kSecUseAuthenticationUIFail` does not stop it, and "Always Allow" is lost the next time the
    /// item is rewritten. Reading through the same tool always matches, so no read ever prompts.
    public func readPassword(service: String, account: String?) throws -> String? {
        try readCLIOwnedPassword(service: service, account: account)
    }

    public func readCLIOwnedPassword(service: String, account: String?) throws -> String? {
        try Self.requireSafe(service)
        var arguments = ["find-generic-password", "-s", service]
        if let account { try Self.requireSafe(account); arguments += ["-a", account] }
        arguments.append("-w")
        if let keychainPath { try Self.requireSafe(keychainPath); arguments.append(keychainPath) }
        let result = try Self.runSecurity(arguments, input: nil, captureOutput: true)
        switch result.status {
        case 0:
            let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case Self.itemNotFoundExit:
            return nil
        default:
            // Never surface the tool's output: it can hold the secret. stderr names only the failure.
            if result.stderr.localizedCaseInsensitiveContains("interaction is not allowed") {
                throw KeychainError.interactionRequired(errSecInteractionNotAllowed)
            }
            throw KeychainError.toolFailed("security exited with status \(result.status)")
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

    /// A secret too long for one interactive line is written by the same tool with the value in the
    /// command's arguments. The keychain item then belongs to `/usr/bin/security` exactly as a short one
    /// does, so the CLIs and MenuSprite both read it without a prompt. Writing it through the Security
    /// framework instead would stamp the item as MenuSprite's, and every later read by Claude Code — or by
    /// MenuSprite itself — would ask for the keychain password. The cost is that the secret is briefly
    /// visible in this process's arguments to other programs running as the same user.
    private func writeLargePassword(service: String, account: String, value: String) throws {
        var arguments = ["add-generic-password", "-U", "-a", account, "-s", service,
                         "-X", CredentialJSON.hex(value)]
        if let keychainPath { arguments.append(keychainPath) }
        let result = try Self.runSecurity(arguments, input: nil)
        guard result.status == 0 else {
            throw KeychainError.toolFailed("security exited with status \(result.status)")
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

    private struct ToolResult { let status: Int32; let stderr: String; let stdout: String }

    /// Collects a child's stdout while it runs, so output larger than the pipe buffer cannot stall it.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    private static func runSecurity(_ arguments: [String], input: String?, captureOutput: Bool = false) throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityTool)
        process.arguments = arguments
        process.environment = [:]
        let stdin = Pipe(), stderr = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let stdout = Pipe(), collector = OutputCollector()
        process.standardOutput = captureOutput ? stdout : FileHandle.nullDevice
        if captureOutput {
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil } else { collector.append(chunk) }
            }
        }
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
        if captureOutput {
            stdout.fileHandleForReading.readabilityHandler = nil
            collector.append(stdout.fileHandleForReading.readDataToEndOfFile())
        }
        return ToolResult(status: process.terminationStatus, stderr: message.trimmingCharacters(in: .whitespacesAndNewlines),
                          stdout: collector.text)
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
