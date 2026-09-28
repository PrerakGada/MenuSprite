import Foundation

public enum SpeedTestPhase: String, Sendable, Equatable {
    case latency, download, upload
}

/// Latency in milliseconds: the median round trip, and jitter as the mean change between
/// consecutive round trips.
public struct SpeedTestLatency: Equatable, Sendable {
    public var median: Double
    public var jitter: Double
    public init(median: Double, jitter: Double) { self.median = median; self.jitter = jitter }
}

public struct SpeedTestResult: Equatable, Sendable {
    /// Megabits per second.
    public var download: Double
    public var upload: Double
    public var latency: SpeedTestLatency
    public init(download: Double, upload: Double, latency: SpeedTestLatency) {
        self.download = download; self.upload = upload; self.latency = latency
    }
}

public enum SpeedTestStatus: Equatable, Sendable {
    case idle
    case running(SpeedTestPhase)
    case finished(SpeedTestResult)
    case failed(SpeedTestPhase)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .finished, .failed, .cancelled: true
        case .idle, .running: false
        }
    }

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

public enum SpeedTestMath {
    /// Megabits per second: bytes × 8 ÷ seconds ÷ 1,000,000. Nil when nothing moved or no time passed.
    public static func megabitsPerSecond(bytes: Int64, seconds: Double) -> Double? {
        guard bytes > 0, seconds > 0, seconds.isFinite else { return nil }
        return Double(bytes) * 8 / seconds / 1_000_000
    }

    /// Median and jitter of round trips in milliseconds, in the order they were measured.
    public static func latency(_ roundTrips: [Double]) -> SpeedTestLatency? {
        guard !roundTrips.isEmpty else { return nil }
        let sorted = roundTrips.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        let changes = zip(roundTrips, roundTrips.dropFirst()).map { abs($1 - $0) }
        let jitter = changes.isEmpty ? 0 : changes.reduce(0, +) / Double(changes.count)
        return SpeedTestLatency(median: median, jitter: jitter)
    }

    /// Whole numbers from 100 up, one decimal below.
    public static func format(_ megabits: Double) -> String {
        megabits >= 100 ? String(Int(megabits.rounded())) : String(format: "%.1f", megabits)
    }
}

/// What one test does: five latency requests, then five seconds of downloading and five of uploading.
public struct SpeedTestPlan: Equatable, Sendable {
    public var latencySamples = 5
    public var downloadSeconds = 5.0
    public var uploadSeconds = 5.0
    /// Each download request asks for this much; the service caps a request just under 100 MB.
    public var downloadChunk: Int64 = 90_000_000
    /// One upload of this many zero bytes, streamed rather than held in memory.
    public var uploadBytes: Int64 = 100_000_000

    public init() {}
    public static let standard = SpeedTestPlan()
}

/// The speed test as a state machine with no networking in it. The runner feeds it what the network
/// did (with the request's number, so a stale callback is recognised) and carries out the commands it
/// returns. Keeping the rules here makes every one of them testable:
///
/// - a non-success status or an error fails the phase at once, and nothing further is requested;
/// - a transfer's time box opens only once data is really moving (a download's first accepted
///   response, the upload's first bytes sent), so a failure before that schedules none;
/// - bytes count only from responses that were accepted, so an error body is never download traffic;
/// - every time box that opens is either fired or cancelled, and a terminal test ignores everything.
public struct SpeedTestMachine: Sendable {
    public enum Command: Equatable, Sendable {
        case requestLatency(Int)
        case requestDownload(Int)
        case startUpload(Int)
        case scheduleTimeBox(Int, seconds: Double)
        case cancelTimeBox(Int)
        /// Stop whatever request is in flight.
        case cancelTransfer
    }

    public enum Event: Equatable, Sendable {
        case start
        /// A latency request ended: its status (nil when it failed) and its round trip in seconds.
        case latency(Int, status: Int?, roundTrip: Double?)
        /// A download or the upload received its response headers.
        case response(Int, status: Int, at: Double)
        /// The upload's body began to leave: `bytes` sent so far.
        case sending(Int, bytes: Int64, at: Double)
        /// A transfer ended; `bytes` is what it moved in total (received, or sent for the upload).
        case completed(Int, failed: Bool, bytes: Int64, at: Double)
        /// A time box closed; `inFlight` is what the current transfer had moved by then.
        case timeBoxFired(Int, inFlight: Int64, at: Double)
        case cancel
    }

    public let plan: SpeedTestPlan
    public private(set) var status: SpeedTestStatus = .idle

    private var serial = 0
    private var request = 0
    private var box: Int?
    private var accepted = false
    private var windowStart: Double?
    private var baseline: Int64 = 0
    private var finishedChunks: Int64 = 0
    private var roundTrips: [Double] = []
    private var latency: SpeedTestLatency?
    private var download: Double?

    public init(plan: SpeedTestPlan = .standard) { self.plan = plan }

    public mutating func handle(_ event: Event) -> [Command] {
        if event == .cancel { return stop(as: .cancelled) }
        switch (status, event) {
        case (.idle, .start):
            status = .running(.latency)
            return [.requestLatency(nextRequest())]

        case (.running(.latency), .latency(let id, let code, let roundTrip)) where id == request:
            guard let code, Self.success(code), let roundTrip, roundTrip >= 0 else { return stop(as: .failed(.latency)) }
            roundTrips.append(roundTrip * 1000)
            if roundTrips.count < plan.latencySamples { return [.requestLatency(nextRequest())] }
            latency = SpeedTestMath.latency(roundTrips)
            status = .running(.download)
            accepted = false
            return [.requestDownload(nextRequest())]

        case (.running(.download), .response(let id, let code, let at)) where id == request:
            guard Self.success(code) else { return stop(as: .failed(.download)) }
            accepted = true
            guard box == nil, windowStart == nil else { return [] }
            windowStart = at
            return [.scheduleTimeBox(openBox(), seconds: plan.downloadSeconds)]

        case (.running(.download), .completed(let id, let failed, let bytes, _)) where id == request:
            guard !failed, accepted else { return stop(as: .failed(.download)) }
            finishedChunks += bytes
            accepted = false
            return [.requestDownload(nextRequest())]

        case (.running(.download), .timeBoxFired(let id, let inFlight, let at)) where id == box:
            box = nil
            let total = finishedChunks + (accepted ? inFlight : 0)
            guard let start = windowStart, let rate = SpeedTestMath.megabitsPerSecond(bytes: total, seconds: at - start) else {
                return stop(as: .failed(.download))
            }
            download = rate
            status = .running(.upload)
            accepted = false
            windowStart = nil
            return [.cancelTransfer, .startUpload(nextRequest())]

        case (.running(.upload), .sending(let id, let bytes, let at)) where id == request:
            guard windowStart == nil else { return [] }
            windowStart = at
            baseline = bytes
            return [.scheduleTimeBox(openBox(), seconds: plan.uploadSeconds)]

        case (.running(.upload), .response(let id, let code, _)) where id == request:
            guard Self.success(code) else { return stop(as: .failed(.upload)) }
            accepted = true
            return []

        case (.running(.upload), .completed(let id, let failed, let bytes, let at)) where id == request:
            guard !failed, accepted else { return stop(as: .failed(.upload)) }
            let cancelBox = box.map { [Command.cancelTimeBox($0)] } ?? []
            box = nil
            return finish(sent: bytes, at: at, before: cancelBox)

        case (.running(.upload), .timeBoxFired(let id, let inFlight, let at)) where id == box:
            box = nil
            return finish(sent: inFlight, at: at, before: [.cancelTransfer])

        default:
            // Stale callbacks, events out of order, and anything after the end.
            return []
        }
    }

    private static func success(_ status: Int) -> Bool { (200..<300).contains(status) }

    private mutating func nextRequest() -> Int {
        serial += 1
        request = serial
        return request
    }

    private mutating func openBox() -> Int {
        serial += 1
        box = serial
        return serial
    }

    private mutating func finish(sent: Int64, at: Double, before: [Command]) -> [Command] {
        guard let start = windowStart, let download, let latency,
              let upload = SpeedTestMath.megabitsPerSecond(bytes: sent - baseline, seconds: at - start) else {
            return before + stop(as: .failed(.upload)).filter { !before.contains($0) }
        }
        status = .finished(SpeedTestResult(download: download, upload: upload, latency: latency))
        return before
    }

    /// Ends the test (failed or cancelled): stop the transfer and cancel an open time box.
    private mutating func stop(as end: SpeedTestStatus) -> [Command] {
        guard !status.isTerminal else { return [] }
        let wasRunning = status.isRunning
        status = end
        guard wasRunning else { return [] }
        var commands: [Command] = [.cancelTransfer]
        if let box { commands.append(.cancelTimeBox(box)) }
        box = nil
        return commands
    }
}
