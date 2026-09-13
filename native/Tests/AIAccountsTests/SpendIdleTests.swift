import Darwin
import Foundation
import Testing
@testable import AIAccounts

/// Steady state is the figure that decides whether spend belongs in a menu-bar app: what the service
/// holds for the life of the process while nobody is scanning. Measuring that inside the process that
/// just scanned is misleading — freed pages stay resident — so this runs as two phases, each its own
/// process, against a directory that survives between them:
///
///     MENUSPRITE_SPEND_IDLE_DIR=/tmp/spend-idle MENUSPRITE_SPEND_IDLE=fill \
///       swift test --package-path native --filter spendIdleFootprint
///     MENUSPRITE_SPEND_IDLE_DIR=/tmp/spend-idle MENUSPRITE_SPEND_IDLE=idle \
///       swift test --package-path native --filter spendIdleFootprint
///
/// Phase one scans the real Codex logs — seconds, where Claude's take minutes — into that directory.
/// Phase two loads only the aggregate and must never scan. Prints figures, never log content.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MENUSPRITE_SPEND_IDLE"]?.isEmpty == false))
func spendIdleFootprint() async throws {
    let environment = ProcessInfo.processInfo.environment
    let phase = environment["MENUSPRITE_SPEND_IDLE"] ?? ""
    let directory = URL(fileURLWithPath: try #require(environment["MENUSPRITE_SPEND_IDLE_DIR"],
                                                      "set MENUSPRITE_SPEND_IDLE_DIR to a directory that survives both phases"))
    let standard = SpendPaths.standard
    let paths = SpendPaths(claudeProjects: standard.claudeProjects, codexSessions: standard.codexSessions,
                           summaryFile: directory.appendingPathComponent("summary.plist"),
                           scanStateFile: directory.appendingPathComponent("scan-state.bin"))
    print("phase \(phase): resident at launch \(idleResidentMiB()) MiB")

    if phase == "fill" {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = SpendService(paths: paths, refreshInterval: 0)
        let summary = await service.scanNow(.codex)
        #expect(summary != nil, "the fill phase must produce an aggregate for the idle phase to load")
        print("  after scan: resident \(idleResidentMiB()) MiB, peak \(idlePeakMiB()) MiB")
    } else {
        // A day's freshness window, so asking for the summary cannot start a scan behind the measurement.
        let service = SpendService(paths: paths, refreshInterval: 86_400)
        let loaded = try #require(await service.summary(.codex, force: false), "run the fill phase first")
        print("  idle, aggregate only: resident \(idleResidentMiB()) MiB, peak \(idlePeakMiB()) MiB")
        print("  30d $\(String(format: "%.2f", loaded.last30Days)) · tokens \(loaded.tokens30Days) · partial \(loaded.partial)")
    }

    for (label, url) in [("summary", paths.summaryFile), ("scan state", paths.scanStateFile)] {
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        print("  \(label) file: \(bytes) bytes")
    }
}

private func idleTaskInfo() -> mach_task_basic_info? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? info : nil
}

private func idleResidentMiB() -> Int { Int(idleTaskInfo()?.resident_size ?? 0) / 1_048_576 }
private func idlePeakMiB() -> Int { Int(idleTaskInfo()?.resident_size_max ?? 0) / 1_048_576 }
