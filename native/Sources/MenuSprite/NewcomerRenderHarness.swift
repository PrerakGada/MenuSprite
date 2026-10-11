import AIAccounts
import AppKit
import SwiftUI
import SystemMonitoring

/// What a first-time user meets, drawn to PNG files with a brand-new profile and nothing on screen:
/// the seeded menu bar, every hub tab, the Sprites window and the studio for the first sprite.
///
///     MenuSprite --newcomer-render <dir>
@MainActor
enum NewcomerRenderHarness {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--newcomer-render"), arguments.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1])
        NSApplication.shared.setActivationPolicy(.prohibited)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MonitoringStore(configurationURL: directory.appendingPathComponent("fresh-monitoring.json"))
        let defaults = IslandRenderHarness.scratchDefaults(in: directory)
        defaults.set(false, forKey: "power.saverEnabled")
        let power = PowerStore(preferences: defaults)
        let accounts = AccountsStore(switcher: AccountSwitcher(usage: UsageService.shared, http: URLSessionTransport()),
                                     usage: UsageService.shared) { _ in }
        Task { @MainActor in
            _ = await store.sampleAllForValidation()
            try? await Task.sleep(for: .seconds(2))
            _ = await store.sampleAllForValidation()
            var report: [String] = ["Seeded sprites: " + store.sprites.map { "\($0.name)\($0.showInMenuBar ? "" : " (hidden)")" }.joined(separator: ", ")]

            // The menu bar a new user sees, right to left as macOS lays it out, with the hub icon last.
            let height = NSStatusBar.system.thickness
            let images = store.sprites.filter { $0.showInMenuBar && $0.enabled }.compactMap { store.renderDesign($0)?.image }
            let bar = HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    Image(nsImage: StudioCanvas.scaled(image, zoom: 2, dark: true))
                }
                if let icon = NSImage(named: "MenuBarIcon") {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(height: height * 2 - 6)
                }
            }
            .padding(.horizontal, 16).frame(height: height * 2 + 8)
            .background(Color(white: 0.12))
            await SpriteStudioRenderHarness.snapshot(bar, appearance: .darkAqua, size: NSSize(width: 1200, height: height * 2 + 8),
                                                     to: directory.appendingPathComponent("1-menu-bar.png"))

            let model = HubModel(monitoring: store, accounts: accounts)
            model.opened()
            for tab in HubTab.available where tab != .ai {
                model.select(tab)
                try? await Task.sleep(for: .milliseconds(300))
                let view = HubView(model: model, monitoring: store, power: power, accounts: accounts, actions: HubActions(), close: {})
                    .frame(width: tab.preferredWidth, height: 720)
                await SpriteStudioRenderHarness.snapshot(view, appearance: .darkAqua, size: NSSize(width: tab.preferredWidth, height: 720),
                                                         to: directory.appendingPathComponent("2-hub-\(tab.rawValue).png"))
            }
            model.closed()

            let window = MonitoringView(store: store).frame(width: 1300, height: 860)
            await SpriteStudioRenderHarness.snapshot(window, appearance: .darkAqua, size: NSSize(width: 1300, height: 860),
                                                     to: directory.appendingPathComponent("3-sprites-window.png"))
            if let first = store.sprites.first {
                let studio = StudioModel(config: first, store: store)
                let view = SpriteStudio(model: studio, store: store, close: {}).frame(width: 1300, height: 860)
                await SpriteStudioRenderHarness.snapshot(view, appearance: .darkAqua, size: NSSize(width: 1300, height: 860),
                                                         to: directory.appendingPathComponent("4-studio-\(first.name).png"))
                studio.close()
            }
            report.append("rendered → \(directory.path)")
            print(report.joined(separator: "\n"))
            exit(0)
        }
        NSApplication.shared.run()
    }
}
