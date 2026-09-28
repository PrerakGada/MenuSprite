import AppKit
import Combine
import IslandKit
import SwiftUI

/// Settings › Dynamic Island in its own window: the master switch, then Layout, Content, Activity and
/// Behavior. MenuSprite has no sidebar settings app, so the editor is a window of its own, opened from
/// the app menu, the brand icon's menu and the island's Settings button. The window and its views are
/// released on close; the small model survives so the tab and selection come back.
@MainActor
final class IslandSettingsWindowController: NSObject, NSWindowDelegate {
    private static let autosaveName = "DynamicIslandSettings"
    private nonisolated static let otherIslandApp = "com.vorssaint.utils"

    private let environment: IslandEnvironment
    private let island: IslandController
    let model: IslandSettingsModel
    private var window: NSWindow?
    private var workspaceObservers: [NSObjectProtocol] = []

    init(environment: IslandEnvironment, island: IslandController) {
        self.environment = environment
        self.island = island
        model = IslandSettingsModel(environment: environment)
    }

    var isVisible: Bool { window?.isVisible == true }

    /// Brings the window forward; a section selects it on the Content tab.
    func show(section: IslandSectionID? = nil) {
        if let section { model.reveal(section) }
        let window = self.window ?? makeWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.windowVisible = !window.isMiniaturized
        refreshChecks()
    }

    func close() { window?.close() }

    /// The window's content, also used by the render harness in a window that is never shown.
    static func rootView(model: IslandSettingsModel, environment: IslandEnvironment, island: IslandController) -> some View {
        IslandSettingsView(model: model, settings: environment.settingsStore, environment: environment,
                           presentation: island.presentation, open: { [weak island] in island?.open(nil, explicit: true) })
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MenuSprite — Dynamic Island"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 820, height: 640)
        window.delegate = self
        window.contentView = NSHostingView(rootView: Self.rootView(model: model, environment: environment, island: island))
        if !window.setFrameUsingName(Self.autosaveName) { window.center() }
        window.setFrameAutosaveName(Self.autosaveName)
        self.window = window
        observeOtherIsland()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        model.windowVisible = false
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        window?.contentView = nil
        window?.delegate = nil
        window = nil
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window else { return }
        model.windowVisible = window.occlusionState.contains(.visible) && !window.isMiniaturized
    }

    func windowDidBecomeKey(_ notification: Notification) { refreshChecks() }

    // MARK: Read-only checks

    /// Accessibility is only checked here; the Permissions window is where it is granted.
    private func refreshChecks() {
        model.accessibilityTrusted = AXIsProcessTrusted()
        refreshOtherIsland()
    }

    private func observeOtherIsland() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.otherIslandApp else { return }
                MainActor.assumeIsolated { self?.refreshOtherIsland() }
            })
        }
    }

    /// Vorssaint's own island is on when its switch is saved on and the app is running. Its preferences
    /// are read off the main thread; nothing is written.
    private func refreshOtherIsland() {
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.otherIslandApp).isEmpty
        guard running else { model.otherIslandOn = false; return }
        let domain = Self.otherIslandApp
        Task { [weak model] in
            let enabled = await Task.detached(priority: .utility) {
                UserDefaults(suiteName: domain)?.bool(forKey: "notchEnabled") == true
            }.value
            model?.otherIslandOn = enabled
        }
    }
}

/// What the settings window shows: tab, selected section and the read-only checks. It also decides
/// when the System page's preview may sample: only on the Content tab, with System selected, while the
/// window is visible.
@MainActor
final class IslandSettingsModel: ObservableObject {
    @Published var tab: IslandSettingsTab = .layout { didSet { syncSampling() } }
    @Published var selection: IslandSectionID = .controls { didSet { syncSampling() } }
    /// Changes when the Content list should scroll to the selection.
    @Published private(set) var scrollRequest = 0
    @Published var windowVisible = false { didSet { syncSampling() } }
    @Published var accessibilityTrusted = true
    @Published var otherIslandOn = false

    private unowned let environment: IslandEnvironment
    private var sampling: IslandSectionID?
    private var islandObservation: AnyCancellable?

    init(environment: IslandEnvironment, tab: IslandSettingsTab = .layout) {
        self.environment = environment
        self.tab = tab
        // The island stops a page's sampling when it leaves that page; the preview picks it up again.
        islandObservation = environment.$isOpen.combineLatest(environment.$destination)
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.resumeSampling() } } }
    }

    /// Opens a section on the Content tab and scrolls the list to it.
    func reveal(_ section: IslandSectionID) {
        tab = .content
        selection = section
        scrollRequest += 1
    }

    private var previewSamples: IslandSectionID? {
        windowVisible && tab == .content && selection == .system ? .system : nil
    }

    private var islandShows: IslandSectionID? {
        environment.isOpen ? environment.destination?.section : nil
    }

    private func syncSampling() {
        let wanted = previewSamples
        guard wanted != sampling else { return }
        if let sampling, islandShows != sampling { environment.sections[sampling]?.pageDidDisappear() }
        sampling = wanted
        if let wanted { environment.sections[wanted]?.pageDidAppear() }
    }

    private func resumeSampling() {
        guard let sampling, islandShows != sampling else { return }
        environment.sections[sampling]?.pageDidAppear()
    }
}
