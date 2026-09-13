import Darwin
import Foundation
import Testing
@testable import AIAccounts

/// Reads the operator's real Claude Code and Codex logs — read-only, into a throwaway cache — and reports
/// what a cold scan, a warm pass and the resting state cost. Prints aggregate figures and model names
/// only: never a log line, a path, a prompt or a token.
///
/// `resident_size_max` is a high-water mark for the whole process, so scanning both providers in one
/// run cannot attribute a peak to either. Run one provider per process for a figure worth quoting:
/// `MENUSPRITE_LIVE_SPEND=claude swift test --package-path native --filter liveSpendScan`
/// `MENUSPRITE_LIVE_SPEND=codex  swift test --package-path native --filter liveSpendScan`
@Test(.enabled(if: ProcessInfo.processInfo.environment["MENUSPRITE_LIVE_SPEND"]?.isEmpty == false))
func liveSpendScanMeasuresRealLogs() async throws {
    let selection = (ProcessInfo.processInfo.environment["MENUSPRITE_LIVE_SPEND"] ?? "").lowercased()
    let providers = AIProvider.allCases.filter { selection == "1" || selection == "all" || selection == $0.rawValue }
    try #require(!providers.isEmpty, "MENUSPRITE_LIVE_SPEND must be claude, codex, all or 1")

    // A caller-supplied directory survives the run, so a separate process can measure what holding
    // that cache actually costs. Without one, the cache is temporary and removed on exit.
    let supplied = ProcessInfo.processInfo.environment["MENUSPRITE_SPEND_CACHE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
    let temporary = supplied.map(URL.init(fileURLWithPath:))
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("menusprite-live-spend-\(UUID().uuidString)")
    defer { if supplied == nil { try? FileManager.default.removeItem(at: temporary) } }
    let standard = SpendPaths.standard
    let paths = SpendPaths(claudeProjects: standard.claudeProjects, codexSessions: standard.codexSessions,
                           summaryFile: temporary.appendingPathComponent("summary.plist"),
                           scanStateFile: temporary.appendingPathComponent("state.bin"))

    print("baseline before any scan: resident \(residentMiB()) MiB, peak \(peakResidentMiB()) MiB")
    for provider in providers {
        let service = SpendService(paths: paths, refreshInterval: 0)
        let coldStart = Date()
        let cold = await service.scanNow(provider)
        let coldSeconds = Date().timeIntervalSince(coldStart)
        print("[\(provider.rawValue)] cold \(String(format: "%.1f", coldSeconds))s → resident \(residentMiB()) MiB, peak \(peakResidentMiB()) MiB")
        if let stats = await service.statistics(provider) {
            print("  files considered \(stats.filesConsidered), read \(stats.filesRead), skipped by age \(stats.filesSkippedByAge)")
            print("  requests counted \(stats.eventsCounted), replays skipped \(stats.duplicatesSkipped), oversized lines \(stats.linesSkipped)")
        }
        if let cold {
            print("  today $\(String(format: "%.2f", cold.today)) · 7d $\(String(format: "%.2f", cold.last7Days)) · 30d $\(String(format: "%.2f", cold.last30Days))")
            print("  tokens today \(cold.tokensToday), 30d \(cold.tokens30Days)")
            print("  top models: " + cold.topModels.map { "\($0.id) $\(String(format: "%.2f", $0.dollars))" }.joined(separator: ", "))
            print("  unpriced: " + (cold.unpricedModels.isEmpty ? "none" : cold.unpricedModels.joined(separator: ", ")))
        }

        let warmStart = Date()
        _ = await service.scanNow(provider)
        let warmSeconds = Date().timeIntervalSince(warmStart)
        print("  warm \(String(format: "%.2f", warmSeconds))s → resident \(residentMiB()) MiB, peak \(peakResidentMiB()) MiB")
        if let stats = await service.statistics(provider) { print("  warm pass read \(stats.filesRead) files, reused \(stats.filesReused)") }

        // Resting state: a fresh service over the same cache, answering from the aggregate alone.
        let sizes = [paths.summaryFile: "summary", paths.scanStateFile: "scan state"].compactMapValues { $0 }
        for (url, label) in sizes {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print("  \(label) file: \((bytes ?? 0) / 1024) KiB")
        }
        let idle = SpendService(paths: paths, refreshInterval: 86_400)
        _ = await idle.summary(provider, force: false)
        print("  idle service loaded (aggregate only) → resident \(residentMiB()) MiB, peak \(peakResidentMiB()) MiB")
        #expect(warmSeconds < max(1, coldSeconds))
    }
}

// The resting-cost measurement lives in `SpendIdleTests.swift` (`spendIdleFootprint`), which runs the
// fill and idle phases as separate processes. Two harnesses measuring one bar is how contradictory
// numbers get quoted later, so there is deliberately only one.

private func taskInfo() -> mach_task_basic_info? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? info : nil
}

/// Resident right now: what the process is actually holding.
private func residentMiB() -> Int { Int(taskInfo()?.resident_size ?? 0) / 1_048_576 }

/// The process's high-water mark since launch — cumulative, never per-scan.
private func peakResidentMiB() -> Int { Int(taskInfo()?.resident_size_max ?? 0) / 1_048_576 }
