import AppKit
import Combine
import EventKit
import IslandKit

/// Everything the Calendar page and the countdown share: permission, the events read, the page's
/// focus and selection, and the one refresh timer.
///
/// It reads only while something needs it: the island's page or the settings preview is on screen,
/// or the countdown is on while the island runs. Then it listens for EventKit and clock changes and
/// keeps one one-shot timer at the next moment something can change (at most 15 minutes away); it
/// never polls. Hiding the section or stopping the island drops everything it read, the store and
/// the countdown strip.
@MainActor
final class CalendarModel: ObservableObject {
    @Published private(set) var access: IslandCalendarAccess = .askable
    @Published private(set) var isRequesting = false
    /// The last request ended without a real answer. Stays visible until the next try.
    @Published private(set) var requestFailed = false
    @Published private(set) var events: [IslandCalendarEvent] = []
    /// False until the first read finishes: only then does the page show a spinner.
    @Published private(set) var hasLoaded = false
    @Published private(set) var text = IslandCalendarText()
    /// The day the week strip and month grid are built around.
    @Published private(set) var focus: Date
    /// Nil is the "Next 7 days" agenda.
    @Published private(set) var selectedDay: Date?
    /// The short island's month grid, which replaces the week strip and agenda until a day is chosen.
    @Published var showsMonth = false

    let preferences: CalendarPreferences
    private unowned let environment: IslandEnvironment
    private let source = CalendarEventSource()
    private let preview: CalendarPreviewData?

    private var running = false
    private var pageVisible = false
    private var previewViewers = 0
    private var observers: [NSObjectProtocol] = []
    private var observations: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
    private var generation = 0
    private var loadedPlan: [DateInterval] = []
    private var stripEvent: IslandCalendarEvent?

    init(environment: IslandEnvironment, preview: CalendarPreviewData?) {
        self.environment = environment
        self.preview = preview
        preferences = preview == nil ? CalendarPreferences() : CalendarPreferences(fixed: true)
        focus = Calendar.autoupdatingCurrent.startOfDay(for: Date())
        if let preview {
            access = IslandCalendarAccess(preview.status)
            requestFailed = preview.state == .failed
            selectedDay = preview.selectedDay(calendar: calendar)
            focus = selectedDay ?? focus
            showsMonth = preview.state == .month
        }
    }

    var calendar: Calendar { text.calendar }
    var today: Date { calendar.startOfDay(for: Date()) }

    private var sectionShown: Bool { environment.settings.enabled && environment.settings.isVisible(.calendar) }
    private var countdownWanted: Bool { running && sectionShown && preferences.countdown }
    /// The page (or its preview) is on screen, so the reader follows the page's month.
    private var pageShown: Bool { pageVisible || previewViewers > 0 }
    private var wantsReading: Bool { pageShown || countdownWanted }
    private var isWatching: Bool { !observers.isEmpty }

    // MARK: Lifecycle

    func islandDidStart() {
        running = true
        environment.settingsStore.$value
            .map { $0.enabled && $0.isVisible(.calendar) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.sync(refresh: true) } }
            .store(in: &observations)
        preferences.$countdown
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.sync(refresh: true) } }
            .store(in: &observations)
        sync(refresh: true)
    }

    func islandDidStop() {
        running = false
        pageVisible = false
        observations.removeAll()
        if previewViewers == 0 { resetPage() }
        sync(refresh: false)
    }

    func pageDidAppear() {
        pageVisible = true
        sync(refresh: true)
    }

    func pageDidDisappear() {
        pageVisible = false
        if previewViewers == 0 { resetPage() }
        // With the countdown still on, the reader goes back to the next seven days.
        sync(refresh: true)
    }

    /// The Settings preview shows the real page; it reads only while it is on screen.
    func previewAppeared() {
        previewViewers += 1
        sync(refresh: previewViewers == 1)
    }

    func previewDisappeared() {
        previewViewers = max(0, previewViewers - 1)
        if previewViewers == 0, !pageVisible { resetPage() }
        sync(refresh: previewViewers == 0)
    }

    private func sync(refresh force: Bool) {
        if wantsReading {
            let starting = !isWatching
            if starting { startObserving() }
            if starting || force { refresh() }
        } else {
            stopWatching()
        }
        // Hiding the section or stopping the island discards what was read.
        if !pageShown, !(running && sectionShown) { dropEvents() }
        if !countdownWanted { publishStrip(nil) }
    }

    // MARK: Reading

    func refreshAccess() {
        let status = preview?.status ?? CalendarEventSource.status
        let updated = IslandCalendarAccess(status)
        guard updated != access else { return }
        access = updated
        if updated == .granted { requestFailed = false }
        if isWatching { refresh() }
    }

    private func refresh() {
        guard wantsReading else { return }
        generation &+= 1
        let token = generation
        refreshTask?.cancel()
        refreshTask = nil
        access = IslandCalendarAccess(preview?.status ?? CalendarEventSource.status)
        guard access == .granted else {
            dropEvents()
            publishStrip(nil)
            return
        }
        requestFailed = false
        let now = Date()
        let plan = IslandCalendarWindow.plan(pageFocus: pageShown ? focus : nil, countdown: countdownWanted,
                                             now: now, calendar: calendar)
        loadedPlan = plan
        if let preview {
            apply(preview.events(now: now, calendar: calendar), now: now)
        } else if environment.isHeadless {
            // Renders never read the person's real calendars.
            apply([], now: now)
        } else {
            Task { [source, weak self] in
                let events = await source.events(in: plan)
                guard let self, token == self.generation else { return }
                self.apply(events, now: Date())
            }
        }
    }

    /// A read the page's new focus needs; moving within the loaded month reads nothing.
    private func reloadIfNeeded() {
        guard isWatching, access == .granted else { return }
        let plan = IslandCalendarWindow.plan(pageFocus: pageShown ? focus : nil, countdown: countdownWanted,
                                             now: Date(), calendar: calendar)
        if plan != loadedPlan { refresh() }
    }

    private func apply(_ events: [IslandCalendarEvent], now: Date) {
        if events != self.events { self.events = events }
        hasLoaded = true
        updateCountdown(now: now)
        let next = IslandCalendarSchedule.nextRefresh(after: now, events: events, countdown: countdownWanted, calendar: calendar)
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.5, next.timeIntervalSinceNow)), tolerance: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func dropEvents() {
        generation &+= 1
        loadedPlan = []
        if !events.isEmpty { events = [] }
        hasLoaded = false
    }

    // MARK: Observers

    private func startObserving() {
        let center = NotificationCenter.default
        let storeChanged: [Notification.Name] = [.EKEventStoreChanged, NSApplication.didBecomeActiveNotification]
        let clockChanged: [Notification.Name] = [.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged,
                                                 NSLocale.currentLocaleDidChangeNotification]
        // EventKit and the clock post from any thread: the handlers are not main-actor code, they hop.
        observers = storeChanged.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { @Sendable [weak self] _ in
                Task { @MainActor in self?.storeChanged() }
            }
        } + clockChanged.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { @Sendable [weak self] _ in
                Task { @MainActor in self?.clockChanged() }
            }
        }
    }

    private func stopWatching() {
        guard isWatching else { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        refreshTask?.cancel(); refreshTask = nil
        changeTask?.cancel(); changeTask = nil
        generation &+= 1
        loadedPlan = []
        Task { [source] in await source.release() }
    }

    /// EventKit announces a sync as a burst of changes; one read follows the burst.
    private func storeChanged() {
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func clockChanged() {
        text = IslandCalendarText()
        if selectedDay == nil { focus = today }
        refresh()
    }

    // MARK: Countdown

    private func updateCountdown(now: Date) {
        guard countdownWanted, access == .granted,
              let next = IslandCalendarCountdown.nextEvent(after: now, in: events),
              IslandCalendarCountdown.isLive(next, at: now) else { publishStrip(nil); return }
        publishStrip(next)
    }

    /// Republishes only when the event (and so the strip's width) changes.
    private func publishStrip(_ event: IslandCalendarEvent?) {
        guard event != stripEvent else { return }
        stripEvent = event
        environment.activities.set(event.map { CalendarCountdownStrip.make($0, text: text) }, for: .calendar)
    }

    // MARK: Page actions

    func tapStripDay(_ day: Date) {
        if day == selectedDay { showNextSevenDays() } else { select(day) }
    }

    /// Picks a day; from the month grid this also returns to the week strip.
    func select(_ day: Date) {
        selectedDay = day
        focus = day
        showsMonth = false
        reloadIfNeeded()
    }

    func showToday() { select(today) }

    /// "Next 7 days" is always about today, so it brings the week strip home too.
    func showNextSevenDays() {
        selectedDay = nil
        focus = today
        showsMonth = false
        reloadIfNeeded()
    }

    func moveWeek(_ direction: Int) {
        select(IslandCalendarDays.day(7 * direction, from: selectedDay ?? focus, calendar: calendar))
    }

    func moveMonth(_ direction: Int) {
        let first = IslandCalendarDays.month(direction, from: focus, calendar: calendar)
        selectedDay = first
        focus = first
        reloadIfNeeded()
    }

    private func resetPage() {
        selectedDay = nil
        focus = today
        showsMonth = false
    }

    func open(_ event: IslandCalendarEvent) {
        guard !environment.isHeadless else { return }
        CalendarApp.show(IslandCalendarLink.url(for: event, timeZone: calendar.timeZone))
    }

    func openCalendar() {
        guard !environment.isHeadless else { return }
        CalendarApp.show(nil)
    }

    // MARK: Permission

    /// Only a button press gets here. From the island, the island opens on this page first and stays
    /// open while the system dialog is up and for a second after, so clicking the dialog cannot
    /// collapse it. Never in renders.
    func requestAccess(fromIsland: Bool) {
        guard !environment.isHeadless, preview == nil, !isRequesting else { return }
        if fromIsland {
            environment.open(.calendar)
            environment.actions.holdOpen(true)
        }
        isRequesting = true
        requestFailed = false
        Task { [weak self] in
            _ = try? await EKEventStore().requestFullAccessToEvents()
            let status = CalendarEventSource.status
            guard let self else { return }
            isRequesting = false
            requestFailed = IslandCalendarAccess.requestFailed(statusAfterRequest: status)
            access = IslandCalendarAccess(status)
            if isWatching { refresh() }
            if fromIsland {
                try? await Task.sleep(for: .seconds(1))
                environment.actions.holdOpen(false)
            }
        }
    }

    func openPrivacySettings() {
        guard !environment.isHeadless,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Calendar.app, addressed by bundle identifier so another app claiming the `ical` scheme never gets
/// the link.
@MainActor
enum CalendarApp {
    static let bundleIdentifier = "com.apple.iCal"

    static func show(_ link: URL?) {
        let workspace = NSWorkspace.shared
        guard let app = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let link {
            workspace.open([link], withApplicationAt: app, configuration: configuration, completionHandler: nil)
        } else {
            workspace.openApplication(at: app, configuration: configuration, completionHandler: nil)
        }
    }
}
