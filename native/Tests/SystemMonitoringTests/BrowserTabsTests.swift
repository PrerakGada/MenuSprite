import Foundation
import Testing
@testable import SystemMonitoring

private let arc = "/Applications/Arc.app"
private let renderer = arc + "/Contents/Frameworks/ArcCore.framework/Helpers/Browser Helper (Renderer).app/Contents/MacOS/Browser Helper (Renderer)"
private let helper = arc + "/Contents/Frameworks/ArcCore.framework/Helpers/Browser Helper.app/Contents/MacOS/Browser Helper"
private let seen = Date(timeIntervalSince1970: 1_000_000)
private func record(_ pid: Int32, _ path: String, bytes: UInt64, tasks: [String]? = nil) -> ProcessMemoryRecord {
    .init(pid: pid, parentPID: pid == 10 ? 1 : 10, userID: 501, started: UInt64(pid), name: URL(fileURLWithPath: path).lastPathComponent,
          executablePath: path, bytes: bytes, context: tasks.map { ProcessContext(browserTasks: $0, browserTasksSeen: seen) })
}

/// Arc as its Task Manager showed it: two named tabs (one process holding two
/// tabs of the same site), an embedded frame, a renderer opened since, and the
/// browser with its GPU helper.
private var browser: [ProcessMemoryRecord] {[
    record(10, arc + "/Contents/MacOS/Arc", bytes: 400),
    record(11, helper, bytes: 80),
    record(20, renderer, bytes: 740, tasks: ["Tab: (5) Messaging | LinkedIn"]),
    record(21, renderer, bytes: 300, tasks: ["Tab: Gala ERP", "Tab: Gala ERP – Stores"]),
    record(22, renderer, bytes: 60, tasks: ["Subframe: https://accounts.google.com/"]),
    record(23, renderer, bytes: 90),
]}
private let applications = [MemoryApplication(pid: 10, name: "Arc", bundlePath: arc)]

@Test func arcSplitsIntoATabPerPageProcessAndPartitionsExactly() throws {
    let group = try #require(MemoryAttribution.group(browser, applications: applications).first { $0.bundlePath == arc })
    let members = try #require(group.members)
    #expect(members.reduce(UInt64(0)) { $0 + $1.bytes } == group.bytes)
    #expect(Set(members.flatMap { $0.processes.map(\.pid) }) == Set(group.processes.map(\.pid)))
    #expect(members.map { BrowserTabs.role(of: $0.id) } == [.page, .browser, .page, .unnamed, .frames])
    #expect(members.first?.processes.map(\.pid) == [20])
    #expect(members.first { BrowserTabs.role(of: $0.id) == .browser }?.processes.map(\.pid).sorted() == [10, 11])
}

@Test func arcRowsNameTabsFromTheTaskManager() throws {
    let group = try #require(MemoryAttribution.group(browser, applications: applications).first { $0.bundlePath == arc })
    #expect(ProcessPresentation(consumer: group).subtitle == "3 tabs named · 1 page unnamed")
    let members = try #require(group.members)
    let linkedIn = ProcessPresentation(consumer: members[0])
    #expect(linkedIn.title == "(5) Messaging | LinkedIn" && linkedIn.subtitle == "PID 20")
    let gala = ProcessPresentation(consumer: try #require(members.first { $0.processes.map(\.pid) == [21] }))
    #expect(gala.title == "Gala ERP" && gala.subtitle == "+1 more tab in this process · PID 21")
    let frames = ProcessPresentation(consumer: try #require(members.first { BrowserTabs.role(of: $0.id) == .frames }))
    #expect(frames.subtitle == "1 process · accounts.google.com")
    // Before any naming the row still opens, so the tag button is reachable.
    let unnamed = browser.map { record($0.pid, $0.executablePath, bytes: $0.bytes) }
    let plain = try #require(MemoryAttribution.group(unnamed, applications: applications).first { $0.bundlePath == arc })
    #expect(ProcessPresentation(consumer: plain).subtitle == "Tabs not named yet · expand to name them")
    #expect(plain.members?.map { BrowserTabs.role(of: $0.id) } == [.unnamed, .browser])
}

@Test func tabRowsQuitNothingAndTheBrowserRowQuitsArc() throws {
    let group = try #require(MemoryAttribution.group(browser, applications: applications).first { $0.bundlePath == arc })
    #expect(ProcessTermination.plan(for: group, userID: 501, ownPID: 999).groupedSessions == 5)
    let members = try #require(group.members)
    for member in members where [.page, .frames].contains(BrowserTabs.role(of: member.id)) {
        let plan = ProcessTermination.plan(for: member, userID: 501, ownPID: 999)
        #expect(plan.browserPage && !plan.canQuit)
    }
    let browserRow = try #require(members.first { BrowserTabs.role(of: $0.id) == .browser })
    #expect(ProcessTermination.plan(for: browserRow, userID: 501, ownPID: 999).targets.map(\.pid) == [10, 11])
}

@Test func namesFollowTheExactProcessAndAReadingReplacesTheLast() {
    let names = BrowserTabNames()
    names.record([.init(task: "Tab: Gala ERP", pid: 21), .init(task: "Tab: Gala ERP – Stores", pid: 21), .init(task: "Browser", pid: 10)],
                 at: seen, startTime: { UInt64($0) })
    #expect(names.names(pid: 21, started: 21)?.tasks == ["Tab: Gala ERP", "Tab: Gala ERP – Stores"])
    // A reused PID is a different process and gets no name.
    #expect(names.names(pid: 21, started: 99) == nil)
    names.record([.init(task: "Tab: Lookout", pid: 30)], at: seen, startTime: { UInt64($0) })
    #expect(names.names(pid: 21, started: 21) == nil && names.names(pid: 30, started: 30)?.tasks == ["Tab: Lookout"])
    names.retain([10])
    #expect(names.isEmpty)
}

@Test func onlyPageLabelsCountAsTabs() {
    #expect(BrowserTabs.pageTitle("Tab: Claude Code") == "Claude Code")
    #expect(BrowserTabs.pageTitle("App: WhatsApp") == "WhatsApp")
    #expect(BrowserTabs.pageTitle("Subframe: https://google.com/") == nil)
    #expect(BrowserTabs.pageTitle("Extension: 1Password") == nil)
    #expect(BrowserTabs.pageTitle("Tab: ") == nil)
    #expect(!BrowserTabs.isBrowser(bundlePath: "/Applications/Google Chrome.app"))
}

@Test func contextsSavedBeforeTabNamesStillDecode() throws {
    let old = #"{"workingDirectory":"/Users/test/Developer/x"}"#
    let context = try JSONDecoder().decode(ProcessContext.self, from: Data(old.utf8))
    #expect(context.browserTasks == nil && context.workingDirectory == "/Users/test/Developer/x")
}

/// Reads Arc's Task Manager if it is open. Prints private tab titles, so it only
/// runs when asked: `MENUSPRITE_LIVE_PROBE=1 swift test --filter liveArcTaskManagerProbe`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MENUSPRITE_LIVE_PROBE"] == "1"))
func liveArcTaskManagerProbe() throws {
    let arcPID = try #require(ProcessInfo.processInfo.environment["ARC_PID"].flatMap { Int32($0) })
    let rows = try #require(ChromiumTaskManager.readOpen(appPID: arcPID))
    for row in rows { print("\(row.pid)\t\(row.task)") }
    #expect(!rows.isEmpty)
}
