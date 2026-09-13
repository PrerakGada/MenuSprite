import Foundation
import Testing
@testable import SystemMonitoring

private func contextual(_ pid: Int32, _ name: String, _ executable: String, _ context: ProcessContext?) -> ProcessMemoryRecord {
    .init(pid: pid, parentPID: 1, userID: 501, started: 100, name: name, executablePath: executable, bytes: 123, context: context)
}
private func label(_ record: ProcessMemoryRecord) -> ProcessPresentation {
    MemoryAttribution.group([record], applications: [])[0].presentation
}
@Test func runtimeRowsShowWorkingFolderAndWorktreeWithoutMerging() {
    let a = contextual(10, "node", "/usr/local/bin/node", .init(workingDirectory: "/Users/test/Developer/ExampleApp/worktrees/feature-example/backend"))
    let b = contextual(11, "node", "/usr/local/bin/node", .init(workingDirectory: "/Users/test/Developer/ExampleApp/backend"))
    #expect(label(a).title == "ExampleApp / backend")
    #expect(label(a).subtitle == "Node.js · worktree feature-example · PID 10")
    #expect(label(b).subtitle == "Node.js · PID 11")
    let grouped = MemoryAttribution.group([a,b], applications: [])
    #expect(grouped.count == 2 && grouped.reduce(UInt64(0)) { $0 + $1.bytes } == 246)
}
@Test func flutterAndSharedGradleAreDescribedWithoutGuessingProjects() {
    let dart = contextual(12, "dartaotruntime", "/Users/test/fvm/versions/3.44/bin/cache/dart-sdk/bin/dartaotruntime", .init(workingDirectory: "/Users/test/Developer/ExampleApp/app"))
    #expect(label(dart).title == "ExampleApp / app")
    #expect(label(dart).subtitle == "Flutter / Dart · PID 12")
    let java = contextual(13, "java", "/jdk/bin/java", .init(workingDirectory: "/Users/test/.gradle/daemon/9.1.0"))
    #expect(label(java).title == "Gradle daemon")
    #expect(label(java).explanation.contains("multiple projects"))
}
@Test func unavailableContextPreservesUncertaintyAndIdentity() {
    let node = contextual(14, "node", "/usr/bin/node", nil)
    #expect(label(node).title == "Node.js process")
    #expect(label(node).subtitle == "Project not identified · PID 14")
    let context = ProcessContext(workingDirectory: "/Users/test/Developer/Unrelated")
    let app = contextual(15, "node", "/Applications/Editor.app/Contents/node", context)
    #expect(label(app).title == "Editor" && label(app).iconBundlePath == "/Applications/Editor.app")
}
@Test func virtualMachineHostRequiresSpecificResourceEvidence() {
    let path = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
    #expect(label(contextual(16,"com.apple.Virtualization.Virtua",path,nil)).title == "Virtual machine service")
    let resource = "/Applications/Docker.app/Contents/Resources/linuxkit/kernel"
    #expect(ProcessContextReader.dockerEvidence(resource)?.bundle == "/Applications/Docker.app")
    #expect(ProcessContextReader.dockerEvidence("/tmp/Docker.raw") == nil)
    let context = ProcessContext(virtualMachineHost: "Docker", hostBundlePath: "/Applications/Docker.app", evidencePath: resource)
    #expect(label(contextual(16,"com.apple.Virtualization.Virtua",path,context)).title == "Docker virtual machine")
}
@Test func oldSnapshotsDecodeWithoutContext() throws {
    let record = contextual(17,"node","/usr/bin/node",nil)
    let encoder = JSONEncoder()
    var object = try JSONSerialization.jsonObject(with: encoder.encode(record)) as! [String:Any]
    object.removeValue(forKey: "context")
    let decoded = try JSONDecoder().decode(ProcessMemoryRecord.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.context == nil && decoded.pid == 17 && decoded.bytes == 123)
}
