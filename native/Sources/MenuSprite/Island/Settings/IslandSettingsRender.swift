import AIAccounts
import AppKit
import IslandKit
import SwiftUI

/// Renders Settings › Dynamic Island to PNG files in a window that is never shown, with throwaway
/// preferences: no status items, no Dock icon, nothing on screen, nothing saved.
///
///     MenuSprite --settings-render <dir>
@MainActor
enum IslandSettingsRender {
    private struct Shot {
        var name: String
        var tab: IslandSettingsTab
        var section: IslandSectionID = .controls
        var size = CGSize(width: 1040, height: 820)
        var appearance: NSAppearance.Name = .darkAqua
        var wait: Double = 0.6
        var prepare: (IslandSettingsModel, IslandSettingsStore, IslandController) -> Void = { _, _, _ in }
    }

    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--settings-render"), arguments.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1])
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = IslandRenderHarness.scratchDefaults(in: directory)

        let monitoring = MonitoringStore(configurationURL: directory.appendingPathComponent("render-monitoring.json"))
        let power = PowerStore(preferences: defaults)
        let accounts = AccountsStore(switcher: AccountSwitcher(usage: UsageService.shared, http: URLSessionTransport()),
                                     usage: UsageService.shared) { _ in }
        let settings = IslandSettingsStore(defaults: defaults)
        settings.update { $0.enabled = true }
        let environment = IslandEnvironment(monitoring: monitoring, power: power, accounts: accounts, settings: settings)
        environment.isHeadless = true
        IslandRegistry.install(in: environment)
        let island = IslandController(environment: environment)

        let shots: [Shot] = [
            Shot(name: "layout", tab: .layout),
            Shot(name: "layout-custom", tab: .layout, prepare: { _, store, _ in
                store.update { $0.size = .custom; $0.customWidth = 600; $0.customHeight = 480; $0.outline = true }
            }),
            Shot(name: "content-controls", tab: .content, prepare: { _, store, _ in store.update { $0 = reset($0) } }),
            Shot(name: "content-system", tab: .content, section: .system, wait: 3, prepare: { model, _, _ in model.windowVisible = true }),
            Shot(name: "content-clipboard", tab: .content, section: .clipboard, prepare: { model, _, _ in model.windowVisible = false }),
            Shot(name: "activity", tab: .activity, prepare: { model, _, _ in model.accessibilityTrusted = false }),
            Shot(name: "behavior", tab: .behavior),
            Shot(name: "behavior-full", tab: .behavior, size: CGSize(width: 1040, height: 1560), prepare: { _, store, _ in
                store.update { $0.opening = .expand; $0.hideInFullScreen = true; $0.appPanelInIsland = true }
            }),
            Shot(name: "narrow-layout", tab: .layout, size: CGSize(width: 820, height: 640), prepare: { model, store, island in
                store.update { $0 = reset($0); $0.coversMenus = false }
                model.otherIslandOn = true
                model.accessibilityTrusted = false
                island.presentation.display = IslandDisplayMetrics.make(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                                                        auxiliaryLeft: nil, auxiliaryRight: nil, safeAreaTop: 0,
                                                                        barHeight: 24, scale: 1)
            }),
            Shot(name: "narrow-content", tab: .content, size: CGSize(width: 820, height: 640), prepare: { model, _, island in
                model.otherIslandOn = false
                island.presentation.display = nil
            }),
            Shot(name: "light-layout", tab: .layout, appearance: .aqua, prepare: { _, store, _ in store.update { $0 = reset($0) } }),
        ]

        Task { @MainActor in
            var report: [String] = []
            for shot in shots {
                let model = IslandSettingsModel(environment: environment, tab: shot.tab)
                model.selection = shot.section
                shot.prepare(model, settings, island)
                let view = IslandSettingsWindowController.rootView(model: model, environment: environment, island: island)
                let url = directory.appendingPathComponent("settings-\(shot.name).png")
                await capture(view, size: shot.size, appearance: shot.appearance, wait: shot.wait, to: url)
                model.windowVisible = false
                report.append("\(shot.name): \(Int(shot.size.width)) × \(Int(shot.size.height)) → \(url.lastPathComponent)")
            }
            settings.update { $0 = reset($0) }
            let add = IslandAddButtonPopover(environment: environment) { _ in }
            await capture(add, size: CGSize(width: 330, height: 330), appearance: .darkAqua, wait: 0.4,
                          to: directory.appendingPathComponent("popover-add.png"))
            let edit = IslandEditButtonPopover(buttonID: IslandFloatingLayout.standard.buttons[1].id, environment: environment,
                                               settings: settings) {}
            await capture(edit, size: CGSize(width: 340, height: 560), appearance: .darkAqua, wait: 0.4,
                          to: directory.appendingPathComponent("popover-edit.png"))
            report.append("popovers → popover-add.png, popover-edit.png")
            try? report.joined(separator: "\n").appending("\n").write(to: directory.appendingPathComponent("settings-report.txt"),
                                                                    atomically: true, encoding: .utf8)
            print(report.joined(separator: "\n"))
            exit(0)
        }
        app.run()
    }

    /// Fresh settings with the island on, as the harness starts each look.
    private static func reset(_ current: IslandSettings) -> IslandSettings {
        var fresh = IslandSettings()
        fresh.enabled = true
        return fresh
    }

    private static func capture<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, wait: Double, to url: URL) async {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .seconds(wait))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.contentView = nil
        window.close()
    }
}
