import Foundation
import IslandKit

/// Runs a speed test only when the person presses the button: latency, download and upload against
/// Cloudflare's public speed endpoints (`speed.cloudflare.com/__down` and `/__up`). The rules live in
/// `SpeedTestMachine`; this carries out its commands with an ephemeral session and feeds back what
/// happened. Nothing exists between tests: the session, its delegate, the time boxes and the upload
/// body are created on start and released the moment the test ends. No user data is sent — the
/// upload is zeros, streamed, never held in memory.
@MainActor
final class SpeedTestModel: ObservableObject {
    @Published private(set) var status: SpeedTestStatus = .idle
    @Published private(set) var lastResult: SpeedTestResult?
    /// The running transfer's five-second window, for the progress bar.
    @Published private(set) var window: ClosedRange<Date>?

    private var machine = SpeedTestMachine()
    private var session: URLSession?
    private var task: URLSessionTask?
    private var timeBoxes: [Int: DispatchWorkItem] = [:]

    static let endpoint = URL(string: "https://speed.cloudflare.com")!

    var isRunning: Bool { status.isRunning }

    func start() {
        guard !status.isRunning else { return }
        machine = SpeedTestMachine()
        let transport = SpeedTestTransport(uploadLength: machine.plan.uploadBytes) { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        let queue = OperationQueue()
        queue.name = "MenuSprite.SpeedTest"
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: transport, delegateQueue: queue)
        handle(.start)
    }

    func cancel() {
        guard status.isRunning else { return }
        handle(.cancel)
    }

    private func handle(_ event: SpeedTestMachine.Event) {
        for command in machine.handle(event) { perform(command) }
        if status != machine.status { status = machine.status }
        if case .finished(let result) = machine.status { lastResult = result }
        if machine.status.isTerminal { release() }
    }

    private func perform(_ command: SpeedTestMachine.Command) {
        guard let session else { return }
        switch command {
        case .requestLatency(let id):
            begin(session.dataTask(with: Self.download(bytes: 0)), .latency, id)
        case .requestDownload(let id):
            begin(session.dataTask(with: Self.download(bytes: machine.plan.downloadChunk)), .download, id)
        case .startUpload(let id):
            var request = URLRequest(url: Self.endpoint.appendingPathComponent("__up"))
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(String(machine.plan.uploadBytes), forHTTPHeaderField: "Content-Length")
            begin(session.uploadTask(withStreamedRequest: request), .upload, id)
        case .scheduleTimeBox(let id, let seconds):
            let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.timeBoxFired(id) } }
            timeBoxes[id] = item
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
            window = Date()...Date().addingTimeInterval(seconds)
        case .cancelTimeBox(let id):
            timeBoxes.removeValue(forKey: id)?.cancel()
        case .cancelTransfer:
            task?.cancel()
            task = nil
        }
    }

    private func begin(_ task: URLSessionTask, _ kind: SpeedTestTransport.Kind, _ id: Int) {
        task.taskDescription = SpeedTestTransport.tag(kind, id)
        self.task = task
        task.resume()
    }

    private func timeBoxFired(_ id: Int) {
        guard timeBoxes.removeValue(forKey: id) != nil else { return }
        window = nil
        let inFlight = machine.status == .running(.upload) ? (task?.countOfBytesSent ?? 0) : (task?.countOfBytesReceived ?? 0)
        handle(.timeBoxFired(id, inFlight: inFlight, at: ProcessInfo.processInfo.systemUptime))
    }

    private func release() {
        for item in timeBoxes.values { item.cancel() }
        timeBoxes = [:]
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        window = nil
    }

    private static func download(bytes: Int64) -> URLRequest {
        var components = URLComponents(url: endpoint.appendingPathComponent("__down"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "bytes", value: String(bytes))]
        return URLRequest(url: components.url!)
    }
}

/// The session's delegate for one test. It turns URLSession callbacks into machine events tagged
/// with the request's number, discards downloaded data as it arrives, and hands the upload a fresh
/// streamed body. It runs on the session's serial queue, and its own state is touched only there.
final class SpeedTestTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Kind: String { case latency, download, upload }

    private let send: @Sendable (SpeedTestMachine.Event) -> Void
    private let uploadLength: Int64
    private var roundTrips: [Int: Double] = [:]
    private var sending: Set<Int> = []
    private var bodies: [Int: ZeroBodyStream] = [:]

    init(uploadLength: Int64, send: @escaping @Sendable (SpeedTestMachine.Event) -> Void) {
        self.uploadLength = uploadLength
        self.send = send
    }

    static func tag(_ kind: Kind, _ id: Int) -> String { "\(kind.rawValue):\(id)" }

    private static func tag(of task: URLSessionTask) -> (Kind, Int)? {
        guard let parts = task.taskDescription?.split(separator: ":"), parts.count == 2,
              let kind = Kind(rawValue: String(parts[0])), let id = Int(parts[1]) else { return nil }
        return (kind, id)
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        if let (kind, id) = Self.tag(of: dataTask), kind != .latency {
            send(.response(id, status: (response as? HTTPURLResponse)?.statusCode ?? 0, at: now))
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {}

    func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void) {
        guard let (kind, _) = Self.tag(of: task), kind == .upload else { completionHandler(nil); return }
        bodies.removeValue(forKey: task.taskIdentifier)?.close()
        let body = ZeroBodyStream(length: uploadLength)
        bodies[task.taskIdentifier] = body
        completionHandler(body.input)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let (kind, id) = Self.tag(of: task), kind == .upload, sending.insert(id).inserted else { return }
        send(.sending(id, bytes: totalBytesSent, at: now))
    }

    /// Latency is the time from sending the request to the first byte of the reply, so connection
    /// setup on the first request does not count.
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        if let transaction = metrics.transactionMetrics.last, let start = transaction.requestStartDate,
           let end = transaction.responseStartDate {
            roundTrips[task.taskIdentifier] = end.timeIntervalSince(start)
        } else {
            roundTrips[task.taskIdentifier] = metrics.taskInterval.duration
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        bodies.removeValue(forKey: task.taskIdentifier)?.close()
        let roundTrip = roundTrips.removeValue(forKey: task.taskIdentifier)
        guard let (kind, id) = Self.tag(of: task) else { return }
        switch kind {
        case .latency:
            let status = error == nil ? (task.response as? HTTPURLResponse)?.statusCode : nil
            send(.latency(id, status: status, roundTrip: roundTrip))
        case .download:
            send(.completed(id, failed: error != nil, bytes: task.countOfBytesReceived, at: now))
        case .upload:
            send(.completed(id, failed: error != nil, bytes: task.countOfBytesSent, at: now))
        }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        for body in bodies.values { body.close() }
        bodies = [:]
    }
}
