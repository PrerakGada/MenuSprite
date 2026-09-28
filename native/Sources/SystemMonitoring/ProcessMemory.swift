import Foundation
import Darwin

public struct MemoryApplication: Sendable, Codable, Equatable {
    public let pid: Int32
    public let name: String
    public let bundlePath: String
    public init(pid: Int32, name: String, bundlePath: String) { self.pid = pid; self.name = name; self.bundlePath = bundlePath }
}
public struct ProcessMemoryRecord: Sendable, Codable, Equatable {
    public let pid: Int32
    public let parentPID: Int32
    public let userID: UInt32
    public let started: UInt64
    public let name: String
    public let executablePath: String
    public let bytes: UInt64
    public let cpuTicks: UInt64?
    public let energyNanojoules: UInt64?
    public let sampledUptime: Double?
    public let context: ProcessContext?
    public init(pid: Int32, parentPID: Int32, userID: UInt32, started: UInt64, name: String, executablePath: String, bytes: UInt64, cpuTicks: UInt64? = nil, energyNanojoules: UInt64? = nil, sampledUptime: Double? = nil, context: ProcessContext? = nil) {
        self.pid = pid; self.parentPID = parentPID; self.userID = userID; self.started = started
        self.name = name; self.executablePath = executablePath; self.bytes = bytes
        self.cpuTicks = cpuTicks; self.energyNanojoules = energyNanojoules; self.sampledUptime = sampledUptime
        self.context = context
    }
}
public struct MemoryConsumer: Identifiable, Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let bundlePath: String?
    public let bytes: UInt64
    public let processes: [ProcessMemoryRecord]
    /// Sub-rows a grouped row can expand into (one per Claude Code session, or per
    /// Arc tab). The
    /// members partition `processes`; totals are never counted twice.
    public var members: [MemoryConsumer]? = nil
    public var processCount: Int { processes.count }
    public var presentation: ProcessPresentation { ProcessPresentation(consumer: self) }
}
public struct ProcessMemorySnapshot: Sendable, Codable {
    public let consumers: [MemoryConsumer]
    public let listedCount: Int
    public let readableCount: Int
    public let unavailableCount: Int
    public let sampledAt: Date
    public let error: String?
}
public enum MemoryAttribution {
    /// Outermost app bundle, so embedded Electron/XPC helpers join their app.
    public static func appBundle(in path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let end = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return "/" + components[...end].joined(separator: "/")
    }
    public static func group(_ records: [ProcessMemoryRecord], applications: [MemoryApplication]) -> [MemoryConsumer] {
        let byPID = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let byAppPID = Dictionary(applications.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var names: [String: String] = [:]
        for app in applications {
            let path = appBundle(in: app.bundlePath) ?? app.bundlePath
            // A top-level application's display name outranks an embedded helper's.
            if names[path] == nil || app.bundlePath == path { names[path] = app.name }
        }
        struct Owner { let id: String; let name: String; let bundle: String? }
        func bundleOwner(_ path: String) -> Owner {
            Owner(id: "app:" + path, name: names[path] ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, bundle: path)
        }
        func directOwner(_ process: ProcessMemoryRecord) -> Owner? {
            if let path = appBundle(in: process.executablePath) { return bundleOwner(path) }
            if let app = byAppPID[process.pid], let path = appBundle(in: app.bundlePath) { return bundleOwner(path) }
            return nil
        }
        // The live chain a process was started through. A parent must be the same
        // user and older than its child, so a reused PID never joins a chain.
        func ancestors(_ process: ProcessMemoryRecord) -> [ProcessMemoryRecord] {
            var result: [ProcessMemoryRecord] = [], current = process, visited: Set<Int32> = [process.pid]
            while current.parentPID > 1, let parent = byPID[current.parentPID], parent.userID == process.userID,
                  parent.started <= current.started, visited.insert(parent.pid).inserted {
                result.append(parent); current = parent
            }
            return result
        }
        func isClaude(_ process: ProcessMemoryRecord) -> Bool { ClaudeCode.isExecutable(process.executablePath) }
        // Claude Code and everything it started (MCP servers, tool shells), in any
        // terminal or editor. A child that is itself an app bundle stays that app's.
        func belongsToClaude(_ process: ProcessMemoryRecord) -> Bool {
            if isClaude(process) { return true }
            if directOwner(process) != nil { return false }
            for parent in ancestors(process) {
                if isClaude(parent) { return true }
                if directOwner(parent) != nil { return false }
            }
            return false
        }
        func owner(_ process: ProcessMemoryRecord) -> Owner {
            if belongsToClaude(process) { return Owner(id: ClaudeCode.groupID, name: "Claude Code", bundle: nil) }
            if let direct = directOwner(process) { return direct }
            // Attribute terminal/tool children only through observed live ancestry.
            // Never infer ownership from name similarity or a reused parent PID.
            for parent in ancestors(process) { if let direct = directOwner(parent) { return direct } }
            return Owner(id: "process:\(process.pid):\(process.started)", name: process.name, bundle: nil)
        }
        var groups: [String: (owner: Owner, records: [ProcessMemoryRecord])] = [:]
        for process in byPID.values {
            let target = owner(process)
            if groups[target.id] == nil { groups[target.id] = (target, []) }
            groups[target.id]!.records.append(process)
        }
        func consumer(_ id: String, _ name: String, _ bundle: String?, _ records: [ProcessMemoryRecord]) -> MemoryConsumer {
            MemoryConsumer(id: id, name: name, bundlePath: bundle, bytes: records.reduce(0) { $0 + $1.bytes },
                           processes: records.sorted { $0.bytes == $1.bytes ? $0.pid < $1.pid : $0.bytes > $1.bytes })
        }
        // Each process joins the nearest Claude Code process with a session record
        // (itself included); the daemon and its spares have none.
        func claudeSessions(_ records: [ProcessMemoryRecord]) -> [MemoryConsumer] {
            var sessions: [String: (root: ProcessMemoryRecord?, records: [ProcessMemoryRecord])] = [:]
            for process in records {
                let root = ([process] + ancestors(process)).first { isClaude($0) && $0.context?.claudeSession != nil }
                let id = root.map { ClaudeCode.sessionPrefix + "\($0.pid):\($0.started)" } ?? ClaudeCode.serviceID
                sessions[id, default: (root, [])].records.append(process)
            }
            return sessions.map { id, session in
                consumer(id, session.root?.context?.claudeSession?.title ?? "Claude Code", nil, session.records)
            }.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
        }
        return groups.values.map { group in
            var result = consumer(group.owner.id, group.owner.name, group.owner.bundle, group.records)
            if group.owner.id == ClaudeCode.groupID { result.members = claudeSessions(group.records) }
            if BrowserTabs.isBrowser(bundlePath: group.owner.bundle) {
                result.members = BrowserTabs.members(groupID: group.owner.id, group.records) { records, id, name in consumer(id, name, nil, records) }
            }
            return result
        }.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
    }
}

/// No task_for_pid, shell collector, helper, command line, environment or memory
/// contents. Kernel accounting only. This actor is owned by the open memory board.
public actor ProcessMemorySampler {
    private struct CachedPath { let started: UInt64; let path: String }
    private var paths: [Int32: CachedPath] = [:]
    private var contextReader = ProcessContextReader()
    public init() {}
    private func readUsage(_ pid: Int32) -> (info: rusage_info_v6, hasEnergy: Bool)? {
        var info = rusage_info_v6()
        func read(_ flavor: Int32) -> Int32 {
            withUnsafeMutablePointer(to: &info) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, flavor, $0) }
            }
        }
        if read(RUSAGE_INFO_V6) == 0 { return (info, true) }
        // V4 is a common prefix of V6. Keep memory/CPU readable on a system
        // rejecting V6, but never interpret the zero-filled tail as energy data.
        guard errno == EINVAL || errno == ENOTSUP else { return nil }
        info = rusage_info_v6()
        return read(RUSAGE_INFO_V4) == 0 ? (info, false) : nil
    }
    public func sample(applications: [MemoryApplication]) -> ProcessMemorySnapshot {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return .init(consumers: [], listedCount: 0, readableCount: 0, unavailableCount: 0, sampledAt: Date(), error: "macOS could not list processes. Try Refresh.") }
        var pids = [Int32](repeating: 0, count: Int(needed) / MemoryLayout<Int32>.size + 256)
        let capacity = Int32(pids.count * MemoryLayout<Int32>.size)
        let returned = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, capacity) }
        guard returned > 0 else { return .init(consumers: [], listedCount: 0, readableCount: 0, unavailableCount: 0, sampledAt: Date(), error: "macOS could not read the process list. Try Refresh.") }
        let listed = Set(pids.prefix(min(pids.count, Int(returned) / MemoryLayout<Int32>.size)).filter { $0 > 0 })
        var records: [ProcessMemoryRecord] = []
        var nextPaths: [Int32: CachedPath] = [:]
        // Arc's Task Manager, when it happens to be open, names its renderers.
        // One Accessibility query for its windows otherwise; nothing when Arc is not running.
        let names = BrowserTabNames.shared
        if let browser = applications.first(where: { BrowserTabs.isBrowser(bundlePath: $0.bundlePath) }),
           let rows = ChromiumTaskManager.readOpen(appPID: browser.pid) { names.record(rows) }
        for pid in listed {
            if Task.isCancelled { break }
            guard let first = readUsage(pid) else { continue }
            let usage = first.info
            var bsd = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { continue }
            // Confirm identity across the metadata read; PID reuse must not mix apps.
            guard let last = readUsage(pid), usage.ri_proc_start_abstime == last.info.ri_proc_start_abstime else { continue }
            let confirmed = last.info
            let path: String
            if let cached = paths[pid], cached.started == confirmed.ri_proc_start_abstime { path = cached.path }
            else {
                var buffer = [CChar](repeating: 0, count: 4096)
                let count = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
                path = count > 0 ? String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
            }
            nextPaths[pid] = CachedPath(started: confirmed.ri_proc_start_abstime, path: path)
            let name = withUnsafeBytes(of: &bsd.pbi_name) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            let fallback = withUnsafeBytes(of: &bsd.pbi_comm) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            var context = contextReader.read(pid: pid, started: confirmed.ri_proc_start_abstime, startSeconds: bsd.pbi_start_tvsec, name: name, path: path, userID: bsd.pbi_uid)
            if BrowserTabs.isRenderer(path), let named = names.names(pid: pid, started: confirmed.ri_proc_start_abstime) {
                context = ProcessContext(browserTasks: named.tasks, browserTasksSeen: named.seen)
            }
            // Context belongs to the same process identity, even if a runtime
            // exits while cwd/descriptor metadata is being read.
            guard let identity = readUsage(pid), identity.info.ri_proc_start_abstime == confirmed.ri_proc_start_abstime else { continue }
            let latest = identity.info
            records.append(.init(pid: pid, parentPID: Int32(bsd.pbi_ppid), userID: bsd.pbi_uid,
                                 started: confirmed.ri_proc_start_abstime, name: !name.isEmpty ? name : (!fallback.isEmpty ? fallback : "Process \(pid)"),
                                 executablePath: path, bytes: latest.ri_phys_footprint,
                                 cpuTicks: latest.ri_user_time &+ latest.ri_system_time,
                                 energyNanojoules: identity.hasEnergy ? latest.ri_energy_nj : nil,
                                 sampledUptime: ProcessInfo.processInfo.systemUptime, context: context))
        }
        paths = nextPaths
        contextReader.retain(Set(records.map(\.pid)))
        names.retain(Set(records.map(\.pid)))
        return .init(consumers: MemoryAttribution.group(records, applications: applications), listedCount: listed.count,
                     readableCount: records.count, unavailableCount: listed.count - records.count, sampledAt: Date(), error: nil)
    }
}
