import AppKit
import Combine
import IslandKit
import SwiftUI

/// Settings › Dynamic Island, the Island page of MenuSprite's window: the master switch, then Layout,
/// Content, Activity and Behavior. The page's views are released when another page is chosen or the
/// window closes; the small model survives so the tab and selection come back.
@MainActor
final class IslandSettingsPage {
    private nonisolated static let otherIslandApp = "com.vorssaint.utils"

    private let environment: IslandEnvironment
    private let island: IslandController
    let model: IslandSettingsModel
    private var workspaceObservers: [NSObjectProtocol] = []

    init(environment: IslandEnvironment, island: IslandController) {
        self.environment = environment
        self.island = island
        model = IslandSettingsModel(environment: environment)
    }

    /// The page's content, also used by the render harness in a window that is never shown.
    static func rootView(model: IslandSettingsModel, environment: IslandEnvironment, island: IslandController) -> some View {
        IslandSettingsView(model: model, settings: environment.settingsStore, environment: environment,
                           presentation: island.presentation, open: { [weak island] in island?.open(nil, explicit: true) })
    }

    /// Builds the page each time the Island tab is chosen.
    func makeView() -> NSView {
        observeOtherIsland()
        refreshChecks()
        let host = NSHostingView(rootView: Self.rootView(model: model, environment: environment, island: island)
            .frame(minWidth: 820, minHeight: 640))
        host.sizingOptions = [.minSize]
        return host
    }

    /// The System preview samples only while the page can be seen.
    func visibilityChanged(_ visible: Bool) { model.windowVisible = visible }

    func closed() {
        model.windowVisible = false
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
    }

    // MARK: Read-only checks

    /// Accessibility is only checked here; the Access page is where it is granted.
    func refreshChecks() {
        model.accessibilityTrusted = AXIsProcessTrusted()
        refreshOtherIsland()
    }

    private func observeOtherIsland() {
        guard workspaceObservers.isEmpty else { return }
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

/// What the Island page shows: tab, selected section and the read-only checks. It also decides
/// when the System page's preview may sample: only on the Content tab, with System selected, while the
/// page is visible.
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
