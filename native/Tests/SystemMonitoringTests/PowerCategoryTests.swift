import Foundation
import Testing
@testable import SystemMonitoring

private func process(_ pid: Int32, _ path: String, cwd: String? = nil) -> ProcessMemoryRecord {
    .init(pid: pid, parentPID: 1, userID: 501, started: 1, name: URL(fileURLWithPath: path).lastPathComponent, executablePath: path,
          bytes: 1024, cpuTicks: nil, energyNanojoules: nil, sampledUptime: nil,
          context: cwd.map { ProcessContext(workingDirectory: $0) })
}
private func app(_ id: String, bundle: String?, _ processes: [ProcessMemoryRecord]) -> MemoryConsumer {
    MemoryConsumer(id: id, name: id, bundlePath: bundle, bytes: 1024, processes: processes)
}
private func rate(_ consumer: MemoryConsumer, _ watts: Double) -> ProcessConsumerRate {
    ProcessConsumerRate(consumer: consumer, value: watts, processValues: [consumer.processes[0].pid: watts], missingCount: 0)
}

struct PowerCategoryTests {
    @Test func curatedListBeatsMisleadingDeclarations() {
        let arc = app("arc", bundle: "/Applications/Arc.app", [process(1, "/Applications/Arc.app/Contents/MacOS/Arc")])
        let facts = BundleFacts(identifier: "company.thebrowser.Browser", declared: "public.app-category.productivity", agent: false)
        #expect(PowerCategories.classify(arc, facts: facts) == .browsing)
        let claude = BundleFacts(identifier: "com.anthropic.claudefordesktop", declared: "public.app-category.developer-tools", agent: false)
        #expect(PowerCategories.classify(app("c", bundle: "/Applications/Claude.app", []), facts: claude) == .work)
        let docs = BundleFacts(identifier: "com.google.drivefs.shortcuts.docs", declared: nil, agent: false)
        #expect(PowerCategories.classify(app("d", bundle: "/Applications/Google Docs.app", []), facts: docs) == .work)
    }
    @Test func declaredCategoryThenAgentThenOtherApps() {
        let bundle = "/Applications/X.app"
        #expect(PowerCategories.classify(app("x", bundle: bundle, []), facts: .init(identifier: "x", declared: "public.app-category.developer-tools", agent: false)) == .development)
        #expect(PowerCategories.classify(app("x", bundle: bundle, []), facts: .init(identifier: "x", declared: "public.app-category.graphics-design", agent: false)) == .media)
        #expect(PowerCategories.classify(app("x", bundle: bundle, []), facts: .init(identifier: "x", declared: "public.app-category.board-games", agent: false)) == .media)
        #expect(PowerCategories.classify(app("x", bundle: bundle, []), facts: .init(identifier: "x", declared: "public.app-category.utilities", agent: true)) == .background)
        #expect(PowerCategories.classify(app("x", bundle: bundle, []), facts: .init(identifier: "x", declared: nil, agent: true)) == .background)
        #expect(PowerCategories.classify(app("x", bundle: bundle, []), facts: .init(identifier: "x", declared: nil, agent: false)) == .apps)
        #expect(PowerCategories.classify(app("x", bundle: bundle, []), facts: nil) == .apps)
        #expect(PowerCategories.classify(app("x", bundle: "/System/Library/CoreServices/Y.app", []), facts: nil) == .background)
        let python = "/opt/homebrew/Cellar/python@3.13/3.13.15/Frameworks/Python.framework/Versions/3.13/Resources/Python.app"
        #expect(PowerCategories.classify(app("py", bundle: python, []), facts: .init(identifier: nil, declared: nil, agent: false)) == .development)
    }
    @Test func processesWithoutAnAppGoByWhatTheyRunAndWhere() {
        #expect(PowerCategories.classify(app(ClaudeCode.groupID, bundle: nil, []), facts: nil) == .development)
        #expect(PowerCategories.classify(app("p", bundle: nil, [process(2, "/Users/example/.nvm/versions/node/v22/bin/node")]), facts: nil) == .development)
        #expect(PowerCategories.classify(app("p", bundle: nil, [process(3, "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend")]), facts: nil) == .development)
        #expect(PowerCategories.classify(app("p", bundle: nil, [process(4, "/usr/local/bin/tool", cwd: "/Users/example/Developer/Repo")]), facts: nil) == .development)
        #expect(PowerCategories.classify(app("p", bundle: nil, [process(5, "/usr/libexec/replayd", cwd: "/")]), facts: nil) == .background)
    }
    @Test func breakdownSplitsHeavyAppsCategoriesAndTheRest() {
        let heavy = app("claude-code", bundle: nil, [process(1, "/x/claude")])
        let term = app("iterm", bundle: nil, [process(2, "/x/iterm")])
        let web = app("arc", bundle: nil, [process(3, "/x/arc")])
        let tiny = app("tiny", bundle: nil, [process(4, "/x/tiny")])
        let kinds: [String: PowerCategory] = ["claude-code": .development, "iterm": .development, "arc": .browsing, "tiny": .media]
        let result = PowerBreakdown.make(system: 20, outside: 1.5, rows: [rate(heavy, 7), rate(term, 1), rate(web, 2), rate(tiny, 0.01)]) { kinds[$0.id]! }
        // Arc at exactly 2 W is heavy: its own pill, so no Browsing pill. Media's 0.01 W is below the floor.
        #expect(result.entries.map(\.id) == ["app:claude-code", "app:arc", "category:development", "rest", "outside"])
        #expect(abs(result.attributed - 10.01) < 1e-9)
        #expect(abs(result.entries[3].watts - 9.99) < 1e-9)
        #expect(result.entries.last?.watts == 1.5)
    }
    @Test func breakdownNeverInventsARestAndKeepsSystemWholeWithoutApps() {
        let busy = app("busy", bundle: nil, [process(1, "/x/busy")])
        let over = PowerBreakdown.make(system: 3, outside: nil, rows: [rate(busy, 4)]) { _ in .development }
        #expect(!over.entries.contains { $0.kind == .restOfMac })
        let none = PowerBreakdown.make(system: 12, outside: 0.01, rows: []) { _ in .apps }
        #expect(none.entries.map(\.kind) == [.system])
    }
    @Test func tooManyCategoriesFoldIntoOtherApps() {
        let kinds: [PowerCategory] = [.development, .browsing, .work, .media, .background, .apps]
        let rows = kinds.enumerated().map { index, _ in rate(app("a\(index)", bundle: nil, [process(Int32(index + 1), "/x/\(index)")]), Double(index + 1) * 0.3) }
        let result = PowerBreakdown.make(system: 30, outside: 1, rows: rows, category: { kinds[Int($0.id.dropFirst())!] },
                                         heavyWatts: 100)
        #expect(result.entries.count <= 8)
        let total = result.entries.filter { if case .category = $0.kind { true } else { false } }.reduce(0) { $0 + $1.watts }
        #expect(abs(total - result.attributed) < 1e-9)
    }
}
