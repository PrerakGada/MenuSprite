import AppKit

/// macOS's own volume-feedback tone, played through the default output at its current level.
@MainActor
enum VolumeToneSound {
    static let path = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
    /// Loaded on the first tone and kept: a few kilobytes.
    private static var sound: NSSound?

    /// System Settings › Sound › "Play feedback when volume is changed", read each time so a change
    /// there applies at once.
    static var isEnabled: Bool {
        let value = CFPreferencesCopyAppValue("com.apple.sound.beep.feedback" as CFString, kCFPreferencesAnyApplication)
        return (value as? NSNumber)?.boolValue ?? false
    }

    /// A tone already sounding restarts, so fast key presses each get one.
    static func play() {
        if sound == nil { sound = NSSound(contentsOfFile: path, byReference: true) }
        guard let sound else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
