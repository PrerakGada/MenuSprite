import AppKit
import Combine
import IslandKit
import SwiftUI

/// AI Agents: what Claude Code and Codex are working on, their plan limits and what the work is
/// worth at API prices.
///
/// Built on what MenuSprite already has rather than a reader of its own history: limits are the
/// server figures the AI readings fetch (shared with the menu bar through the monitoring store),
/// working sessions come from Claude Code's own registry plus the tails of the logs being written,
/// and costs come from the opt-in spend estimate's cache, which the island never starts. Nothing runs
/// unless the section is shown and the page, the live activity, a notice or the resting wings need it.
@MainActor
final class AgentsSection: IslandSection {
    let id = IslandSectionID.agents
    private unowned let environment: IslandEnvironment
    let optionStore = AgentsOptionsStore()
    let activity = AgentActivityService()
    let limits: AgentLimitsModel
    /// Agents whose folders exist on this Mac, looked up once, when first needed.
    private lazy var found: Set<AgentKind> = Self.lookForAgents()
    private var running = false
    private var pageVisible = false
    private var settingsObservation: AnyCancellable?
    private var optionsObservation: AnyCancellable?
    private var heightObservation: AnyCancellable?
    private var stripKey: StripKey?
    private var stripRefresh: Task<Void, Never>?
    private var restShows = false
    private var pageSignature: [String] = []

    /// The strip is re-published only when the working agents or the reading's shape change.
    private struct StripKey: Equatable {
        var agents: [AgentKind]
        var shape: String
        var reading: AgentReading
    }

    init(environment: IslandEnvironment) {
        self.environment = environment
        limits = AgentLimitsModel(monitoring: environment.monitoring, preview: environment.isHeadless)
        environment.register(rest: .aiLimits, IslandRestProvider { [weak self] in self?.restWings() })
        activity.onChange = { [weak self] in self?.dataChanged() }
        activity.onFinish = { [weak self] in self?.postFinish($0) }
        limits.onChange = { [weak self] in self?.dataChanged() }
        limits.onAlert = { [weak self] in self?.postAlert($0) }
        optionsObservation = optionStore.$value.dropFirst().sink { [weak self] _ in
            Task { @MainActor in
                self?.sync()
                self?.environment.invalidate()
            }
        }
    }

    var availability: IslandAvailability { .available }

    private var sectionOn: Bool {
        let settings = environment.settings
        return settings.enabled && settings.isVisible(.agents)
    }

    // MARK: Page

    func pageHeight(_ context: IslandPageContext) -> IslandPageHeight {
        .fixed(min(context.budget, layout(width: context.width).height))
    }

    func page(_ context: IslandPageContext) -> AnyView {
        if context.isPreview {
            // The preview starts nothing; it shows limits the menu bar's readings already fetched.
            let limits = self.limits, agents = optionStore.value.agents
            Task { @MainActor in limits.peek(agents: agents) }
        }
        let store = optionStore
        let actions = AgentsPageActions(openAccounts: { [weak environment] in environment?.showHubTab(.ai) },
                                        setPeriod: { period in store.update { $0.period = period } })
        return AnyView(AgentsPage(activity: activity, limits: limits, options: optionStore, found: found, sectionOn: sectionOn,
                                  context: context, actions: actions))
    }

    func options() -> AnyView? {
        AnyView(AgentsOptionsView(store: optionStore, found: found, spendEnabled: SpendPreference.isEnabled,
                                  openAccounts: { [weak environment] in environment?.showHubTab(.ai) }))
    }

    private func layout(width: CGFloat) -> AgentsLayout {
        AgentsLayout(options: optionStore.value, activity: activity, limits: limits, found: found, sectionOn: sectionOn, width: width)
    }

    // MARK: Lifecycle

    func islandDidStart() {
        running = true
        settingsObservation = environment.settingsStore.$value
            .map { [$0.enabled, $0.isVisible(.agents), $0.atRest == .aiLimits] }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.sync() } }
        heightObservation = environment.$stripHeight.removeDuplicates().dropFirst().sink { [weak self] _ in
            Task { @MainActor in
                self?.stripKey = nil
                self?.updateStrip()
            }
        }
        sync()
    }

    func islandDidStop() {
        running = false
        pageVisible = false
        settingsObservation = nil
        heightObservation = nil
        stripRefresh?.cancel(); stripRefresh = nil
        activity.stop()
        limits.stop()
        clearStrip()
        restShows = false
    }

    func pageDidAppear() {
        pageVisible = true
        sync()
    }

    func pageDidDisappear() {
        pageVisible = false
        sync()
    }

    /// Starts and stops the reader and the limits to match what is needed right now.
    private func sync() {
        let value = optionStore.value
        let on = sectionOn
        let background = running && on
        let page = pageVisible && on
        let wantsActivity = page || (background && (value.liveActivity || value.finishNotice))
        let hot = page || (value.liveActivity && (value.reading == .tokens || value.reading == .cost))
        activity.run(wantsActivity ? AgentActivityConfiguration(agents: value.agents, hot: hot) : nil)
        let rest = environment.settings.atRest == .aiLimits
        limits.configure(AgentLimitsModel.Demand(
            limits: background && (rest || value.limitWarning || (value.liveActivity && value.reading == .limit)),
            page: page, spend: page || (background && rest), agents: value.agents, warnAt: value.warnAt,
            warnings: background && value.limitWarning))
        dataChanged()
    }

    private func dataChanged() {
        updateStrip()
        updateRest()
        guard pageVisible else { return }
        let current = layout(width: 424)
        let signature = current.tiles.map(\.id) + ["\(current.state)"]
        if signature != pageSignature {
            pageSignature = signature
            environment.invalidate()
        }
    }

    // MARK: Closed island

    private func updateStrip() {
        let value = optionStore.value
        let now = Date()
        guard running, sectionOn, value.liveActivity,
              let content = AgentStripContent.make(activity.snapshot, windows: limits.windows, options: value, now: now) else {
            clearStrip()
            return
        }
        scheduleStripRefresh(at: content.nextChange)
        let agents = activity.snapshot.workingAgents.filter(value.isOn)
        let key = StripKey(agents: agents, shape: AgentStrip.shape(content.text(at: now)), reading: value.reading)
        guard key != stripKey else { return }
        stripKey = key
        var strip = IslandCompactStrip(
            kind: .agents, wing: content.wing(count: agents.count, now: now, height: environment.stripHeight),
            minimumRoom: AgentStrip.wingRange.lowerBound,
            left: AnyView(AgentStripMarks(activity: activity, options: optionStore)),
            right: AnyView(AgentStripReading(activity: activity, limits: limits, options: optionStore)),
            companionMark: AnyView(AgentStripMarks(activity: activity, options: optionStore, companion: true)),
            outline: nil)
        // Fitted to the camera's own height; with less than 44 pt of room the wings go, and a working
        // agent never drops below the camera.
        let count = agents.count
        strip.wingForRoom = { room, height in
            guard room >= AgentStrip.wingRange.lowerBound else { return 0 }
            return min(room, content.wing(count: count, now: Date(), height: height))
        }
        environment.activities.set(strip, for: .agents)
    }

    private func clearStrip() {
        stripRefresh?.cancel(); stripRefresh = nil
        guard stripKey != nil else { return }
        stripKey = nil
        environment.activities.set(nil, for: .agents)
    }

    /// The reading can change width without new data only at a clock digit or a renewal: wake then.
    private func scheduleStripRefresh(at date: Date?) {
        stripRefresh?.cancel()
        guard let date else { stripRefresh = nil; return }
        let delay = max(0.5, date.timeIntervalSinceNow + 0.25)
        stripRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.updateStrip()
        }
    }

    private var firstSeen: AgentKind? {
        let seen = found.union(activity.snapshot.seen)
        return AgentKind.allCases.first { optionStore.value.isOn($0) && seen.contains($0) }
    }

    private var restHasContent: Bool { sectionOn && (!limits.windows.isEmpty || firstSeen != nil) }

    /// Nil while the section is off or no agent has been seen: the island then rests empty, and a
    /// saved "AI limits" choice waits unchanged.
    private func restWings() -> (left: AnyView, right: AnyView)? {
        guard restHasContent else { return nil }
        return (AnyView(AgentRestLeft(limits: limits, options: optionStore, firstSeen: firstSeen)),
                AnyView(AgentRestRight(limits: limits, options: optionStore)))
    }

    private func updateRest() {
        let shows = restHasContent
        guard shows != restShows else { return }
        restShows = shows
        if environment.settings.atRest == .aiLimits { environment.invalidate() }
    }

    // MARK: Notices

    private func postFinish(_ turn: AgentFinishedTurn) {
        let value = optionStore.value
        guard running, sectionOn, value.finishNotice, value.isOn(turn.agent),
              AgentTurnRules.announcesFinish(completed: turn.completed, duration: turn.duration, minimum: value.finishMinimum,
                                             endedAt: turn.endedAt, now: Date(), armed: turn.armed) else { return }
        var detail = AgentFormat.duration(turn.duration)
        if let cost = turn.cost, cost > 0 { detail += " · " + AgentFormat.cost(cost) }
        post(title: "\(turn.agent.title) finished", detail: detail, symbol: turn.agent.symbol, tint: turn.agent.color)
    }

    private func postAlert(_ event: AgentLimitAlerts.Event) {
        let value = optionStore.value
        guard running, sectionOn, value.limitWarning else { return }
        switch event {
        case .warning(let window):
            guard value.isOn(window.agent) else { return }
            post(title: window.noticeTitle, detail: AgentLimits.phrase(window, display: value.limitDisplay, now: Date()),
                 symbol: "exclamationmark.triangle.fill", tint: .orange)
        case .renewed(let window):
            guard value.renewalNotice, value.isOn(window.agent) else { return }
            post(title: window.noticeTitle, detail: "Limit renewed", symbol: "arrow.clockwise", tint: window.agent.color)
        }
    }

    private func post(title: String, detail: String, symbol: String, tint: Color) {
        environment.notices.post(IslandNotice(kind: .agent,
                                              style: .text(symbol: symbol, image: nil, title: title, detail: detail, tint: tint),
                                              label: "\(title), \(detail)", destination: .agents))
    }

    private static func lookForAgents() -> Set<AgentKind> {
        let paths = AgentPaths.standard
        var found = Set<AgentKind>()
        if FileManager.default.fileExists(atPath: paths.claudeProjects.path) { found.insert(.claude) }
        if FileManager.default.fileExists(atPath: paths.codexSessions.path) { found.insert(.codex) }
        return found
    }
}
