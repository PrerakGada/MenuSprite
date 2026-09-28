import AppKit
import Foundation
import IslandKit

/// The Downloads section's own options, stored as `MenuSprite.Island.Downloads.<option>`: the watch
/// switch, the chosen folder's saved authority and name, and what the closed island shows.
@MainActor
final class DownloadsPreferences: ObservableObject {
    private static let prefix = "MenuSprite.Island.Downloads."
    private let defaults: UserDefaults
    /// Called after any change has been stored.
    var changed: () -> Void = {}

    /// The section's Downloads switch. On by default, but inert until a folder is chosen.
    @Published var enabled: Bool { didSet { store(enabled, "enabled") } }
    /// Show an active download's progress beside the camera.
    @Published var showsActivity: Bool { didSet { store(showsActivity, "activity") } }
    /// Show "Download complete" when a download is proven finished.
    @Published var showsNotice: Bool { didSet { store(showsNotice, "notice") } }
    /// The chosen folder's security-scoped bookmark.
    @Published private(set) var bookmark: Data?
    @Published private(set) var folderName: String?
    @Published private(set) var folderPath: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func flag(_ key: String) -> Bool { defaults.object(forKey: Self.prefix + key) as? Bool ?? true }
        enabled = flag("enabled")
        showsActivity = flag("activity")
        showsNotice = flag("notice")
        bookmark = defaults.data(forKey: Self.prefix + "bookmark")
        folderName = defaults.string(forKey: Self.prefix + "folderName")
        folderPath = defaults.string(forKey: Self.prefix + "folderPath")
    }

    func saveFolder(bookmark: Data, url: URL) {
        self.bookmark = bookmark
        folderName = url.lastPathComponent
        folderPath = url.path
        defaults.set(bookmark, forKey: Self.prefix + "bookmark")
        defaults.set(folderName, forKey: Self.prefix + "folderName")
        defaults.set(folderPath, forKey: Self.prefix + "folderPath")
        enabled = true
    }

    /// Deletes the saved authority and turns the switch off.
    func forgetFolder() {
        bookmark = nil
        folderName = nil
        folderPath = nil
        for key in ["bookmark", "folderName", "folderPath"] { defaults.removeObject(forKey: Self.prefix + key) }
        enabled = false
    }

    private func store(_ value: Bool, _ key: String) {
        defaults.set(value, forKey: Self.prefix + key)
        changed()
    }
}

/// The folder picker, begun from the island's Downloads page or from Settings.
///
/// From the island it is an independent panel one level above the island (a sheet moved and reskinned
/// the borderless island), kept up while another app is active, with the island held open meanwhile.
/// Its result counts only while nothing changed underneath: leaving the page, stopping or disabling the
/// section, or a newer Settings chooser drops it, and leaving the page also closes the panel. From
/// Settings it is an ordinary panel that never borrows, opens or focuses the island, and still saves.
@MainActor
final class DownloadFolderChooser {
    enum Origin { case island, settings }

    static let hint = "Choose the folder where your browser saves downloads. Only that folder is watched."

    private unowned let environment: IslandEnvironment
    private let chosen: (URL) -> Void
    private var islandPanel: NSOpenPanel?
    private var islandToken: UUID?
    private var settingsPanel: NSOpenPanel?

    init(environment: IslandEnvironment, chosen: @escaping (URL) -> Void) {
        self.environment = environment
        self.chosen = chosen
    }

    /// Never shows anything in the render harness or tests.
    func choose(from origin: Origin) {
        guard !environment.isHeadless else { return }
        switch origin {
        case .island: beginInIsland()
        case .settings: beginInSettings()
        }
    }

    /// Closes a panel begun from the island and forgets its result.
    func cancelIslandChooser() {
        guard let panel = islandPanel else { return }
        islandPanel = nil
        islandToken = nil
        environment.actions.holdOpen(false)
        panel.cancel(nil)
    }

    private func beginInIsland() {
        cancelIslandChooser()
        // The click that asked for the panel came from the island's own window.
        let islandLevel = NSApp.currentEvent?.window?.level ?? NSApp.keyWindow?.level ?? .statusBar
        let panel = Self.makePanel()
        panel.level = NSWindow.Level(rawValue: islandLevel.rawValue + 1)
        let token = UUID()
        islandToken = token
        islandPanel = panel
        environment.actions.holdOpen(true)
        panel.begin { [weak self] response in
            let url = response == .OK ? panel.url : nil
            // Return on the next turn, once the panel has finished going away.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishInIsland(token, url) } }
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func finishInIsland(_ token: UUID, _ url: URL?) {
        guard token == islandToken else { return }
        islandToken = nil
        islandPanel = nil
        environment.actions.holdOpen(false)
        guard environment.isRunning, environment.isOpen, environment.destination == .section(.downloads) else { return }
        if let url { chosen(url) }
        // Back to the same page; the pin is left as it was.
        environment.open(.downloads)
    }

    private func beginInSettings() {
        cancelIslandChooser()
        if let settingsPanel {
            settingsPanel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = Self.makePanel()
        settingsPanel = panel
        panel.begin { [weak self] response in
            let url = response == .OK ? panel.url : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.settingsPanel = nil
                    if let url { self?.chosen(url) }
                }
            }
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private static func makePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = hint
        panel.prompt = "Choose"
        panel.hidesOnDeactivate = false
        return panel
    }
}
