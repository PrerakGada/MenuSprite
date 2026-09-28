import AppKit
import Foundation

/// System Audio Recording consent ("Screen & System Audio Recording → System Audio Recording Only"),
/// which process taps need. macOS has no public status check for it; the TCC preflight used here only
/// reads the current decision and never shows a prompt. The prompt is shown only by `request`, which
/// the mixer calls from an explicit button press, never in headless mode.
enum MixerPermission {
    enum Status: Equatable {
        case granted
        case denied
        case notDetermined
        /// The status could not be read; a failed engine build is then treated as missing consent.
        case unknown

        /// Whether the mixer may create taps without causing a prompt.
        var allowsTaps: Bool { self == .granted || self == .unknown }
    }

    private static let service = "kTCCServiceAudioCapture"
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    nonisolated(unsafe) private static let framework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static func status() -> Status {
        guard let framework, let symbol = dlsym(framework, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)(service as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        case 2: return .notDetermined
        default: return .unknown
        }
    }

    /// Shows the system prompt (or nothing, if already decided) and reports the outcome on the main actor.
    static func request(_ completion: @escaping @MainActor @Sendable (Status) -> Void) {
        let deliver: @Sendable () -> Void = {
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(status()) } }
        }
        guard let framework, let symbol = dlsym(framework, "TCCAccessRequest") else { return deliver() }
        let reply: @convention(block) @Sendable (Bool) -> Void = { _ in deliver() }
        unsafeBitCast(symbol, to: Request.self)(service as CFString, nil, reply)
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}
