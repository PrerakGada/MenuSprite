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
        let width: CGFloat = 380
        let height = max(360, min(680, visible.height - 20))
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
        panel = nil
    }

    /// Closes on outside clicks, app switches, sleep and Space changes, like the other boards. Clicks on
    /// the sprite that opened the board are left to its button, which toggles the board.
    private func installDismissal() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { eventMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel, event.window !== self.anchorWindow { self.close() }
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
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

extension SpriteConfiguration {
    /// Sprites built only from AI usage readings open the accounts board instead of the generic board.
    var opensAccountsBoard: Bool { !metricIDs.isEmpty && metricIDs.allSatisfy { $0.hasPrefix("ai.") } }
}

struct AccountsBoard: View {
    @ObservedObject var store: AccountsStore
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "person.2.circle").foregroundStyle(Color(red: 0.72, green: 0.63, blue: 0.95))
                Text("AI Accounts").font(.system(size: 14, weight: .semibold))
                Spacer()
                if store.isLoading { ProgressView().controlSize(.mini) }
                Button { store.reload(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh usage").accessibilityLabel("Refresh usage")
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Close").accessibilityLabel("Close AI Accounts")
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let message = store.message {
                        MessageBanner(text: message) { store.message = nil }
                    }
                    ForEach(store.overview.problems, id: \.self) { problem in
                        Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(AIProvider.allCases) { provider in
                        ProviderSection(store: store, provider: provider)
                    }
                }
                .padding(14)
            }
            Divider()
            Text("Running Claude Code sessions follow a switch within about 30 seconds. Running Codex sessions keep their account — start a new session.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(provider.title).font(.headline)
                Spacer()
                Text(liveSummary(overview)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if provider == .codex && overview.codexUsesKeyring {
                Text(SwitchingError.codexKeyringMode.localizedDescription)
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if overview.live[provider] != nil && !overview.isLiveLoginSaved(provider) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(overview.liveEmail(provider).map { "\($0) is signed in but not saved. Save it so you can switch back without signing in again." }
                         ?? "The signed-in \(provider.title) login doesn't name its account yet.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button("Save current login") { store.saveCurrentLogin(provider) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(store.busy.contains(provider) || overview.liveEmail(provider) == nil)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            if rows.isEmpty {
                Text("No \(provider.title) accounts saved yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                AccountRowView(store: store, row: row, confirmingRemoval: $confirmingRemoval)
            }
            if let summary = store.spend[provider] {
                SpendLine(summary: summary)
            } else if !SpendPreference.isEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Estimate spend from your own session logs, at published API rates. The first pass reads every log on this Mac — minutes of work — and later passes take seconds.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Estimate spend") { store.setSpendEstimates(true) }.controlSize(.small)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            } else if store.isLoading {
                Text("Estimating spend from session logs…").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if store.signingIn.contains(provider) {
                    ProgressView().controlSize(.mini)
                    Text("Waiting for sign-in…").font(.caption)
                    Button("Cancel") { store.cancelSignIn(provider) }.controlSize(.small)
                } else {
                    Button("Add account…") { store.addAccount(provider) }
                        .controlSize(.small)
                        .disabled(store.busy.contains(provider) || (provider == .codex && overview.codexUsesKeyring))
                        .help("Saves the current login, then opens the \(provider.title) sign-in in Terminal")
                }
                Spacer()
                Toggle("Auto-switch", isOn: Binding(get: { autoSwitch }, set: { store.setAutoSwitch(provider, enabled: $0) }))
                    .toggleStyle(.switch).controlSize(.mini).font(.caption)
                    .help("Switch to another saved account when session or weekly usage reaches \(Int(overview.config.autoSwitchThreshold))%. Shared with Claude Switcher.")
            }
            if autoSwitch && store.claudeSwitcherRunning {
                Text("Claude Switcher is running — it handles auto-switch.").font(.caption2).foregroundStyle(.secondary)
            }
            if let status = store.autoSwitchStatus[provider] {
                Text(status).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                Image(systemName: row.isLive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(row.isLive ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.email).font(.system(size: 12, weight: row.isLive ? .semibold : .regular))
                        .lineLimit(1).truncationMode(.middle)
                    Text(planText(state)).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if row.isLive {
                    Text("Active").font(.caption.weight(.medium)).foregroundStyle(.green)
                } else {
                    Button("Switch") { store.switchAccount(row.provider, to: row.email) }
                        .controlSize(.small)
                        .disabled(busy || !row.hasCredential)
                        .help(row.hasCredential ? "Sign \(row.provider.title) in to \(row.email)" : "No saved login for this account — use Add account…")
                }
            }
            switch state {
            case .loaded(let snapshot)?:
                // Every window the provider reports, including model-scoped ones MenuSprite never expected.
                ForEach(snapshot.windows) { window in
                    UsageBar(label: window.label, window: window)
                }
                ForEach(detailLines(snapshot), id: \.self) { line in
                    Text(line).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let notice = snapshot.notice {
                    Text(notice).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            case .failed(let text)?:
                Text(text).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            case .loading?:
                Text("Loading usage…").font(.caption2).foregroundStyle(.secondary)
            case nil:
                if !row.hasCredential && !row.isLive {
                    Text("No saved login for this account.").font(.caption2).foregroundStyle(.orange)
                }
            }
            if row.isSaved {
                if confirmingRemoval == row.id {
                    HStack(spacing: 6) {
                        Text("Remove this saved login?").font(.caption2)
                        Spacer()
                        Button("Cancel") { confirmingRemoval = nil }.controlSize(.mini)
                        Button("Remove", role: .destructive) {
                            confirmingRemoval = nil
                            store.remove(row.provider, email: row.email)
                        }.controlSize(.mini)
                    }
                } else {
                    HStack {
                        Spacer()
                        Button("Remove…") { confirmingRemoval = row.id }
                            .buttonStyle(.borderless).font(.caption2)
                            .disabled(row.isLive || busy)
                            .help(row.isLive ? "Switch to another account before removing this one" : "Delete this saved login from MenuSprite and Claude Switcher")
                    }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.separator.opacity(0.4)))
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
            HStack(spacing: 10) {
                Text("Estimated spend").font(.caption.weight(.medium))
                Spacer()
                ForEach([("today", summary.today), ("7d", summary.last7Days), ("30d", summary.last30Days)], id: \.0) { period, value in
                    VStack(spacing: 0) {
                        Text(dollars(value)).font(.caption2.monospacedDigit())
                        Text(period).font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                }
            }
            Text(footnote).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
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

private struct UsageBar: View {
    let label: String
    let window: UsageWindow?

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(tint).frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 6)
            Text(window.map { "\(Int($0.usedPercent.rounded()))%" } ?? "—")
                .font(.caption2.monospacedDigit()).frame(width: 34, alignment: .trailing)
            Text(resetText).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(window.map { "\(Int($0.usedPercent.rounded())) percent used" } ?? "not reported"). \(resetText)")
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
        if minutes <= 0 { return "resets now" }
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
            Text(text).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless).accessibilityLabel("Dismiss message")
        }
        .padding(9)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
