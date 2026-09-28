import AppKit
import SwiftUI
import SystemMonitoring

/// A board's own dialog is a separate window, which the panel's outside-click
/// monitors would otherwise read as "the user left".
@MainActor
enum PanelInteraction {
    private static var depth = 0
    static var isSuspended: Bool { depth > 0 }
    @discardableResult
    static func suspended<T>(_ body: () -> T) -> T {
        depth += 1; defer { depth -= 1 }
        return body()
    }
    /// Quitting another app makes macOS activate a different one, which the board
    /// would read as the user leaving. Hold the board open across that handover.
    static func hold(for seconds: Double) {
        depth += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { depth -= 1 }
    }
}

/// A row that has been asked to quit and is still listed. Its button becomes a
/// force-quit button until the process goes away, so force quit costs one more
/// click on the same spot instead of a dialog — and is never the first thing a
/// click can do.
@MainActor
final class ProcessQuitArming: ObservableObject {
    static let shared = ProcessQuitArming()
    /// An armed row stops offering force quit after this long: a row still listed
    /// two minutes later is ordinary again, not a pending kill.
    private let window: TimeInterval = 120
    /// A second click this soon after the first is an impatient double-click on
    /// "quit", not a decision to force quit. It is ignored.
    private let settling: TimeInterval = 0.75
    @Published private var armed: [String: Date] = [:]
    func isArmed(_ id: String) -> Bool {
        guard let stamp = armed[id] else { return false }
        return Date().timeIntervalSince(stamp) < window
    }
    func acceptsForce(_ id: String) -> Bool {
        guard let stamp = armed[id], isArmed(id) else { return false }
        return Date().timeIntervalSince(stamp) >= settling
    }
    func arm(_ id: String) { armed[id] = Date() }
    func disarm(_ id: String) { armed[id] = nil }
    /// Rows that have gone from the list have quit; forget them.
    func retain(_ ids: Set<String>) {
        let live = armed.filter { ids.contains($0.key) && isArmed($0.key) }
        if live.count != armed.count { armed = live }
    }
}

/// Trailing quit buttons for the drawn process rows of the Memory, CPU and Power
/// boards. One reused button per visible row, positioned by the drawing view.
/// Rows are re-ranked every interval, so a button remembers the consumer it was
/// laid out for and acts on that row, never on whatever has since moved into its
/// position.
@MainActor
final class ProcessQuitButtons: NSObject {
    private let processes: MemoryBoardStore
    private var buttons: [NSButton] = []
    private var consumerIDs: [String] = []
    private let tint: NSColor?
    init(processes: MemoryBoardStore, tint: NSColor? = nil) {
        self.processes = processes; self.tint = tint
    }

    /// `rows` are the laid-out rows in drawing order with the button's frame.
    func layout(in view: NSView, rows: [(row: ProcessConsumerRate, frame: NSRect)]) {
        while buttons.count < rows.count {
            let button = NSButton(image: NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Quit")!,
                                  target: self, action: #selector(click(_:)))
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.tag = buttons.count
            view.addSubview(button)
            buttons.append(button)
        }
        consumerIDs = rows.map(\.row.id)
        ProcessQuitArming.shared.retain(Set(consumerIDs))
        for (index, button) in buttons.enumerated() {
            guard index < rows.count else { button.isHidden = true; continue }
            button.isHidden = false
            button.frame = rows[index].frame
            apply(rows[index].row, to: button)
        }
    }
    private func apply(_ row: ProcessConsumerRate, to button: NSButton) {
        switch BrowserTabs.role(of: row.id) {
        case .page?, .frames?:
            // Ending a page process crashes the tab rather than closing it.
            button.isHidden = true; return
        case .unnamed?:
            button.isEnabled = true
            button.image = NSImage(systemSymbolName: "tag.circle", accessibilityDescription: nil)
            button.contentTintColor = tint ?? .controlAccentColor
            button.toolTip = ProcessQuitAction.nameTabsLabel; button.setAccessibilityLabel(ProcessQuitAction.nameTabsLabel)
            return
        default: break
        }
        // A grouped row's trailing control opens it instead of quitting it.
        if !row.members.isEmpty {
            let open = processes.expanded.contains(row.id)
            button.isEnabled = true
            button.image = NSImage(systemSymbolName: open ? "chevron.down.circle" : "chevron.right.circle", accessibilityDescription: nil)
            button.contentTintColor = tint ?? .secondaryLabelColor
            let label = ProcessQuitAction.disclosureLabel(for: row, open: open)
            button.toolTip = label; button.setAccessibilityLabel(label)
            return
        }
        let plan = ProcessTermination.plan(for: row.consumer)
        let armed = ProcessQuitArming.shared.isArmed(row.id) && !plan.isOwnApplication
        button.isEnabled = plan.canQuit
        button.image = NSImage(systemSymbolName: armed ? "xmark.octagon.fill" : "xmark.circle", accessibilityDescription: nil)
        button.contentTintColor = !plan.canQuit ? .tertiaryLabelColor
            : armed ? .systemOrange : (tint ?? .secondaryLabelColor)
        let label = ProcessQuitAction.label(for: plan, armed: armed)
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    @objc private func click(_ sender: NSButton) {
        guard sender.tag < consumerIDs.count,
              let row = processes.row(id: consumerIDs[sender.tag]) else { return }
        if !row.members.isEmpty { processes.toggle(row.id); return }
        if BrowserTabs.role(of: row.id) == .unnamed { ArcTabNaming.name(processes: processes); return }
        ProcessQuitAction.click(row, processes: processes)
        apply(row, to: sender)
    }
}

/// Shared by the drawn panels and the hub's SwiftUI process lists, so both quit a
/// row the same way and report it in the same words.
@MainActor
enum ProcessQuitAction {
    static let nameTabsLabel = "Name these pages: opens Arc's Task Manager for a moment and reads which tab each process shows"
    static func disclosureLabel(for row: ProcessConsumerRate, open: Bool) -> String {
        if BrowserTabs.isGroup(row.consumer) { return (open ? "Hide" : "Show") + " what each Arc tab uses" }
        return (open ? "Hide" : "Show") + " \(row.consumer.presentation.title) sessions (\(row.members.count))"
            + (open ? "" : ". Quit them one at a time from there.")
    }
    static func label(for plan: ProcessQuitPlan, armed: Bool) -> String {
        if plan.browserPage { return "Close this tab in Arc to free its memory" }
        if plan.groupedSessions > 0 { return "Expand \(plan.title) to quit its \(plan.groupedSessions) sessions one at a time" }
        if plan.isOwnApplication { return "Quit MenuSprite" }
        if plan.blockedByOwnership { return "\(plan.title) belongs to another user; macOS does not permit quitting it from here" }
        if armed { return "Force quit \(plan.title) — it was asked to quit and is still running. Unsaved work is lost." }
        return "Quit \(plan.title)" + (plan.targets.count > 1 ? " and its \(plan.targets.count - 1) helper processes" : "")
            + ". Click again to force quit."
    }
    /// One click quits; the row's button then arms, and the next click on it
    /// forces. No dialog stands between the user and the next row.
    static func click(_ row: ProcessConsumerRate, processes: MemoryBoardStore) {
        let plan = ProcessTermination.plan(for: row.consumer)
        guard plan.canQuit else { return }
        if plan.isOwnApplication { NSApp.terminate(nil); return }
        let arming = ProcessQuitArming.shared
        if arming.isArmed(row.id) {
            guard arming.acceptsForce(row.id) else { return }
            perform(plan, forced: true, processes: processes)
            arming.disarm(row.id)
        } else {
            perform(plan, forced: false, processes: processes)
            arming.arm(row.id)
        }
    }
    static func perform(_ plan: ProcessQuitPlan, forced: Bool, processes: MemoryBoardStore) {
        guard !plan.isOwnApplication else { return }
        PanelInteraction.hold(for: 2)
        var outcomes: [ProcessSignalOutcome] = []
        // A running application is asked as a whole: macOS ends its helpers with
        // it, and an app can still refuse or prompt to save. Only processes with
        // no application to ask are signalled directly.
        let applications = plan.ownTargets.compactMap { target in
            NSRunningApplication(processIdentifier: target.pid).map { (target, $0) }
        }
        if applications.isEmpty {
            outcomes = plan.ownTargets.map { ProcessTermination.send(forced ? SIGKILL : SIGTERM, to: $0) }
        } else {
            outcomes = applications.map { target, application in
                guard ProcessTermination.startTime(of: target.pid) == target.started else { return .identityChanged }
                return (forced ? application.forceTerminate() : application.terminate()) ? .delivered : .notPermitted
            }
        }
        var note = ProcessTermination.summary(title: plan.title, outcomes: outcomes, forced: forced)
        if !forced, outcomes.contains(.delivered) { note += " Click again to force quit." }
        processes.note(note)
        // A cooperative app is gone in about a tenth of a second, but the list
        // samples every five. Without these the row sits there looking untouched,
        // which reads as "the click did nothing".
        processes.resample()
        for delay in [0.4, 1.2, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { processes.resample() }
        }
        guard !forced, outcomes.contains(.delivered) else { return }
        // Still listed seconds later means it did not go: an app can refuse a quit
        // request, and a helper can be restarted by whatever supervises it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            guard ProcessQuitArming.shared.isArmed(plan.id), processes.row(id: plan.id) != nil else { return }
            processes.note("\(plan.title) has not quit — it may be asking you to save, or something restarts it. Click again to force quit.")
        }
    }
}

/// The panels' row button, for a SwiftUI row.
struct ProcessQuitButton: View {
    let row: ProcessConsumerRate
    @ObservedObject var processes: MemoryBoardStore
    @ObservedObject private var arming = ProcessQuitArming.shared
    var body: some View {
        switch BrowserTabs.role(of: row.id) {
        case .page?, .frames?: Color.clear.frame(width: 16, height: 1)
        case .unnamed?:
            Button { ArcTabNaming.name(processes: processes) } label: { Image(systemName: "tag.circle").font(.system(size: 11)) }
                .buttonStyle(.plain).frame(width: 16).foregroundStyle(Color.accentColor)
                .help(ProcessQuitAction.nameTabsLabel).accessibilityLabel(ProcessQuitAction.nameTabsLabel)
        default:
            if !row.members.isEmpty { disclosure } else { quit }
        }
    }
    private var disclosure: some View {
        let open = processes.expanded.contains(row.id)
        return Button { processes.toggle(row.id) } label: {
            Image(systemName: open ? "chevron.down.circle" : "chevron.right.circle").font(.system(size: 11))
        }
        .buttonStyle(.plain).frame(width: 16).foregroundStyle(.secondary)
        .help(ProcessQuitAction.disclosureLabel(for: row, open: open))
        .accessibilityLabel(ProcessQuitAction.disclosureLabel(for: row, open: open))
    }
    private var quit: some View {
        let plan = ProcessTermination.plan(for: row.consumer)
        let armed = arming.isArmed(row.id) && !plan.isOwnApplication
        return Button {
            ProcessQuitAction.click(row, processes: processes)
        } label: {
            Image(systemName: armed ? "xmark.octagon.fill" : "xmark.circle").font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .frame(width: 16)
        .disabled(!plan.canQuit)
        .foregroundStyle(!plan.canQuit ? AnyShapeStyle(.tertiary) : armed ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
        .help(ProcessQuitAction.label(for: plan, armed: armed))
        .accessibilityLabel(ProcessQuitAction.label(for: plan, armed: armed))
    }
}
