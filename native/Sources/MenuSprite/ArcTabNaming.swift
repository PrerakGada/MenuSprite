import AppKit
import ApplicationServices
import SystemMonitoring

/// Names Arc's page processes on request: opens Arc's Task Manager for a moment,
/// reads which tab each process shows, closes it and hands focus back. Only the
/// PID → task-name link is kept; memory is still MenuSprite's own reading.
@MainActor
enum ArcTabNaming {
    static let bundleID = "company.thebrowser.Browser"
    private static var running = false

    static func name(processes: MemoryBoardStore) {
        guard !running else { return }
        guard let arc = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            processes.note("Arc is not running."); return
        }
        guard ChromiumTaskManager.isTrusted else {
            // Asked only because the user pressed the button; opening a board never asks.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            processes.note("MenuSprite needs Accessibility access to read Arc's Task Manager. Allow it in System Settings › Privacy & Security › Accessibility, then press the tag again.")
            return
        }
        running = true
        let previous = NSWorkspace.shared.frontmostApplication
        // Arc comes to the front for a moment; the board must not read that as the user leaving.
        PanelInteraction.hold(for: 6)
        processes.note("Reading Arc's Task Manager…")
        Task { @MainActor in
            defer { running = false }
            let outcome = await read(arc)
            if let previous, previous.processIdentifier != arc.processIdentifier { previous.activate() }
            processes.note(outcome)
            processes.resample()
        }
    }

    private static func read(_ arc: NSRunningApplication) async -> String {
        let pid = arc.processIdentifier
        let openedHere = ChromiumTaskManager.window(appPID: pid) == nil
        if openedHere {
            arc.activate()
            try? await Task.sleep(for: .milliseconds(300))
            var item = ChromiumTaskManager.menuItem(appPID: pid)
            // Arc enables the item only while one of its browser windows is in front.
            if item?.enabled != true, let window = ChromiumTaskManager.browserWindow(appPID: pid) {
                ChromiumTaskManager.raise(window)
                try? await Task.sleep(for: .milliseconds(300))
                item = ChromiumTaskManager.menuItem(appPID: pid)
            }
            guard let item else { return "This Arc version has no Task Manager command MenuSprite can find." }
            guard item.enabled else { return "Arc opens its Task Manager only while a browser window is open. Open an Arc window and press the tag again." }
            ChromiumTaskManager.press(item.item)
        }
        var window: AXUIElement?
        for _ in 0..<20 where window == nil {
            try? await Task.sleep(for: .milliseconds(150))
            window = ChromiumTaskManager.window(appPID: pid)
        }
        guard let window else { return "Arc's Task Manager did not open. Try again, or open it from Arc's command bar." }
        if openedHere {
            ChromiumTaskManager.showAllTasks(window)
            try? await Task.sleep(for: .milliseconds(300))
        }
        var rows: [ChromiumTaskManager.Row]?
        for _ in 0..<10 {
            rows = ChromiumTaskManager.readOpen(appPID: pid)
            if rows?.isEmpty == false { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        if openedHere { ChromiumTaskManager.close(window) }
        guard let rows, !rows.isEmpty else {
            return "Arc's Task Manager showed no Process ID column. Right-click its header, turn on Process ID, and press the tag again."
        }
        BrowserTabNames.shared.record(rows)
        let tabs = rows.filter { BrowserTabs.pageTitle($0.task) != nil }.count
        return "Named \(tabs) Arc tab\(tabs == 1 ? "" : "s"). New tabs stay unnamed until the next reading."
    }
}
