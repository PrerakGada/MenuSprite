import AppKit
import ApplicationServices
import Combine
import IslandKit
import SwiftUI

/// Mirrors new macOS notification banners into the island: a notice beside the camera that opens
/// into the whole message under the pointer, and an inbox of this session's messages. Banners are
/// read as they appear on screen, through Accessibility on Notification Center's process; nothing
/// reads Notification Center's database. The reader runs only while the island is on, the section is
/// shown and Accessibility is granted, and everything it read is dropped when any of that stops.
@MainActor
final class NotificationsSection: IslandSection {
    let id = IslandSectionID.notifications
    private unowned let environment: IslandEnvironment
    let store = NotificationMirrorStore()
    let preferences = NotificationPreferencesStore()
    private var running = false
    private var observations: Set<AnyCancellable> = []
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var trustCheck: Task<Void, Never>?
    private var noticeID: UUID?

    /// Posted system-wide whenever an app's Accessibility permission changes.
    private static let accessibilityChanged = Notification.Name("com.apple.accessibility.api")
    private static let accessibilitySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    init(environment: IslandEnvironment) {
        self.environment = environment
        store.onArrival = { [weak self] mirror in self?.announce(mirror) }
        store.onTrustLost = { [weak self] in self?.sync() }
        preferences.changed = { [weak self] in self?.updateCloseGate() }
    }

    var availability: IslandAvailability { .available }

    func pageHeight(_ context: IslandPageContext) -> IslandPageHeight { .fill }

    func page(_ context: IslandPageContext) -> AnyView {
        AnyView(NotificationsPage(store: store, context: context,
                                  requestAccess: { [weak self] in self?.requestAccess() },
                                  openAccessSettings: { [weak self] in self?.openAccessSettings() },
                                  open: { [weak self] id in self?.store.open(id) }))
    }

    func headerAccessory(_ context: IslandPageContext) -> AnyView? { AnyView(NotificationsClearButton(store: store)) }

    func options() -> AnyView? {
        AnyView(NotificationsOptionsView(preferences: preferences, store: store,
                                         requestAccess: { [weak self] in self?.requestAccess() },
                                         openAccessSettings: { [weak self] in self?.openAccessSettings() }))
    }

    func pageDidAppear() { sync() }

    func islandDidStart() {
        running = true
        observe()
        sync()
    }

    func islandDidStop() {
        running = false
        observations.removeAll()
        observers.forEach { $0.center.removeObserver($0.token) }
        observers.removeAll()
        trustCheck?.cancel()
        trustCheck = nil
        store.stop()
        retireNotice()
    }

    // MARK: Running

    /// Starts or stops the reader to match the island, the section's visibility and Accessibility.
    private func sync() {
        if environment.isHeadless, let mode = NotificationSamples.mode { showSamples(mode); return }
        let trusted = store.refreshTrust()
        let runs = NotificationPolicy.readerRuns(islandRunning: running && !environment.isHeadless,
                                                 sectionVisible: environment.settings.isVisible(.notifications), trusted: trusted)
        if runs {
            store.start()
        } else {
            store.stop()
            retireNotice()
        }
        updateCloseGate()
    }

    private func observe() {
        environment.settingsStore.$value
            .map { $0.isVisible(.notifications) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.sync() } }
            .store(in: &observations)
        environment.$isOpen
            .removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.updateCloseGate() } }
            .store(in: &observations)
        // Notification Center can restart; any app launching or quitting is the cue to check it.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.store.checkNotificationCenter() }
            }
            observers.append((workspace, token))
        }
        let token = DistributedNotificationCenter.default().addObserver(forName: Self.accessibilityChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleTrustCheck() }
        }
        observers.append((DistributedNotificationCenter.default(), token))
    }

    /// Accessibility changes take a moment to reach this process: check shortly after the signal.
    private func scheduleTrustCheck() {
        trustCheck?.cancel()
        trustCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.sync()
        }
    }

    /// The reader acts on a close only while the option is on and the island is closed.
    private func updateCloseGate() {
        store.setCloseAllowed(preferences.showBanners && preferences.closeOriginals && !environment.isOpen)
    }

    // MARK: Notices

    private func announce(_ mirror: NotificationMirror) {
        guard running, NotificationPolicy.postsBanner(readerRuns: store.status != .off, showBanners: preferences.showBanners) else { return }
        let appName = mirror.appName
        let showsActionRow = mirror.canOpen || store.mirrors.count > 1
        let id = mirror.id
        let card = NotificationMessageCard(store: store, mirror: mirror, showsActionRow: showsActionRow,
                                           open: { [weak self] in self?.openFromIsland(id) },
                                           dismiss: { [weak self] in self?.dismissFromIsland(id) },
                                           showInbox: { [weak self] in self?.environment.open(.notifications) })
        var notice = IslandNotice(kind: .notification,
                                  style: .custom(wing: IslandNoticeWings.notification,
                                                 left: AnyView(NotificationNoticeLeading(icon: store.icon(for: mirror),
                                                                                         title: NotificationText.compactTitle(mirror.fields, appName: appName))),
                                                 right: AnyView(NotificationNoticeTrailing(detail: NotificationText.compactDetail(mirror.fields)))),
                                  label: NotificationText.spoken(mirror.fields, appName: appName),
                                  destination: .notifications,
                                  expanded: AnyView(card),
                                  expandedHeight: NotificationCardMetrics.height(for: mirror, showsActionRow: showsActionRow,
                                                                                 settings: environment.settings))
        notice.action = { [weak self] in self?.openFromIsland(id) }
        let shown = environment.notices.post(notice)
        guard shown else { return }
        noticeID = notice.id
        let closes = NotificationPolicy.closesOriginal(readerRuns: true, closeOriginals: preferences.closeOriginals, noticeShown: shown,
                                                       islandOpen: environment.isOpen, isPersistent: mirror.live?.isPersistent ?? true)
        guard closes, !environment.isHeadless else { return }
        store.scheduleClose(mirror) { [weak self] in
            guard let self else { return false }
            return self.running && self.preferences.showBanners && self.preferences.closeOriginals && !self.environment.isOpen
        }
    }

    /// A click on the banner (or Open in its card) opens the message; if it cannot be opened, the
    /// inbox shows it instead.
    private func openFromIsland(_ id: Int) {
        retireNotice()
        store.open(id) { [weak self] opened in
            guard !opened else { return }
            self?.environment.open(.notifications)
        }
    }

    private func dismissFromIsland(_ id: Int) {
        store.dismiss(id)
        retireNotice()
    }

    private func retireNotice() {
        if let noticeID, environment.notices.current?.id == noticeID { environment.notices.dismiss() }
        noticeID = nil
    }

    // MARK: Access

    /// Only ever called from a button the person pressed.
    private func requestAccess() {
        guard !environment.isHeadless else { return }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        scheduleTrustCheck()
    }

    private func openAccessSettings() {
        guard !environment.isHeadless, let url = Self.accessibilitySettings else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Render samples

    private func showSamples(_ mode: NotificationSamples.Mode) {
        store.loadSamples(mode == .populated ? NotificationSamples.items : [], trusted: mode == .populated)
        if running, let newest = store.mirrors.first { announce(newest) }
    }
}
