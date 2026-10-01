import AIAccounts
import AppKit
import SwiftUI
import SystemMonitoring

/// Shows the AI Accounts board in the same borderless key panel style as the memory and energy boards.
/// The panel, its hosting view and the loaded usage are released when it closes.
@MainActor
final class AccountsPanelController: NSObject, NSWindowDelegate {
    private let store: AccountsStore
    private var panel: AccountsPanel?
    private weak var anchorWindow: NSWindow?
    private var eventMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    init(store: AccountsStore) {
        self.store = store
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(anchor: NSRect?, anchorWindow: NSWindow?) {
        if isVisible { close() } else { show(anchor: anchor, anchorWindow: anchorWindow) }
    }

    func show(anchor: NSRect?, anchorWindow: NSWindow?) {
        if let panel { panel.makeKeyAndOrderFront(nil); return }
        self.anchorWindow = anchorWindow
        let screen = anchorWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 850)
        let anchor = anchor ?? NSRect(x: visible.maxX - 20, y: visible.maxY + 6, width: 1, height: 1)
        let width: CGFloat = 440
        let height = max(420, min(900, visible.height - 20))
        let origin = NSPoint(x: min(max(anchor.midX - width / 2, visible.minX + 8), visible.maxX - width - 8),
                             y: max(visible.minY + 8, anchor.minY - height - 6))
        let panel = AccountsPanel(contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "MenuSprite — AI Accounts"
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.dismiss = { [weak self] in self?.close() }
        panel.reload = { [weak self] in self?.store.reload(force: true) }
        panel.delegate = self
        let hosting = NSHostingController(rootView: AccountsBoard(store: store, close: { [weak self] in self?.close() }))
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        panel.setContentSize(NSSize(width: width, height: height))
        self.panel = panel
        store.opened()
        panel.makeKeyAndOrderFront(nil)
        installDismissal()
    }

    func close() { panel?.close() }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        eventMonitors = []
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        store.closed()
        panel?.contentViewController = nil
        panel?.delegate = nil
        panel?.dismiss = nil
        panel?.reload = nil
        panel = nil
    }

    /// Closes on outside clicks, app switches, sleep and Space changes, like the other boards. Clicks on
    /// the sprite that opened the board are left to its button, which toggles the board.
    private func installDismissal() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !PanelAnchor.pointerIsOver(self.anchorWindow) else { return }
                self.close()
            }
        }) { eventMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel, event.window !== self.anchorWindow,
                   !PanelAnchor.pointerIsOver(self.anchorWindow) { self.close() }
            }
            return event
        }) { eventMonitors.append(local) }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let activatedPID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    if let activatedPID {
                        if activatedPID == ProcessInfo.processInfo.processIdentifier { return }
                        if NSWorkspace.shared.frontmostApplication?.processIdentifier != activatedPID { return }
                    }
                    self?.close()
                }
            })
        }
    }
}

@MainActor
final class AccountsPanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var reload: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { dismiss?() }
    /// A borderless panel in a menu-bar app has no menu to carry ⌘R, so the panel answers it itself.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.isReloadShortcut, let reload { reload(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// A menu-bar panel is toggled by the status item that opened it. Outside-click dismissal must leave a
/// click on that item alone: otherwise the mouse-down closes the panel and the item's action, arriving
/// after it, finds the panel closed and opens it again — a second click could never close it.
enum PanelAnchor {
    static func pointerIsOver(_ itemWindow: NSWindow?) -> Bool {
        guard let itemWindow, itemWindow.isVisible else { return false }
        return itemWindow.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }
}

extension NSEvent {
    /// ⌘R with no other modifier.
    var isReloadShortcut: Bool {
        type == .keyDown && modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command
            && charactersIgnoringModifiers?.lowercased() == "r"
    }
}

extension SpriteConfiguration {
    /// Sprites built only from AI usage readings open the accounts board instead of the generic board.
    var opensAccountsBoard: Bool { !metricIDs.isEmpty && metricIDs.allSatisfy { $0.hasPrefix("ai.") } }
}

struct AccountsBoard: View {
    @ObservedObject var store: AccountsStore
    let close: () -> Void
    /// Inside the hub the surrounding panel already supplies a title, refresh and close, so the
    /// board drops its own header rather than showing a second one.
    var embedded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !embedded {
            HStack(spacing: 8) {
                Image(systemName: "person.2.circle").font(.system(size: 15))
                    .foregroundStyle(Color(red: 0.72, green: 0.63, blue: 0.95))
                Text("AI Accounts").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { store.reload(force: true) } label: { Image(systemName: "arrow.clockwise").font(.system(size: 13)) }
                    .buttonStyle(.borderless).help("Refresh usage (⌘R)").accessibilityLabel("Refresh usage")
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 13)) }
                    .buttonStyle(.borderless).help("Close").accessibilityLabel("Close AI Accounts")
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 9)
            Divider()
            }
            ReloadStrip(store: store)
                .padding(.horizontal, 14).padding(.vertical, 9)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let message = store.message {
                        MessageBanner(text: message) { store.message = nil }
                    }
                    ForEach(store.overview.problems, id: \.self) { problem in
                        Text(problem).font(.system(size: 13)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(AIProvider.allCases) { provider in
                        ProviderSection(store: store, provider: provider)
                    }
                }
                .padding(14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// When the figures on the board were fetched, when the board asks again, and how often. The countdown
/// redraws once a second only while the board is on screen.
private struct ReloadStrip: View {
    @ObservedObject var store: AccountsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 8) {
                    if store.isLoadingUsage {
                        ProgressView().controlSize(.small)
                        Text("Reloading…").font(.system(size: 12, weight: .medium))
                    } else {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(updatedText(now: context.date)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                    }
                    Spacer(minLength: 6)
                    if let next = store.nextReloadAt, !store.isLoadingUsage {
                        Text("Next in \(Self.countdown(next.timeIntervalSince(context.date)))")
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    }
                    Text("⌘R").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                        .help("Press ⌘R to reload now")
                }
            }
            HStack(spacing: 10) {
                Text("Reload").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("Reload", selection: Binding(get: { store.refreshInterval },
                                                               set: { store.setRefreshInterval($0) })) {
                    ForEach(UsageRefreshInterval.choices, id: \.self) { seconds in
                        Text(seconds == UsageRefreshInterval.auto ? "Auto" : "\(Int(seconds / 60))m").tag(seconds)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .help("Auto asks every 2 minutes while you are using AI, backs off towards an hour when nothing changes, and asks every minute when the 5-hour session is nearly full. ⌘R starts it again from 2 minutes. The menu-bar readings follow the same choice.")
            }
        }
        .accessibilityIdentifier("ai-reload-strip")
    }

    private func updatedText(now: Date) -> String {
        guard let updated = store.dataUpdatedAt else { return store.lastReloadAt == nil ? "Not loaded yet" : "No usage figures" }
        let seconds = max(0, Int(now.timeIntervalSince(updated)))
        let age = seconds < 60 ? "\(seconds)s" : seconds < 3600 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds / 3600)h \((seconds % 3600) / 60)m"
        return "Updated \(age) ago · \(updated.formatted(date: .omitted, time: .shortened))"
    }

    static func countdown(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.up)))
        if seconds >= 3600 { return String(format: "%dh %02dm", seconds / 3600, (seconds % 3600) / 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct ProviderSection: View {
    @ObservedObject var store: AccountsStore
    let provider: AIProvider
    @State private var confirmingRemoval: String?

    var body: some View {
        let overview = store.overview
        let rows = store.rows(provider)
        let autoSwitch = overview.config.isAutoSwitchEnabled(provider)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(provider.title).font(.system(size: 16, weight: .bold))
                Spacer()
                Text(liveSummary(overview)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if provider == .codex && overview.codexUsesKeyring {
                Text(SwitchingError.codexKeyringMode.localizedDescription)
                    .font(.system(size: 13)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if overview.live[provider] != nil && !overview.isLiveLoginSaved(provider) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(overview.liveEmail(provider).map { "\($0) is signed in but not saved. Save it so you can switch back without signing in again." }
                         ?? "The signed-in \(provider.title) login doesn't name its account yet.")
                        .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    Button("Save current login") { store.saveCurrentLogin(provider) }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.busy.contains(provider) || overview.liveEmail(provider) == nil)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            if rows.isEmpty {
                Text("No \(provider.title) accounts saved yet.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                AccountRowView(store: store, row: row, confirmingRemoval: $confirmingRemoval)
            }
            if let summary = store.spend[provider] {
                SpendLine(summary: summary)
            } else if !SpendPreference.isEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Estimate spend from your own session logs, at published API rates. The first pass reads every log on this Mac — minutes of work — and later passes take seconds.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Estimate spend") { store.setSpendEstimates(true) }.controlSize(.small)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            } else if store.isLoading {
                Text("Estimating spend from session logs…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if store.signingIn.contains(provider) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for sign-in…").font(.system(size: 13))
                    Button("Cancel") { store.cancelSignIn(provider) }
                } else {
                    Button("Add account…") { store.addAccount(provider) }
                        .controlSize(.small)
                        .disabled(store.busy.contains(provider) || (provider == .codex && overview.codexUsesKeyring))
                        .help("Saves the current login, then opens the \(provider.title) sign-in in Terminal")
                }
                Spacer()
                Toggle("Auto-switch", isOn: Binding(get: { autoSwitch }, set: { store.setAutoSwitch(provider, enabled: $0) }))
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 12))
                    .help("Switch to another saved account when session or weekly usage reaches \(Int(overview.config.autoSwitchThreshold))%. Shared with Claude Switcher.")
            }
            if autoSwitch && store.claudeSwitcherRunning {
                Text("Claude Switcher is running — it handles auto-switch.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let status = store.autoSwitchStatus[provider] {
                Text(status).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func liveSummary(_ overview: AccountsOverview) -> String {
        guard let login = overview.live[provider] else { return "Not signed in" }
        return login.email.map { "Signed in: \($0)" } ?? "Signed in"
    }
}

private struct AccountRowView: View {
    @ObservedObject var store: AccountsStore
    let row: AccountsStore.Row
    @Binding var confirmingRemoval: String?

    var body: some View {
        let state = store.usage[row.id]
        let busy = store.busy.contains(row.provider) || store.signingIn.contains(row.provider)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: row.isLive ? "checkmark.circle.fill" : "circle").font(.system(size: 14))
                    .foregroundStyle(row.isLive ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.email).font(.system(size: 13, weight: row.isLive ? .semibold : .regular))
                        .lineLimit(1).truncationMode(.middle)
                    Text(planText(state)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if row.isSaved && confirmingRemoval != row.id {
                    Button("Remove…") { confirmingRemoval = row.id }
                        .buttonStyle(.borderless).font(.system(size: 11))
                        .disabled(row.isLive || busy)
                        .help(row.isLive ? "Switch to another account before removing this one" : "Delete this saved login from MenuSprite and Claude Switcher")
                }
                if row.isLive {
                    Text("Active").font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
                } else {
                    Button("Switch") { store.switchAccount(row.provider, to: row.email) }
                        .controlSize(.small)
                        .disabled(busy || !row.hasCredential)
                        .help(row.hasCredential
                              ? "Sign \(row.provider.title) in to \(row.email). " + (row.provider == .claude
                                  ? "Running Claude Code sessions follow within about 30 seconds."
                                  : "Running Codex sessions keep their account — start a new session.")
                              : "No saved login for this account — use Add account…")
                }
            }
            if confirmingRemoval == row.id {
                HStack(spacing: 8) {
                    Text("Remove this saved login?").font(.system(size: 12))
                    Spacer()
                    Button("Cancel") { confirmingRemoval = nil }.controlSize(.small)
                    Button("Remove", role: .destructive) {
                        confirmingRemoval = nil
                        store.remove(row.provider, email: row.email)
                    }.controlSize(.small)
                }
            }
            switch state {
            case .loaded(let snapshot)?:
                // Every window the provider reports, including model-scoped ones MenuSprite never expected.
                ForEach(snapshot.windows) { window in
                    UsageBar(label: window.label, window: window)
                }
                ForEach(detailLines(snapshot), id: \.self) { line in
                    Text(line).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let notice = snapshot.notice {
                    Text(notice).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            case .failed(let text)?:
                Text(text).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            case .loading?:
                Text("Loading usage…").font(.system(size: 12)).foregroundStyle(.secondary)
            case nil:
                if !row.hasCredential && !row.isLive {
                    Text("No saved login for this account.").font(.system(size: 12)).foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.4)))
    }

    /// The figures the providers report beside their windows: where the week went, extra usage,
    /// credits and reset credits. Each line appears only when the provider actually sent it.
    private func detailLines(_ snapshot: UsageSnapshot) -> [String] {
        var lines: [String] = []
        if !snapshot.breakdown.isEmpty {
            lines.append("This week: " + snapshot.breakdown.filter { $0.percent > 0 }
                .map { "\($0.label) \(Int($0.percent.rounded()))%" }.joined(separator: " · "))
        }
        if let extra = snapshot.extraUsage {
            let cap = extra.limitDollars.map { String(format: " of $%.2f", $0) } ?? ""
            lines.append(String(format: "Extra usage: $%.2f", extra.usedDollars) + cap + " · " + (extra.enabled ? "on" : "off"))
        }
        if let credits = snapshot.creditsRemaining {
            let value = snapshot.creditDollars.map { String(format: " · $%.2f", $0) } ?? ""
            lines.append("Credits: \(Int(credits))\(value)")
        }
        if let resets = snapshot.resetCredits {
            let next = resets.expiries.first.map { " · next expires \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
            lines.append("Rate-limit resets: \(resets.available)\(next)")
        }
        return lines
    }

    private func planText(_ state: AccountsStore.UsageState?) -> String {
        if case .loaded(let snapshot)? = state, let plan = snapshot.plan { return plan }
        if !row.isSaved { return "Signed in · not saved" }
        return row.plan.isEmpty ? "Plan unknown" : row.plan.capitalized
    }
}

/// Reconstructed from this Mac's own session logs at published API rates — never money charged,
/// because a subscription already covers the work.
private struct SpendLine: View {
    let summary: SpendSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Text("Estimated spend").font(.system(size: 12, weight: .medium))
                Spacer()
                ForEach([("today", summary.today), ("7d", summary.last7Days), ("30d", summary.last30Days)], id: \.0) { period, value in
                    VStack(spacing: 1) {
                        Text(dollars(value)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(period).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            Text(footnote).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footnote: String {
        var parts = ["At published API rates, not money charged"]
        if summary.partial { parts.append("still scanning") }
        if !summary.unpricedModels.isEmpty {
            parts.append("no published rate for " + summary.unpricedModels.prefix(2).joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    private func dollars(_ value: Double) -> String { String(format: value < 10 ? "$%.2f" : "$%.0f", value) }
}

/// One limit window on one line: name, bar, time to reset, and the percentage large enough to read at a glance.
private struct UsageBar: View {
    let label: String
    let window: UsageWindow?

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .frame(width: 96, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(tint).frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 7)
            Text(resetText).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1).frame(width: 58, alignment: .trailing)
            Text(window.map { "\(Int($0.usedPercent.rounded()))%" } ?? "—")
                .font(.system(size: 17, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(window == nil ? Color.secondary : Color.primary)
                .frame(width: 52, alignment: .trailing)
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(window.map { "\(Int($0.usedPercent.rounded())) percent used" } ?? "not reported"). Resets in \(resetText)")
        .help(resetText.isEmpty ? label : "\(label) resets in \(resetText)")
    }

    private var fraction: CGFloat { CGFloat(min(1, max(0, (window?.usedPercent ?? 0) / 100))) }

    private var tint: Color {
        let percent = window?.usedPercent ?? 0
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return Color(red: 0.47, green: 0.87, blue: 0.74)
    }

    private var resetText: String {
        guard let date = window?.resetsAt else { return "" }
        let minutes = Int(date.timeIntervalSinceNow / 60)
        if minutes <= 0 { return "now" }
        if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

private struct MessageBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless).accessibilityLabel("Dismiss message")
        }
        .padding(11)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }
}
