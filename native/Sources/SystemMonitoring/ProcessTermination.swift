import Foundation
import Darwin

/// One process a panel row offers to quit. `started` is the same birth stamp the
/// sampler groups by, so a signal can be refused when a PID has been reused.
public struct ProcessQuitTarget: Sendable, Equatable, Identifiable {
    public let pid: Int32
    public let started: UInt64
    public let name: String
    public let ownedByUser: Bool
    public var id: Int32 { pid }
    public init(pid: Int32, started: UInt64, name: String, ownedByUser: Bool) {
        self.pid = pid; self.started = started; self.name = name; self.ownedByUser = ownedByUser
    }
}

public struct ProcessQuitPlan: Sendable, Equatable {
    /// The consumer id the row was laid out for, so follow-up work can find the
    /// same row in a list that re-ranks under it.
    public let id: String
    public let title: String
    public let targets: [ProcessQuitTarget]
    /// The row is MenuSprite itself; quitting it is the app's own Quit, never a signal.
    public let isOwnApplication: Bool
    /// A row that stands for several independent sessions. It offers no quit of
    /// its own: one click would end every session, including busy ones.
    public var groupedSessions: Int = 0
    /// An Arc page row. Ending its process would crash the tab rather than close
    /// it, so the row offers nothing; the tab is closed in Arc.
    public var browserPage = false
    public var ownTargets: [ProcessQuitTarget] { targets.filter(\.ownedByUser) }
    public var canQuit: Bool { !ownTargets.isEmpty }
    /// Every listed process belongs to another user or to the system.
    public var blockedByOwnership: Bool { !targets.isEmpty && ownTargets.isEmpty }
}

public enum ProcessSignalOutcome: Sendable, Equatable {
    case delivered
    /// The PID now belongs to a different process; nothing was signalled.
    case identityChanged
    case notPermitted
    case alreadyExited
    case failed(Int32)
}

/// Quitting is an ordinary user action: a request to the running application, or
/// a signal to a process this user owns. No helper, privilege or root path.
public enum ProcessTermination {
    public static func plan(for consumer: MemoryConsumer, userID: UInt32 = getuid(), ownPID: Int32 = getpid()) -> ProcessQuitPlan {
        if let members = consumer.members, !members.isEmpty {
            return ProcessQuitPlan(id: consumer.id, title: consumer.presentation.title, targets: [], isOwnApplication: false, groupedSessions: members.count)
        }
        if let role = BrowserTabs.role(of: consumer.id), role == .page || role == .frames {
            return ProcessQuitPlan(id: consumer.id, title: consumer.presentation.title, targets: [], isOwnApplication: false, browserPage: true)
        }
        var seen = Set<Int32>()
        // launchd and the kernel task are never offered; PID 1 would refuse anyway.
        let targets = consumer.processes.filter { $0.pid > 1 }.sorted { $0.pid < $1.pid }.compactMap { record -> ProcessQuitTarget? in
            guard seen.insert(record.pid).inserted else { return nil }
            return ProcessQuitTarget(pid: record.pid, started: record.started, name: record.name, ownedByUser: record.userID == userID)
        }
        return ProcessQuitPlan(id: consumer.id, title: consumer.presentation.title, targets: targets,
                               isOwnApplication: targets.contains { $0.pid == ownPID })
    }

    /// Birth stamp from the same kernel counter the sampler reads, so an identity
    /// check compares like with like.
    public static func startTime(of pid: Int32) -> UInt64? {
        var info = rusage_info_v6()
        func read(_ flavor: Int32) -> Int32 {
            withUnsafeMutablePointer(to: &info) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, flavor, $0) }
            }
        }
        if read(RUSAGE_INFO_V6) == 0 { return info.ri_proc_start_abstime }
        guard errno == EINVAL || errno == ENOTSUP else { return nil }
        info = rusage_info_v6()
        return read(RUSAGE_INFO_V4) == 0 ? info.ri_proc_start_abstime : nil
    }

    /// Confirms the PID still belongs to the sampled process before signalling it.
    /// The remaining window between the check and `kill` is microseconds wide and
    /// also requires a PID to be recycled inside it; macOS offers no atomic form.
    @discardableResult
    public static func send(_ signal: Int32, to target: ProcessQuitTarget) -> ProcessSignalOutcome {
        guard target.pid > 1 else { return .notPermitted }
        guard target.ownedByUser else { return .notPermitted }
        guard let started = startTime(of: target.pid) else { return .alreadyExited }
        guard started == target.started else { return .identityChanged }
        if kill(target.pid, signal) == 0 { return .delivered }
        switch errno {
        case EPERM: return .notPermitted
        case ESRCH: return .alreadyExited
        default: return .failed(errno)
        }
    }

    /// The footer line a panel shows after acting. States what actually happened,
    /// including partial results; never claims an application has quit.
    public static func summary(title: String, outcomes: [ProcessSignalOutcome], forced: Bool) -> String {
        guard !outcomes.isEmpty else { return "Nothing left to quit in \(title)." }
        let delivered = outcomes.filter { $0 == .delivered }.count
        let verb = forced ? "Force quit" : "Asked"
        let tail = forced ? "" : " to quit"
        var reasons: [String] = []
        if outcomes.contains(.notPermitted) { reasons.append("macOS did not permit it") }
        if outcomes.contains(.identityChanged) { reasons.append("a PID had already been reused") }
        if outcomes.contains(.alreadyExited) { reasons.append("some had already exited") }
        if let code = outcomes.compactMap({ if case let .failed(code) = $0 { code } else { nil } }).first {
            reasons.append("macOS reported error \(code)")
        }
        if delivered == 0 { return "Could not quit \(title): " + (reasons.first ?? "no process responded") + "." }
        if reasons.isEmpty {
            return outcomes.count == 1 ? "\(verb) \(title)\(tail)." : "\(verb) \(title)\(tail) (\(outcomes.count) processes)."
        }
        return "\(verb) \(delivered) of \(outcomes.count) processes in \(title)\(tail); " + reasons.joined(separator: ", ") + "."
    }
}
