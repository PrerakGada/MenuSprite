import AppKit
import SwiftUI

/// Draws the Controls page to PNG files without showing a window, saving a setting or reaching the
/// helper: once as a new install sees it (power controls off) and once with them on.
///
///     MenuSprite --power-render <dir>
@MainActor
enum PowerRenderHarness {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--power-render"), arguments.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1])
        NSApplication.shared.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        PowerStore.offline = true
        for (name, state) in [("off", PowerHelperState.off), ("approval", .needsApproval), ("on", .on)] {
            let suite = "MenuSprite.PowerRender.\(UUID().uuidString)"
            let store = PowerStore(preferences: UserDefaults(suiteName: suite)!)
            store.previewHelper(state)
            for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 820, height: 1900), styleMask: [.borderless], backing: .buffered, defer: false)
                let host = NSHostingView(rootView: PowerView(store: store).frame(width: 820, height: 1900))
                host.appearance = NSAppearance(named: appearance)
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: 820, height: 1900)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
                window.contentView = nil
            }
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        print("Power render written to \(directory.path)")
        exit(0)
    }
}
