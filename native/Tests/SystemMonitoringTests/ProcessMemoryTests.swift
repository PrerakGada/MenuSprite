import Foundation
import Testing
@testable import SystemMonitoring

private func process(_ pid: Int32, parent: Int32 = 1, user: UInt32 = 501, started: UInt64 = 100, path: String = "", bytes: UInt64 = 100, name: String = "tool") -> ProcessMemoryRecord {
    .init(pid: pid, parentPID: parent, userID: user, started: started, name: name, executablePath: path, bytes: bytes)
}
@Test func memoryAttributionGroupsEmbeddedHelpersAndTerminalChildrenOnce() {
    let rows = [
        process(10, path: "/Applications/Arc.app/Contents/MacOS/Arc", bytes: 400),
        process(11, path: "/Applications/Arc.app/Contents/Frameworks/Arc Helper.app/Contents/MacOS/Arc Helper", bytes: 300),
        process(20, path: "/Applications/iTerm.app/Contents/MacOS/iTerm2", bytes: 100),
        process(21, parent: 20, started: 101, bytes: 600, name: "node"),
        process(22, parent: 21, started: 102, bytes: 200, name: "worker"),
        process(30, path: "/usr/local/bin/node", bytes: 50, name: "node")
    ]
    let apps = [MemoryApplication(pid: 10, name: "Arc", bundlePath: "/Applications/Arc.app"), .init(pid: 20, name: "iTerm2", bundlePath: "/Applications/iTerm.app")]
    let grouped = MemoryAttribution.group(rows, applications: apps)
    #expect(grouped.count == 3)
    #expect(grouped[0].name == "iTerm2" && grouped[0].bytes == 900 && grouped[0].processCount == 3)
    #expect(grouped[1].name == "Arc" && grouped[1].bytes == 700 && grouped[1].processCount == 2)
    #expect(grouped[2].name == "node" && grouped[2].bytes == 50)
    #expect(grouped.flatMap(\.processes).count == rows.count)
    #expect(grouped.reduce(UInt64(0)) { $0 + $1.bytes } == rows.reduce(UInt64(0)) { $0 + $1.bytes })
}
@Test func anotherAppLaunchedFromTerminalKeepsItsOwnIdentity() {
    let rows = [process(1_000, path: "/Applications/Terminal.app/Contents/MacOS/Terminal"), process(1_001, parent: 1_000, started: 101, path: "/Applications/Editor.app/Contents/MacOS/Editor")]
    let grouped = MemoryAttribution.group(rows, applications: [])
    #expect(grouped.count == 2)
    #expect(Set(grouped.compactMap(\.bundlePath)) == ["/Applications/Terminal.app", "/Applications/Editor.app"])
}
@Test func unknownParentsReusedPIDsAndOtherUsersStaySeparate() {
    let rows = [
        process(10, user: 501, started: 200, path: "/Applications/Terminal.app/Contents/MacOS/Terminal"),
        process(11, parent: 10, started: 100), // Parent PID now belongs to a newer process.
        process(12, parent: 10, user: 502, started: 201),
        process(13, parent: 99)
    ]
    let grouped = MemoryAttribution.group(rows, applications: [])
    #expect(grouped.count == 4)
    #expect(grouped.first { $0.bundlePath != nil }?.processCount == 1)
}
@Test func attributionHandlesCyclesDuplicatePIDsAndNameCollisions() {
    let a = process(10, parent: 11, name: "node"), b = process(11, parent: 10, name: "node")
    let grouped = MemoryAttribution.group([a,b,a], applications: [])
    #expect(grouped.count == 2)
    #expect(grouped.allSatisfy { $0.processCount == 1 && $0.bytes == 100 })
}
@Test func appPathsDoNotUseNameSimilarity() {
    #expect(MemoryAttribution.appBundle(in: "/Applications/Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Helper") == "/Applications/Code.app")
    #expect(MemoryAttribution.appBundle(in: "/usr/local/bin/Code") == nil)
    #expect(MemoryAttribution.appBundle(in: "/tmp/Code.application/tool") == nil)
}
