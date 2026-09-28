import AIAccounts
import AppKit
import Combine
import IslandKit
import SwiftUI

/// The island's preferences, persisted as one JSON value in the app's defaults. Section-specific
/// options live in their own keys, named `MenuSprite.Island.<Section>.<option>`.
@MainActor
final class IslandSettingsStore: ObservableObject {
    static let key = "MenuSprite.Island"
    @Published private(set) var value: IslandSettings
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let decoded = try? JSONDecoder().decode(IslandSettings.self, from: data) {
            value = decoded
        } else {
            value = IslandSettings()
        }
    }

    func update(_ change: (inout IslandSettings) -> Void) {
        var copy = value
        change(&copy)
        guard copy != value else { return }
        value = copy
        if let data = try? JSONEncoder().encode(copy) { defaults.set(data, forKey: Self.key) }
    }
}

/// Live compact activities, published by their owners. Only liveness and width changes come through
/// here; per-second text inside a strip observes its owner directly.
@MainActor
final class IslandActivityCenter: ObservableObject {
    @Published private(set) var strips: [IslandActivityKind: IslandCompactStrip] = [:]
    /// The person's pick from the activity picker; in memory only.
    @Published var choice = IslandActivityChoice()

    func set(_ strip: IslandCompactStrip?, for kind: IslandActivityKind) {
        if let strip { strips[kind] = strip } else { strips[kind] = nil }
        choice.reconcile(live: live, timerRunning: timerRunning)
    }

    var live: Set<IslandActivityKind> { Set(strips.keys) }
    var timerRunning: Bool { strips[.timer]?.isRunning == true }

    /// The strip the closed island shows, and the timer's companion if one was combined.
    var resolved: (primary: IslandCompactStrip, companion: IslandCompactStrip?)? {
        guard let pick = choice.resolve(live: live, timerRunning: timerRunning), let primary = strips[pick.primary] else { return nil }
        return (primary, pick.companion.flatMap { strips[$0] })
    }
}

/// The closed island's single notice slot: priority, duration and replacement rules.
@MainActor
final class IslandNoticeCenter: ObservableObject {
    @Published private(set) var current: IslandNotice?
    /// Set by the shell: notices are accepted only while the island is running, presentable, not
    /// hidden for full screen and not hidden until hover.
    var canShow: () -> Bool = { false }
    /// Set by the shell: whether an indicator is switched on in Settings › Activity.
    var indicatorEnabled: (IslandIndicatorID) -> Bool = { _ in false }
    private var dismissTask: Task<Void, Never>?

    /// Posts a notice. Returns false when it was dropped (lower priority, or the island cannot show it).
    @discardableResult
    func post(_ notice: IslandNotice) -> Bool {
        guard canShow(), notice.kind.replaces(current?.kind) else { return false }
        if var existing = current, existing.kind == notice.kind, notice.kind.isLevel {
            // The next volume step updates the text and meter in place; no new animation.
            existing.style = notice.style
            existing.label = notice.label
            current = existing
        } else {
            current = notice
        }
        scheduleDismiss(after: notice.kind.duration)
        return true
    }

    func dismiss() {
        dismissTask?.cancel(); dismissTask = nil
        current = nil
    }

    /// A banner under the pointer stays until the pointer leaves.
    func hold() { dismissTask?.cancel(); dismissTask = nil }

    /// The pointer left a held banner: it gets its full time again, counted from now.
    func resume() {
        guard let current, dismissTask == nil else { return }
        scheduleDismiss(after: current.kind.duration)
    }

    private func scheduleDismiss(after seconds: Double) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }
}

/// Everything a section, tile, card or module can reach: the app's stores, the island's settings,
/// the activity and notice centres, the presentation state and the shell's actions.
@MainActor
final class IslandEnvironment: ObservableObject {
    let monitoring: MonitoringStore
    let power: PowerStore
    let accounts: AccountsStore
    let settingsStore: IslandSettingsStore
    let activities = IslandActivityCenter()
    let notices = IslandNoticeCenter()
    /// Output/input volume and devices, filled in by the audio module.
    let systemAudio = IslandSystemAudio()
    /// Set by the music section: skip forward (true) or back. Returns false when nothing can skip.
    /// The shell's swipe gesture over music calls it.
    var musicSkip: ((Bool) -> Bool)?
    /// Set by the Files section: accepts files dropped on the island (the shell shows a drop target
    /// while files are dragged over it, or anywhere when "Show a drop target while dragging" is on).
    var fileDrop: (([URL]) -> Bool)?
    /// Set by the Files section: accepts a whole drag pasteboard (files, image data, links, text and
    /// file promises from Mail or browsers). The shell prefers it to `fileDrop`.
    var pasteboardDrop: ((NSPasteboard) -> Bool)?
    /// Set by the Files section: whether a drag under way anywhere should reveal the drop target
    /// (droppable content, not from an excluded app). `window` is the drag's source window number.
    var revealsDrag: ((NSPasteboard, Int) -> Bool)?
    /// Set by the Captures section while an area is being picked with the island's capture controls,
    /// so the shell keeps the island out of the way and above the selection overlay.
    @Published var captureControlsActive = false

    /// Presentation state, published by the shell.
    @Published var isRunning = false
    @Published var isOpen = false
    @Published var destination: IslandDestination?
    @Published var isKey = false
    @Published var isPinned = false
    /// The closed strip's height on the island's display (the camera height), for fitting wings.
    @Published var stripHeight: CGFloat = 32
    /// Whether the island hangs from a real camera notch (false: a cutout drawn on a display without one).
    @Published var stripIsPhysical = true
    /// Bumped whenever a section's availability or the set of registered tiles changes.
    @Published private(set) var revision = 0

    var actions = IslandActions()
    /// True in the render harness and tests: features must not install event taps, capture audio,
    /// open the camera or prompt for permissions.
    var isHeadless = false
    /// App-level actions the island hands back to the delegate.
    var showHubTab: (HubTab) -> Void = { _ in }
    var showMonitoring: () -> Void = {}
    var showPermissions: () -> Void = {}
    /// Opens Settings › Dynamic Island (set by the app delegate).
    var showSettings: (IslandSectionID?) -> Void = { _ in }
    /// The hub as an island page, and its visibility, when "Open app panel" is set to the island.
    var appPanel: (() -> AnyView)?
    var appPanelVisibility: (Bool) -> Void = { _ in }

    private(set) var sections: [IslandSectionID: any IslandSection] = [:]
    private(set) var features: [any IslandFeature] = []
    private(set) var controls: [IslandControlID: IslandControlModel] = [:]
    private(set) var cards: [IslandCardID: IslandCardProvider] = [:]
    private(set) var rests: [IslandRestContent: IslandRestProvider] = [:]
    private(set) var indicators: [IslandIndicatorID: () -> IslandAvailability] = [:]

    init(monitoring: MonitoringStore, power: PowerStore, accounts: AccountsStore, settings: IslandSettingsStore) {
        self.monitoring = monitoring
        self.power = power
        self.accounts = accounts
        self.settingsStore = settings
    }

    var settings: IslandSettings { settingsStore.value }

    func register(_ section: any IslandSection) {
        sections[section.id] = section
        features.append(section)
    }
    func register(module: any IslandFeature) { features.append(module) }
    func register(_ control: IslandControlModel) { controls[control.id] = control; revision += 1 }
    func register(card: IslandCardID, _ provider: IslandCardProvider) { cards[card] = provider; revision += 1 }
    func register(rest: IslandRestContent, _ provider: IslandRestProvider) { rests[rest] = provider; revision += 1 }
    /// The feature that raises an indicator says whether it can right now (Settings › Activity).
    func register(indicator: IslandIndicatorID, availability: @escaping () -> IslandAvailability) {
        indicators[indicator] = availability; revision += 1
    }
    func availability(of indicator: IslandIndicatorID) -> IslandAvailability { indicators[indicator]?() ?? .notBuilt }
    /// Whether an indicator should be raised now: switched on in settings and available.
    func wants(_ indicator: IslandIndicatorID) -> Bool {
        settings.enabled && settings.indicators.contains(indicator) && availability(of: indicator).isAvailable
    }

    func availability(of section: IslandSectionID) -> IslandAvailability {
        sections[section]?.availability ?? .notBuilt
    }

    func availability(of control: IslandControlID) -> IslandAvailability {
        controls[control]?.availability ?? .notBuilt
    }

    /// Sections the open island shows, in the person's order.
    var visibleSections: [IslandSectionID] {
        IslandNavigation.visibleSections(settings) { availability(of: $0).isAvailable }
    }

    /// The floating buttons the live island shows: those whose section or feature is unavailable are
    /// left out (their saved place is kept and they return when it is).
    var liveFloating: IslandFloatingLayout {
        IslandFloatingLayout(buttons: settings.floating.buttons.filter { button in
            switch button.action {
            case .explore, .settings, .pin: true
            case .section(let id): visibleSections.contains(id)
            case .control(let id): availability(of: id).isAvailable
            }
        })
    }

    /// Something a section owns changed shape; re-lay out and refresh editors.
    func invalidate() {
        revision += 1
        actions.invalidate()
    }

    func open(_ section: IslandSectionID) { actions.open(.section(section)) }
    func close() { actions.close() }
}
