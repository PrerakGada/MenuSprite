import Foundation

/// Watches work sent to a serial driver queue. A CoreAudio or display call can block for as long as a
/// Bluetooth or USB device takes to reconnect, and everything queued behind it waits too. Once the
/// oldest unfinished job has waited longer than the limit, the queue is abandoned: the generation
/// moves on, the owner starts a fresh queue, work still queued on the old one is skipped, and results
/// that come back from it later are not used.
public struct IslandHALWatchdog: Sendable {
    public struct Job: Hashable, Sendable {
        public let id: Int
        public let generation: Int
    }

    public let limit: TimeInterval
    public private(set) var generation = 0
    private var nextID = 1
    private var waiting: [Int: TimeInterval] = [:]

    public init(limit: TimeInterval) { self.limit = limit }

    public mutating func submit(now: TimeInterval) -> Job {
        let job = Job(id: nextID, generation: generation)
        nextID += 1
        waiting[job.id] = now
        return job
    }

    /// A job came back. True when its result belongs to the current queue and may be used.
    public mutating func finish(_ job: Job) -> Bool {
        guard job.generation == generation else { return false }
        waiting[job.id] = nil
        return true
    }

    public func isCurrent(_ job: Job) -> Bool { job.generation == generation }

    /// When the next check is due; nil when nothing is waiting (no timer at rest).
    public var deadline: TimeInterval? { waiting.values.min().map { $0 + limit } }

    /// True when the queue is stuck. The generation moves on and everything waiting is abandoned.
    public mutating func check(now: TimeInterval) -> Bool {
        guard let deadline, now >= deadline else { return false }
        generation += 1
        waiting.removeAll()
        return true
    }
}
