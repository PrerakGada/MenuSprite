import Foundation
import ApplicationServices
import os

/// Arc runs every web page in an anonymous "Browser Helper (Renderer)" process.
/// Nothing a process exposes (path, arguments, sockets, windows) says which tab it
/// renders; only Arc's own Task Manager does, and it states each task's process
/// ID. MenuSprite reads that table through Accessibility, keeps only the
/// PID → task-name link, and measures each process itself. See docs/arc-tabs.md.
public enum BrowserTabs {
    public static let pagePrefix = "browser-page:"
    public static let framesSuffix = ":frames"
    public static let unnamedSuffix = ":unnamed"
    public static let browserSuffix = ":browser"

    /// Arc only for now: opening its Task Manager goes through Arc's own menu.
    public static func isBrowser(bundlePath: String?) -> Bool { bundlePath?.hasSuffix("/Arc.app") == true }
    public static func isRenderer(_ path: String) -> Bool { path.contains(" Helper (Renderer).app/") }
    public static func isGroup(_ consumer: MemoryConsumer) -> Bool { isBrowser(bundlePath: consumer.bundlePath) && consumer.members != nil }

    public enum Role: Sendable, Equatable { case page, frames, unnamed, browser }
    public static func role(of id: String) -> Role? {
        if id.hasPrefix(pagePrefix) { return .page }
        guard id.hasPrefix("app:") else { return nil }
        if id.hasSuffix(framesSuffix) { return .frames }
        if id.hasSuffix(unnamedSuffix) { return .unnamed }
        if id.hasSuffix(browserSuffix) { return .browser }
        return nil
    }

    /// "Tab: Gala ERP" → a page the user has open. Arc's Task Manager also lists
    /// subframes, extensions and workers in renderer processes, and the browser,
    /// GPU and utility processes under "All tasks".
    public static func pageTitle(_ label: String) -> String? {
        for prefix in ["Tab: ", "App: ", "Pinned Tab: ", "Incognito Tab: "] where label.hasPrefix(prefix) {
            let title = String(label.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        return nil
    }

    /// Splits Arc's processes so the members partition the group: one member per
    /// renderer showing at least one tab, one for renderers serving only embedded
    /// frames/extensions/workers, one for renderers not yet named, and one for the
    /// browser process with its GPU and utility helpers.
    static func members(groupID: String, _ records: [ProcessMemoryRecord], consumer: ([ProcessMemoryRecord], String, String) -> MemoryConsumer) -> [MemoryConsumer] {
        var pages: [ProcessMemoryRecord] = [], frames: [ProcessMemoryRecord] = [], unnamed: [ProcessMemoryRecord] = [], browser: [ProcessMemoryRecord] = []
        for record in records {
            guard isRenderer(record.executablePath) else { browser.append(record); continue }
            guard let tasks = record.context?.browserTasks, !tasks.isEmpty else { unnamed.append(record); continue }
            if tasks.contains(where: { pageTitle($0) != nil }) { pages.append(record) } else { frames.append(record) }
        }
        var result: [MemoryConsumer] = pages.map { page in
            let title: String = page.context?.browserTasks?.compactMap(pageTitle).first ?? page.name
            return consumer([page], pagePrefix + "\(page.pid):\(page.started)", title)
        }
        if !frames.isEmpty { result.append(consumer(frames, groupID + framesSuffix, "Embedded frames, extensions and workers")) }
        if !unnamed.isEmpty { result.append(consumer(unnamed, groupID + unnamedSuffix, "Pages not yet named")) }
        if !browser.isEmpty { result.append(consumer(browser, groupID + browserSuffix, "Arc")) }
        return result.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
    }
}

/// The PID → task-name links last read from Arc's Task Manager, shared by every
/// open board. Each link is tied to the process's birth stamp, so a reused PID
/// never inherits a closed tab's name. Held in memory only; nothing is written.
public final class BrowserTabNames: @unchecked Sendable {
    public static let shared = BrowserTabNames()
    public struct Names: Sendable, Equatable { public let started: UInt64; public let tasks: [String]; public let seen: Date }
    private let lock = OSAllocatedUnfairLock<[Int32: Names]>(initialState: [:])
    init() {}

    /// Replaces what one reading covered. `startTime` resolves a PID's birth stamp
    /// at the moment of reading, so the link names that exact process.
    @discardableResult
    public func record(_ rows: [ChromiumTaskManager.Row], at date: Date = Date(), startTime: (Int32) -> UInt64? = ProcessTermination.startTime) -> Int {
        var fresh: [Int32: Names] = [:]
        for (pid, tasks) in Dictionary(grouping: rows, by: \.pid) {
            guard let started = startTime(pid) else { continue }
            fresh[pid] = Names(started: started, tasks: tasks.map(\.task), seen: date)
        }
        // A reading is the whole table: a renderer missing from it has no tab any more.
        let reading = fresh
        lock.withLock { $0 = reading }
        return fresh.count
    }
    public func names(pid: Int32, started: UInt64) -> Names? {
        lock.withLock { current in current[pid].flatMap { $0.started == started ? $0 : nil } }
    }
    /// Forget processes that have exited.
    public func retain(_ pids: Set<Int32>) { lock.withLock { $0 = $0.filter { pids.contains($0.key) } } }
    public var isEmpty: Bool { lock.withLock { $0.isEmpty } }
}

/// Reads Chromium's Task Manager window through Accessibility. Every call is
/// bounded by a short messaging timeout, so a busy browser cannot stall a board.
public enum ChromiumTaskManager {
    public struct Row: Sendable, Equatable { public let task: String; public let pid: Int32
        public init(task: String, pid: Int32) { self.task = task; self.pid = pid } }
    public static let windowTitle = "Task Manager"
    public static let menuItemTitle = "Open Task Manager"

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    private static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        return app
    }
    static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }
    static func children(_ element: AXUIElement) -> [AXUIElement] { value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    static func title(_ element: AXUIElement) -> String { value(element, kAXTitleAttribute) as? String ?? "" }
    static func role(_ element: AXUIElement) -> String { value(element, kAXRoleAttribute) as? String ?? "" }

    public static func window(appPID: pid_t) -> AXUIElement? {
        guard isTrusted else { return nil }
        let windows = value(application(appPID), kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.first { title($0) == windowTitle }
    }

    /// Rows of the open Task Manager, or nil when it is not open or has no
    /// Process ID column. Rows still measuring ("–") already carry their PID.
    public static func readOpen(appPID: pid_t) -> [Row]? {
        guard let window = window(appPID: appPID), let table = find(in: window, role: kAXTableRole as String, depth: 12) else { return nil }
        return rows(of: table)
    }

    static func rows(of table: AXUIElement) -> [Row]? {
        let rows = children(table).filter { role($0) == kAXRowRole as String }
        guard let header = rows.first else { return nil }
        let columns = children(header).map(title)
        guard let task = columns.firstIndex(where: { $0.contains("Task") }),
              let pid = columns.firstIndex(where: { $0.contains("Process ID") }) else { return nil }
        return rows.dropFirst().compactMap { row in
            let cells = children(row).map(title)
            guard cells.indices.contains(max(task, pid)), let id = Int32(cells[pid].trimmingCharacters(in: .whitespaces)), id > 0 else { return nil }
            return Row(task: cells[task], pid: id)
        }
    }

    static func find(in element: AXUIElement, role wanted: String, depth: Int) -> AXUIElement? {
        guard depth > 0 else { return nil }
        for child in children(element) {
            if role(child) == wanted { return child }
            if let found = find(in: child, role: wanted, depth: depth - 1) { return found }
        }
        return nil
    }

    /// Arc keeps this item under Help › Troubleshooting and enables it only while
    /// one of its browser windows is in front.
    public static func menuItem(appPID: pid_t) -> (item: AXUIElement, enabled: Bool)? {
        guard let bar = value(application(appPID), kAXMenuBarAttribute) else { return nil }
        func walk(_ element: AXUIElement, _ depth: Int) -> AXUIElement? {
            if title(element) == menuItemTitle { return element }
            guard depth > 0 else { return nil }
            for child in children(element) { if let found = walk(child, depth - 1) { return found } }
            return nil
        }
        guard let item = walk(bar as! AXUIElement, 6) else { return nil }
        return (item, value(item, kAXEnabledAttribute) as? Bool ?? false)
    }
    @discardableResult
    public static func press(_ element: AXUIElement) -> Bool { AXUIElementPerformAction(element, kAXPressAction as CFString) == .success }

    /// Shows every task (browser, GPU, spare renderers), not only tabs, so fewer
    /// renderers stay unnamed. Harmless if the tab strip is absent.
    public static func showAllTasks(_ window: AXUIElement) {
        guard let group = find(in: window, role: kAXTabGroupRole as String, depth: 10) else { return }
        if let all = children(group).first(where: { title($0) == "All tasks" }) { press(all) }
    }
    /// The Task Manager's first standard window other than itself, for raising.
    public static func browserWindow(appPID: pid_t) -> AXUIElement? {
        let windows = value(application(appPID), kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.first { title($0) != windowTitle && (value($0, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole as String }
    }
    public static func raise(_ window: AXUIElement) { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
    public static func close(_ window: AXUIElement) {
        if let button = value(window, kAXCloseButtonAttribute) { press(button as! AXUIElement) }
    }
}
