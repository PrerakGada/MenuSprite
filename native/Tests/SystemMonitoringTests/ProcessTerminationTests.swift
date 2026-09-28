import Foundation
import Testing
@testable import SystemMonitoring

private func record(_ pid: Int32, user: UInt32 = 501, started: UInt64 = 100, path: String = "", name: String = "tool") -> ProcessMemoryRecord {
    .init(pid: pid, parentPID: 1, userID: user, started: started, name: name, executablePath: path, bytes: 10)
}
private func consumer(_ records: [ProcessMemoryRecord], name: String = "Thing", bundle: String? = nil) -> MemoryConsumer {
    .init(id: bundle.map { "app:" + $0 } ?? "process:\(records[0].pid)", name: name, bundlePath: bundle, bytes: 10, processes: records)
}

@Test func planCoversEveryGroupedProcessOnceAndMarksOwnership() {
    let rows = [record(310, path: "/Applications/Editor.app/Contents/MacOS/Editor", name: "Editor"),
                record(311, name: "Editor Helper"),
                record(312, user: 0, name: "root helper")]
    let plan = ProcessTermination.plan(for: consumer(rows, name: "Editor", bundle: "/Applications/Editor.app"), userID: 501, ownPID: 900)
    #expect(plan.targets.map(\.pid) == [310, 311, 312])
    #expect(plan.ownTargets.map(\.pid) == [310, 311])
    #expect(plan.canQuit && !plan.blockedByOwnership && !plan.isOwnApplication)
    #expect(plan.title == "Editor")
}

@Test func planRefusesSystemOwnedRowsAndNeverOffersPIDOne() {
    let plan = ProcessTermination.plan(for: consumer([record(1, user: 0, name: "launchd"), record(77, user: 0, name: "logd")]), userID: 501, ownPID: 900)
    #expect(plan.targets.map(\.pid) == [77])
    #expect(!plan.canQuit && plan.blockedByOwnership)
}

@Test func planRecognizesMenuSpriteItself() {
    let plan = ProcessTermination.plan(for: consumer([record(900, name: "MenuSprite")]), userID: 501, ownPID: 900)
    #expect(plan.isOwnApplication)
}

@Test func signallingRefusesAProcessWhoseBirthStampNoLongerMatches() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    let pid = process.processIdentifier
    defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
    let started = try #require(ProcessTermination.startTime(of: pid))

    // A PID whose birth stamp differs is a different process; nothing is signalled.
    let stale = ProcessQuitTarget(pid: pid, started: started &- 1, name: "sleep", ownedByUser: true)
    #expect(ProcessTermination.send(SIGTERM, to: stale) == .identityChanged)
    #expect(process.isRunning)

    // A row the user does not own is refused before any signal is attempted.
    #expect(ProcessTermination.send(SIGTERM, to: ProcessQuitTarget(pid: pid, started: started, name: "sleep", ownedByUser: false)) == .notPermitted)
    #expect(process.isRunning)

    let target = ProcessQuitTarget(pid: pid, started: started, name: "sleep", ownedByUser: true)
    #expect(ProcessTermination.send(SIGTERM, to: target) == .delivered)
    process.waitUntilExit()
    #expect(!process.isRunning)
    // The PID is gone, so the same target now reports an exit rather than acting.
    #expect(ProcessTermination.send(SIGTERM, to: target) == .alreadyExited)
}

@Test func signallingASecondTimeWithSIGKILLEndsAProcessThatIgnoredSIGTERM() throws {
    // The escalating button's second click: the same target, forced. A process
    // that traps SIGTERM survives the first click and not the second.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", "import signal, sys, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('ready', flush=True); time.sleep(30)"]
    let ready = Pipe()
    process.standardOutput = ready
    try process.run()
    let pid = process.processIdentifier
    defer { if process.isRunning { kill(pid, SIGKILL) }; process.waitUntilExit() }
    // Only signal once the child has actually installed the handler.
    #expect(String(decoding: ready.fileHandleForReading.availableData, as: UTF8.self).contains("ready"))
    let target = ProcessQuitTarget(pid: pid, started: try #require(ProcessTermination.startTime(of: pid)),
                                   name: "python3", ownedByUser: true)

    #expect(ProcessTermination.send(SIGTERM, to: target) == .delivered)
    Thread.sleep(forTimeInterval: 0.3)
    #expect(process.isRunning)

    #expect(ProcessTermination.send(SIGKILL, to: target) == .delivered)
    process.waitUntilExit()
    #expect(!process.isRunning)
}

@Test func summaryStatesWhatHappenedIncludingPartialResults() {
    #expect(ProcessTermination.summary(title: "Editor", outcomes: [.delivered], forced: false) == "Asked Editor to quit.")
    #expect(ProcessTermination.summary(title: "Editor", outcomes: [.delivered, .delivered], forced: true) == "Force quit Editor (2 processes).")
    #expect(ProcessTermination.summary(title: "Editor", outcomes: [.notPermitted], forced: false).hasPrefix("Could not quit Editor: macOS did not permit it"))
    let mixed = ProcessTermination.summary(title: "node", outcomes: [.delivered, .alreadyExited], forced: false)
    #expect(mixed == "Asked 1 of 2 processes in node to quit; some had already exited.")
    #expect(ProcessTermination.summary(title: "node", outcomes: [], forced: false) == "Nothing left to quit in node.")
}
