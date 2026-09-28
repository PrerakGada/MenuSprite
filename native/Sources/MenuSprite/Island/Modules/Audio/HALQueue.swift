import Foundation
import IslandKit
import os

/// A serial queue for driver calls (CoreAudio, DisplayServices, DDC) that one stuck call cannot wedge.
/// A watchdog on the main actor notices work waiting longer than the limit; it then abandons the
/// queue (its thread may stay blocked in the driver), starts a fresh one for later work, skips work
/// still queued on the old one, and ignores results that come back from it. The owner is told both
/// when a queue is abandoned and when an abandoned call finally returns, so it can re-read then.
@MainActor
final class IslandHALQueue {
    private static let log = Logger(subsystem: "in.prerakgada.MenuSprite", category: "IslandDrivers")

    private let label: String
    private var queue: DispatchQueue
    private var watchdog: IslandHALWatchdog
    /// The current generation, readable from the queue so work queued behind a stuck call is skipped.
    private let current = OSAllocatedUnfairLock(initialState: 0)
    private var timer: Task<Void, Never>?
    /// The queue was abandoned: whatever it was doing is lost.
    var onStall: () -> Void = {}
    /// A call on an abandoned queue returned: the driver answers again.
    var onRecover: () -> Void = {}

    init(label: String, limit: TimeInterval) {
        self.label = label
        queue = DispatchQueue(label: label, qos: .userInitiated)
        watchdog = IslandHALWatchdog(limit: limit)
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Runs `work` on the queue and hands its result to `done` on the main actor, unless the queue is
    /// abandoned first, in which case `done` is never called.
    func run<Result: Sendable>(_ work: @escaping @Sendable () -> Result, done: @escaping @MainActor (Result) -> Void) {
        let job = watchdog.submit(now: now)
        let current = current
        queue.async {
            guard current.withLock({ $0 }) == job.generation else { return }
            let result = work()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in self?.finished(job, result: result, done: done) }
            }
        }
        arm()
    }

    /// Bookkeeping that must always run, in order, and is not watched (listener registration).
    func enqueue(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }

    private func finished<Result>(_ job: IslandHALWatchdog.Job, result: Result, done: @MainActor (Result) -> Void) {
        if watchdog.finish(job) {
            done(result)
        } else {
            Self.log.notice("\(self.label, privacy: .public): a stalled driver call returned")
            onRecover()
        }
    }

    /// One timer, only while work is waiting.
    private func arm() {
        guard timer == nil, let deadline = watchdog.deadline else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime)))
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            self.check()
        }
    }

    private func check() {
        if watchdog.check(now: now) {
            Self.log.error("\(self.label, privacy: .public): a driver call is stuck; continuing on a fresh queue")
            queue = DispatchQueue(label: label, qos: .userInitiated)
            let generation = watchdog.generation
            current.withLock { $0 = generation }
            onStall()
        }
        arm()
    }
}
