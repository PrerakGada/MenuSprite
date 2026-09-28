import AppKit
import Foundation

/// The gap between every app's menu-bar items — the setting Bartender and Ice call "menu bar item
/// spacing". It is not private API: AppKit's `NSSystemStatusBar` reads two per-host global defaults,
/// `NSStatusItemSpacing` (the gap between items) and `NSStatusItemSelectionPadding` (the padding
/// inside each item's highlight), both 16 pt when absent. Each app reads them once, when it
/// launches, so a change reaches every item only after logging out; an app that is quit and
/// reopened picks it up on its own. Items drawn by macOS itself (Control Center, the clock) may
/// keep their own gaps on macOS 27, where `MenuBarAgent` draws them. Spec: `docs/menu-bar-spacing.md`.
enum MenuBarSpacing {
    static let spacingKey = "NSStatusItemSpacing"
    static let paddingKey = "NSStatusItemSelectionPadding"
    static let systemDefault = 16

    enum Preset: String, CaseIterable, Identifiable {
        case standard, small, verySmall, none
        var id: String { rawValue }
        var title: String {
            switch self {
            case .standard: "Default"
            case .small: "Small"
            case .verySmall: "Very small"
            case .none: "None"
            }
        }
        /// `nil` means the keys are removed, so macOS uses its own 16 pt.
        var points: Int? {
            switch self {
            case .standard: nil
            case .small: 8
            case .verySmall: 4
            case .none: 0
            }
        }
    }

    struct Value: Equatable {
        var spacing: Int?
        var padding: Int?
        var preset: Preset? {
            Preset.allCases.first { $0.points == spacing && $0.points == padding }
        }
        var summary: String {
            if let preset { return preset.points.map { "\(preset.title) · \($0) pt" } ?? "Default · 16 pt" }
            return "Custom · spacing \(spacing ?? systemDefault) pt, padding \(padding ?? systemDefault) pt"
        }
    }

    /// What this process's own menu-bar items were laid out with — AppKit read the keys before
    /// anything here ran, so this is the value the running menu bar is using, not the saved one.
    static let atLaunch: Value = current()

    static func current() -> Value {
        Value(spacing: read(spacingKey), padding: read(paddingKey))
    }

    /// The preset MenuSprite has been told to keep. Set when someone picks one here; absent means
    /// MenuSprite does not own the setting and leaves whatever another app wrote alone.
    static var owned: Preset? {
        get { UserDefaults.standard.string(forKey: ownedKey).flatMap(Preset.init(rawValue:)) }
        set {
            if let newValue { UserDefaults.standard.set(newValue.rawValue, forKey: ownedKey) }
            else { UserDefaults.standard.removeObject(forKey: ownedKey) }
        }
    }

    /// Re-applies the owned preset if the stored keys have drifted from it — run at every launch, so
    /// a login is enough to restore the spacing if anything else changed or cleared it. A no-op in
    /// the ordinary case, and silent: nothing here needs the user's attention.
    static func enforce() {
        guard let owned, current() != Value(spacing: owned.points, padding: owned.points) else { return }
        apply(owned)
    }

    @discardableResult
    static func apply(_ preset: Preset) -> Bool {
        owned = preset
        let value = preset.points.map { $0 as CFNumber }
        for key in [spacingKey, paddingKey] {
            CFPreferencesSetValue(key as CFString, value, kCFPreferencesAnyApplication,
                                  kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
        return CFPreferencesSynchronize(kCFPreferencesAnyApplication,
                                        kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    /// Quits and reopens MenuSprite so its own items take the saved spacing immediately. A detached
    /// shell waits for this process to go, then opens the same bundle.
    @MainActor static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", path]
        guard (try? process.run()) != nil else { return }
        NSApp.terminate(nil)
    }

    private static let ownedKey = "MenuSprite.MenuBarSpacing"

    private static func read(_ key: String) -> Int? {
        let value = CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication,
                                           kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return (value as? NSNumber)?.intValue
    }
}
