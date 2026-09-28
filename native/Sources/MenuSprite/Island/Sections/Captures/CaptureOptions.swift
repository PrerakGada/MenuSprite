import AppKit
import AVFoundation
import IslandKit

/// The capture feature's own preferences, stored under `MenuSprite.Island.Captures.<option>`. Without
/// defaults (the render harness) the values live in memory only. Where the capture controls open and
/// whether previews go to the island are island settings (`capturesInIsland`, the Captures indicator).
@MainActor
final class CaptureOptions: ObservableObject {
    private enum Key {
        static let afterAction = "MenuSprite.Island.Captures.afterAction"
        static let saveFolder = "MenuSprite.Island.Captures.saveFolder"
        static let showsPreview = "MenuSprite.Island.Captures.showPreview"
        static let systemAudio = "MenuSprite.Island.Captures.systemAudio"
        static let microphone = "MenuSprite.Island.Captures.microphone"
        static let countdown = "MenuSprite.Island.Captures.countdown"
        static let screenshotShortcut = "MenuSprite.Island.Captures.screenshotShortcut"
        static let recordingShortcut = "MenuSprite.Island.Captures.recordingShortcut"
    }

    private let defaults: UserDefaults?

    /// Saved and copied by default, so a capture is never only in memory.
    @Published var afterAction: CaptureAfterAction { didSet { defaults?.set(afterAction.rawValue, forKey: Key.afterAction) } }
    @Published var saveFolder: URL { didSet { defaults?.set(saveFolder.path, forKey: Key.saveFolder) } }
    @Published var showsPreview: Bool { didSet { defaults?.set(showsPreview, forKey: Key.showsPreview) } }
    @Published var recordsSystemAudio: Bool { didSet { defaults?.set(recordsSystemAudio, forKey: Key.systemAudio) } }
    @Published var recordsMicrophone: Bool { didSet { defaults?.set(recordsMicrophone, forKey: Key.microphone) } }
    @Published var countdown: Int { didSet { defaults?.set(countdown, forKey: Key.countdown) } }
    /// Global shortcuts; none is assigned until the person records one.
    @Published var screenshotShortcut: IslandShortcut? { didSet { store(screenshotShortcut, Key.screenshotShortcut) } }
    @Published var recordingShortcut: IslandShortcut? { didSet { store(recordingShortcut, Key.recordingShortcut) } }

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        afterAction = defaults?.string(forKey: Key.afterAction).flatMap(CaptureAfterAction.init(rawValue:)) ?? .saveAndCopy
        saveFolder = defaults?.string(forKey: Key.saveFolder).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultFolder
        showsPreview = defaults?.object(forKey: Key.showsPreview) as? Bool ?? true
        recordsSystemAudio = defaults?.object(forKey: Key.systemAudio) as? Bool ?? CaptureRecordingRules.recordsSystemAudioByDefault
        recordsMicrophone = defaults?.object(forKey: Key.microphone) as? Bool ?? CaptureRecordingRules.recordsMicrophoneByDefault
        let stored = defaults?.object(forKey: Key.countdown) as? Int ?? CaptureRecordingRules.defaultCountdown
        countdown = CaptureRecordingRules.countdownChoices.contains(stored) ? stored : CaptureRecordingRules.defaultCountdown
        screenshotShortcut = Self.shortcut(defaults, Key.screenshotShortcut)
        recordingShortcut = Self.shortcut(defaults, Key.recordingShortcut)
    }

    /// The Desktop, or the home folder when there is none.
    static var defaultFolder: URL {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        return FileManager.default.fileExists(atPath: desktop.path) ? desktop : FileManager.default.homeDirectoryForCurrentUser
    }

    /// The folder to save into now: the chosen one while it exists, otherwise the default.
    var resolvedSaveFolder: URL {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: saveFolder.path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? saveFolder : Self.defaultFolder
    }

    /// Whether the microphone may be recorded right now: switched on and already allowed. Access is
    /// asked for only when the person turns the switch on.
    var microphoneAllowed: Bool {
        recordsMicrophone && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Turns the microphone switch on or off, asking for access the first time it is turned on.
    func setRecordsMicrophone(_ on: Bool, headless: Bool) {
        recordsMicrophone = on
        guard on, !headless, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    private func store(_ shortcut: IslandShortcut?, _ key: String) {
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) { defaults?.set(data, forKey: key) }
        else { defaults?.removeObject(forKey: key) }
    }

    private static func shortcut(_ defaults: UserDefaults?, _ key: String) -> IslandShortcut? {
        defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(IslandShortcut.self, from: $0) }
    }
}
