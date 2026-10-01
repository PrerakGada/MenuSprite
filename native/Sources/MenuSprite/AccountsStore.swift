import AppKit
import AIAccounts

/// State behind the AI Accounts board and the background auto-switch check. Usage is loaded only
/// while the board is open; the auto-switch loop reads usage only for providers with auto-switch on.
/// Estimated spend reads every session log on the Mac. A first pass over this history is minutes of
/// work and hundreds of megabytes of parsing, so it happens because Prerak asked for it — never
/// because a board opened. Once on, refreshes are incremental and cost a second.
enum SpendPreference {
    private static let key = "MenuSprite.SpendEstimatesEnabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

@MainActor
final class AccountsStore: ObservableObject {
    enum UsageState: Equatable, Sendable {
        case loading
        case loaded(UsageSnapshot)
        case failed(String)
    }

    struct Row: Identifiable, Equatable, Sendable {
        let provider: AIProvider
        let email: String
        let plan: String
        /// The account the CLI is signed in to right now.
        let isLive: Bool
        /// Listed in accounts.json (an unsaved live login is shown too, so it can be saved).
        let isSaved: Bool
        let hasCredential: Bool
        var id: String { "\(provider.rawValue):\(email)" }
    }

    @Published private(set) var overview = AccountsOverview()
    @Published private(set) var usage: [String: UsageState] = [:]
    /// Estimated spend is per provider, not per account: local logs record the work, not the login.
    @Published private(set) var spend: [AIProvider: SpendSummary] = [:]
    @Published private(set) var busy: Set<AIProvider> = []
    @Published private(set) var signingIn: Set<AIProvider> = []
    @Published private(set) var isLoading = false
    /// True only while account usage is being asked for; spend scanning can run on for minutes after.
    @Published private(set) var isLoadingUsage = false
    /// Counts reload requests, so a validation run can tell a ⌘R reached the store.
    private(set) var reloadRequests = 0
    @Published private(set) var claudeSwitcherRunning = false
    @Published private(set) var autoSwitchStatus: [AIProvider: String] = [:]
    @Published var message: String?
    /// When the board last finished asking for usage, and when it will ask again while it stays open.
    @Published private(set) var lastReloadAt: Date?
    @Published private(set) var nextReloadAt: Date?
    /// The chosen interval; `UsageRefreshInterval.auto` (0) lets the service pace itself.
    @Published private(set) var refreshInterval: TimeInterval = UsageRefreshInterval.current
    /// When Auto next wants figures, as the service last reported it.
    private var autoDue: Date?
    var isAuto: Bool { refreshInterval == UsageRefreshInterval.auto }
    private(set) var isOpen = false
    /// The board can be on screen twice at once — its own panel and the hub's AI tab — so openings
    /// are counted and the usage data is released only when the last viewer goes away.
    private var openCount = 0

    let switcher: AccountSwitcher
    private let usageSource: any UsageFetching
    private let spendSource: (any SpendEstimating)?
    private let didSwitch: (AIProvider) -> Void
    private var loadTask: Task<Void, Never>?
    private var autoReloadTask: Task<Void, Never>?
    private var autoSwitchTask: Task<Void, Never>?
    private var signInTasks: [AIProvider: Task<Void, Never>] = [:]
    private var lastAutoAttempt: [AIProvider: Date] = [:]

    init(switcher: AccountSwitcher, usage: any UsageFetching, spend: (any SpendEstimating)? = nil,
         didSwitch: @escaping (AIProvider) -> Void) {
        self.switcher = switcher
        usageSource = usage
        spendSource = spend
        self.didSwitch = didSwitch
    }

    // MARK: Board

    func rows(_ provider: AIProvider) -> [Row] {
        let active = overview.activeEmail(provider)
        var rows = overview.config.accounts(for: provider).map { account in
            Row(provider: provider, email: account.email, plan: account.subscriptionType, isLive: account.email == active,
                isSaved: true, hasCredential: overview.savedCredentials.contains(account.id))
        }
        if let login = overview.live[provider], let email = login.email, !rows.contains(where: { $0.email == email }) {
            rows.insert(Row(provider: provider, email: email, plan: login.plan ?? "", isLive: true, isSaved: false, hasCredential: false), at: 0)
        }
        return rows
    }

    func opened() {
        openCount += 1
        isOpen = true
        reload(force: false)
    }

    /// Releases usage and cancels loading; the auto-switch loop keeps its own schedule.
    func closed() {
        openCount = max(0, openCount - 1)
        guard openCount == 0 else { return }
        isOpen = false
        loadTask?.cancel()
        loadTask = nil
        autoReloadTask?.cancel()
        autoReloadTask = nil
        nextReloadAt = nil
        isLoading = false
        isLoadingUsage = false
        usage = [:]
        spend = [:]
        message = nil
    }

    func reload(force: Bool) {
        loadTask?.cancel()
        reloadRequests += 1
        // ⌘R and the refresh button start Auto's ladder again from the shortest wait.
        let restart = force
        isLoading = true
        isLoadingUsage = true
        claudeSwitcherRunning = Self.claudeSwitcherIsRunning()
        let switcher = self.switcher
        let source = usageSource
        loadTask = Task { [weak self] in
            if restart { await source.restartAutoPacing() }
            let overview = await Task.detached(priority: .userInitiated) { switcher.overview() }.value
            guard let self, !Task.isCancelled else { return }
            self.overview = overview
            let rows = AIProvider.allCases.flatMap { self.rows($0) }.filter { $0.isLive || $0.hasCredential }
            let ids = Set(rows.map(\.id))
            usage = usage.filter { ids.contains($0.key) }
            for row in rows where usage[row.id] == nil { usage[row.id] = .loading }
            await withTaskGroup(of: (String, UsageState).self) { group in
                for row in rows {
                    let readLive = row.isLive && overview.live[row.provider] != nil
                    group.addTask {
                        let result = readLive
                            ? await source.activeUsage(row.provider, force: force)
                            : await source.savedUsage(row.provider, email: row.email, force: force)
                        switch result {
                        case .success(let snapshot): return (row.id, .loaded(snapshot))
                        case .failure(let error): return (row.id, .failed(error.localizedDescription))
                        }
                    }
                }
                for await (id, state) in group where !Task.isCancelled { usage[id] = state }
            }
            guard !Task.isCancelled else { return }
            isLoadingUsage = false
            lastReloadAt = Date()
            autoDue = await source.nextRefreshDate()
            scheduleAutoReload()
            // Scanned from local logs on its own schedule, so it never delays the account rows — and
            // only once Prerak has turned it on, because the first pass is minutes of parsing.
            if let source = self.spendSource, SpendPreference.isEnabled {
                for provider in AIProvider.allCases where !Task.isCancelled {
                    if let summary = await source.summary(provider, force: force) { self.spend[provider] = summary }
                }
            }
            if !Task.isCancelled { isLoading = false }
        }
    }

    /// The oldest usage figure on the board, so "updated" never claims fresher data than is shown.
    var dataUpdatedAt: Date? {
        usage.values.compactMap { state -> Date? in
            if case .loaded(let snapshot) = state { return snapshot.fetchedAt }
            return nil
        }.min()
    }

    func setRefreshInterval(_ seconds: TimeInterval) {
        guard UsageRefreshInterval.choices.contains(seconds), seconds != refreshInterval else { return }
        UsageRefreshInterval.current = seconds
        refreshInterval = seconds
        if isOpen { scheduleAutoReload() }
    }

    /// While the board is open, ask again as soon as the first figure on it goes stale. A figure the
    /// service kept serving past its interval (a rate-limit cooldown) would make that moment already
    /// past, so the board then waits one whole interval rather than asking every second.
    private func scheduleAutoReload() {
        autoReloadTask?.cancel()
        guard isOpen else { nextReloadAt = nil; return }
        let now = Date()
        // Auto's wait is decided by the service; the fixed choices are counted from each figure.
        let interval = isAuto ? UsageService.freshness : refreshInterval
        let expiries = isAuto ? [autoDue].compactMap { $0 } : usage.values.compactMap { state -> Date? in
            if case .loaded(let snapshot) = state { return snapshot.fetchedAt.addingTimeInterval(interval) }
            return nil
        }
        var next = expiries.min() ?? now.addingTimeInterval(interval)
        if next < now.addingTimeInterval(2) {
            next = (lastReloadAt ?? now).addingTimeInterval(interval)
            if next < now.addingTimeInterval(2) { next = now.addingTimeInterval(2) }
        }
        nextReloadAt = next
        autoReloadTask = Task { [weak self] in
            // A second past the moment, so the service's own cache (stamped just after the fetch) has expired too.
            try? await Task.sleep(for: .milliseconds(Int(max(0, next.timeIntervalSinceNow + 1) * 1000)))
            guard !Task.isCancelled, let self, self.isOpen else { return }
            self.reload(force: false)
        }
    }

    // MARK: Actions

    func switchAccount(_ provider: AIProvider, to email: String) {
        guard !busy.contains(provider), signInTasks[provider] == nil else { return }
        busy.insert(provider)
        message = nil
        let switcher = self.switcher
        let source = usageSource
        Task { [weak self] in
            let text: String
            var switched = false
            do {
                let outcome = try await switcher.switchAccount(provider, to: email)
                await source.invalidate(provider)
                text = Self.describe(outcome)
                switched = !outcome.alreadyActive
            } catch {
                text = error.localizedDescription
            }
            guard let self else { return }
            busy.remove(provider)
            message = text
            if switched { didSwitch(provider) }
            reload(force: false)
        }
    }

    func saveCurrentLogin(_ provider: AIProvider) {
        guard !busy.contains(provider) else { return }
        busy.insert(provider)
        message = nil
        let switcher = self.switcher
        Task { [weak self] in
            let text: String
            do {
                let account = try await switcher.saveCurrentLogin(provider)
                text = "Saved \(account.email) as a \(provider.title) account."
            } catch {
                text = error.localizedDescription
            }
            guard let self else { return }
            busy.remove(provider)
            message = text
            reload(force: false)
        }
    }

    func remove(_ provider: AIProvider, email: String) {
        guard !busy.contains(provider) else { return }
        busy.insert(provider)
        message = nil
        let switcher = self.switcher
        Task { [weak self] in
            let text: String
            do {
                try await switcher.removeAccount(provider, email: email)
                text = "Removed the saved \(provider.title) login for \(email)."
            } catch {
                text = error.localizedDescription
            }
            guard let self else { return }
            busy.remove(provider)
            message = text
            reload(force: false)
        }
    }

    /// Writes the flag shared with Claude Switcher, then checks straight away when turned on.
    /// Turning estimates on starts the first scan; turning them off stops asking and drops what was shown.
    func setSpendEstimates(_ enabled: Bool) {
        SpendPreference.isEnabled = enabled
        if enabled {
            message = "Estimating spend from your session logs. The first pass takes a few minutes; later ones are seconds."
            reload(force: false)
        } else {
            spend = [:]
            objectWillChange.send()
        }
    }

    func setAutoSwitch(_ provider: AIProvider, enabled: Bool) {
        overview.config.autoSwitch[provider.rawValue] = enabled
        let switcher = self.switcher
        Task { [weak self] in
            do {
                try await switcher.setAutoSwitch(provider, enabled: enabled)
            } catch {
                self?.message = error.localizedDescription
            }
            guard let self else { return }
            overview = await Task.detached(priority: .userInitiated) { switcher.overview() }.value
            if enabled { restartAutoSwitchMonitor() }
        }
    }

    /// Saves the current login, opens the CLI's sign-in in Terminal and saves the new login once it lands.
    func addAccount(_ provider: AIProvider) {
        guard signInTasks[provider] == nil, !busy.contains(provider) else { return }
        signingIn.insert(provider)
        message = "Finish signing in to \(provider.title) in Terminal. MenuSprite saves the account when it's done."
        let switcher = self.switcher
        let source = usageSource
        signInTasks[provider] = Task { [weak self] in
            var script: URL?
            var text: String
            var added = false
            do {
                let previous = await Task.detached { try? switcher.liveLogin(provider) }.value
                // Keep the current login reachable before the CLI replaces it.
                if previous != nil { try await switcher.saveCurrentLogin(provider) }
                script = try await Task.detached { try switcher.launchSignIn(provider) }.value
                if let account = try await switcher.waitForSignIn(provider, replacing: previous) {
                    await source.invalidate(provider)
                    text = "Saved \(account.email) as a \(provider.title) account and signed in to it."
                    added = true
                } else {
                    text = "No new \(provider.title) sign-in was detected within five minutes."
                }
            } catch is CancellationError {
                text = "Stopped waiting for the \(provider.title) sign-in."
            } catch {
                text = error.localizedDescription
            }
            if let script { try? FileManager.default.removeItem(at: script) }
            guard let self else { return }
            signingIn.remove(provider)
            signInTasks[provider] = nil
            message = text
            if added { didSwitch(provider) }
            if isOpen { reload(force: false) }
        }
    }

    func cancelSignIn(_ provider: AIProvider) { signInTasks[provider]?.cancel() }

    // MARK: Auto-switch

    /// Checks every five minutes. Does nothing for providers without auto-switch, and nothing at all
    /// while Claude Switcher runs, so the two apps never switch the same login.
    func startAutoSwitchMonitor() {
        guard autoSwitchTask == nil else { return }
        autoSwitchTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let store = self else { return }
                    await store.autoSwitchTick()
                }
                try? await Task.sleep(for: .seconds(AutoSwitchPolicy.cadence))
            }
        }
    }

    func stop() {
        autoReloadTask?.cancel()
        autoReloadTask = nil
        autoSwitchTask?.cancel()
        autoSwitchTask = nil
        loadTask?.cancel()
        loadTask = nil
        for task in signInTasks.values { task.cancel() }
        signInTasks = [:]
    }

    private func restartAutoSwitchMonitor() {
        autoSwitchTask?.cancel()
        autoSwitchTask = nil
        startAutoSwitchMonitor()
    }

    private func autoSwitchTick() async {
        let switcher = self.switcher
        let overview = await Task.detached(priority: .utility) { switcher.overview() }.value
        let config = overview.config
        let running = Self.claudeSwitcherIsRunning()
        claudeSwitcherRunning = running
        for provider in AIProvider.allCases {
            guard config.isAutoSwitchEnabled(provider), !running else { continue }
            guard !busy.contains(provider), signInTasks[provider] == nil, let activeEmail = overview.activeEmail(provider) else { continue }
            guard case .success(let activeUsage) = await usageSource.activeUsage(provider, force: false),
                  AutoSwitchPolicy.isExhausted(activeUsage, threshold: config.autoSwitchThreshold) else { continue }
            if let last = lastAutoAttempt[provider], Date().timeIntervalSince(last) < AutoSwitchPolicy.cooldown { continue }
            var candidates: [String: UsageSnapshot] = [:]
            for account in config.accounts(for: provider) where account.email != activeEmail && overview.savedCredentials.contains(account.id) {
                if case .success(let snapshot) = await usageSource.savedUsage(provider, email: account.email, force: false) {
                    candidates[account.email] = snapshot
                }
            }
            let now = Date()
            let decision = AutoSwitchPolicy.decide(
                provider: provider, enabled: true, threshold: config.autoSwitchThreshold,
                claudeSwitcherRunning: Self.claudeSwitcherIsRunning(), activeEmail: activeEmail, activeUsage: activeUsage,
                lastAttempt: lastAutoAttempt[provider], now: now, accounts: config.accounts, usage: candidates,
                hasCredential: { overview.savedCredentials.contains($0.id) })
            let time = now.formatted(date: .omitted, time: .shortened)
            switch decision {
            case .switchTo(let email):
                lastAutoAttempt[provider] = now
                busy.insert(provider)
                do {
                    _ = try await switcher.switchAccount(provider, to: email)
                    await usageSource.invalidate(provider)
                    didSwitch(provider)
                    autoSwitchStatus[provider] = "Auto-switched from \(activeEmail) to \(email) at \(time)."
                } catch {
                    autoSwitchStatus[provider] = "Auto-switch to \(email) failed at \(time): \(error.localizedDescription)"
                }
                busy.remove(provider)
                if isOpen { reload(force: false) }
            case .noTarget:
                lastAutoAttempt[provider] = now
                autoSwitchStatus[provider] = "\(activeEmail) reached its limit at \(time); no other saved account has room."
            case .disabled, .handledByClaudeSwitcher, .notExhausted, .coolingDown:
                break
            }
        }
    }

    // MARK: Helpers

    static func claudeSwitcherIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: AutoSwitchPolicy.claudeSwitcherBundleID).isEmpty
    }

    private static func describe(_ outcome: SwitchOutcome) -> String {
        let title = outcome.provider.title
        guard !outcome.alreadyActive else {
            return "\(outcome.email) is already the signed-in \(title) account; its saved copy was refreshed."
        }
        let sessions = outcome.provider == .claude
            ? "Running Claude Code sessions follow within about 30 seconds."
            : "Start a new Codex session to use it; running sessions keep the previous account."
        return (["Switched \(title) to \(outcome.email). \(sessions)"] + outcome.notes).joined(separator: " ")
    }
}
