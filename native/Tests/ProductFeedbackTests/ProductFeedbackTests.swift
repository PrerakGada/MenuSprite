import AIAccounts
import Foundation
import Testing
@testable import ProductFeedback

/// Records every request and answers from a handler; never touches the network.
final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) throws -> HTTPResponse
    private let lock = NSLock()
    private let handler: Handler
    private let delay: Duration
    private var recorded: [HTTPRequest] = []

    init(delay: Duration = .zero, _ handler: @escaping Handler) {
        self.delay = delay
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { recorded.append(request) }
        if delay > .zero { try await Task.sleep(for: delay) }
        return try handler(request)
    }

    var requests: [HTTPRequest] { lock.withLock { recorded } }
}

private let context = FeedbackContext(appName: "MenuSprite", version: "0.5.9", build: "20",
                                      osVersion: "26.0 (25A354)", deviceModel: "Mac16,5")

private func client(_ transport: any HTTPTransport, timeout: Duration = .seconds(15)) -> FeedbackClient {
    FeedbackClient(product: "menusprite", context: context, transport: transport, timeout: timeout)
}

private func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: ["content-type": "application/json"],
                 body: try! JSONSerialization.data(withJSONObject: object))
}

private func bodyObject(_ request: HTTPRequest) throws -> [String: Any] {
    let data = try #require(request.body)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - The request

@Test func postsTheSharedEndpointWithTheSpecHeaders() async throws {
    let transport = RecordingTransport { _ in json(201, ["ok": true, "id": "fb_1"]) }
    let outcome = await client(transport).send(FeedbackDraft(kind: .problem, message: "The fan board is blank"))
    #expect(outcome == .sent(id: "fb_1"))
    let request = try #require(transport.requests.first)
    #expect(transport.requests.count == 1)
    #expect(request.method == "POST")
    #expect(request.url.absoluteString == "https://api.prerakgada.in/v1/p/menusprite/feedback")
    #expect(request.headers["Content-Type"] == "application/json")
    #expect(request.headers["User-Agent"] == "MenuSprite/0.5.9 (20; macOS 26.0 (25A354))")
    #expect(request.timeout == 15)
}

@Test func bodyCarriesOnlyWhatWasTypedAndTheListedFacts() async throws {
    let transport = RecordingTransport { _ in json(201, ["ok": true, "id": "fb_2"]) }
    _ = await client(transport).send(FeedbackDraft(kind: .idea, message: "  Add a clock sprite\n", name: " Asha ", email: " asha@example.com "))
    let body = try bodyObject(try #require(transport.requests.first))
    #expect(Set(body.keys) == ["kind", "message", "name", "email", "appVersion", "build", "platform", "osVersion", "deviceModel", "source"])
    #expect(body["kind"] as? String == "idea")
    #expect(body["message"] as? String == "Add a clock sprite")
    #expect(body["name"] as? String == "Asha")
    #expect(body["email"] as? String == "asha@example.com")
    #expect(body["appVersion"] as? String == "0.5.9")
    #expect(body["build"] as? String == "20")
    #expect(body["platform"] as? String == "macOS")
    #expect(body["osVersion"] as? String == "26.0 (25A354)")
    #expect(body["deviceModel"] as? String == "Mac16,5")
    #expect(body["source"] as? String == "app")
}

@Test func blankNameEmailAndUnknownModelAreLeftOut() async throws {
    let transport = RecordingTransport { _ in json(201, ["ok": true, "id": "fb_3"]) }
    var bare = context; bare.deviceModel = nil
    _ = await FeedbackClient(product: "menusprite", context: bare, transport: transport)
        .send(FeedbackDraft(kind: .feedback, message: "Nice app", name: "   ", email: ""))
    let body = try bodyObject(try #require(transport.requests.first))
    #expect(body["name"] == nil && body["email"] == nil && body["deviceModel"] == nil)
    #expect(body["kind"] as? String == "feedback")
}

@Test func everyKindMapsToTheAPIValue() {
    #expect(FeedbackKind.allCases.map(\.rawValue) == ["problem", "idea", "feedback"])
    #expect(FeedbackKind.allCases.map(\.label) == ["Problem", "Idea", "Other feedback"])
    #expect(FeedbackKind.problem.placeholder(appName: "MenuSprite") == "What happened, and what did you expect to happen?")
    #expect(FeedbackKind.idea.placeholder(appName: "MenuSprite") == "What would make MenuSprite better for you?")
    #expect(FeedbackKind.feedback.placeholder(appName: "MenuSprite") == "Anything you'd like to tell me.")
}

// MARK: - Checks before sending

@Test func sendNeedsThreeCharactersThatAreNotSpaces() {
    #expect(!FeedbackDraft(kind: .problem, message: "").canSend)
    #expect(!FeedbackDraft(kind: .problem, message: "  a b \n").canSend)
    #expect(!FeedbackDraft(kind: .problem, message: "\n\t  ").canSend)
    #expect(FeedbackDraft(kind: .problem, message: " a b c ").canSend)
    #expect(FeedbackDraft(kind: .problem, message: "Hey").canSend)
}

@Test func localChecksUseTheServersWords() {
    #expect(FeedbackDraft(kind: .idea, message: "ok!", email: "not-an-email").problem == "Enter a valid email, or leave it blank.")
    #expect(FeedbackDraft(kind: .idea, message: "ok!", email: "a@b").problem == "Enter a valid email, or leave it blank.")
    #expect(FeedbackDraft(kind: .idea, message: "ok!", email: "a@example.org").problem == nil)
    #expect(FeedbackDraft(kind: .idea, message: String(repeating: "x", count: 5001)).problem == "That message is too long (5,000 characters at most).")
    #expect(FeedbackDraft(kind: .idea, message: String(repeating: "x", count: 5000)).problem == nil)
    #expect(FeedbackDraft(kind: .idea, message: "ok!", name: String(repeating: "n", count: 101)).problem == "Your name or email is too long.")
}

@Test func aDraftTheServerWouldRefuseIsNeverSent() async {
    let transport = RecordingTransport { _ in json(201, ["ok": true]) }
    let invalid = await client(transport).send(FeedbackDraft(kind: .problem, message: "Broken", email: "nope"))
    let short = await client(transport).send(FeedbackDraft(kind: .problem, message: " a "))
    #expect(invalid == .rejected("Enter a valid email, or leave it blank."))
    #expect(short == .rejected("Write a few words about it first."))
    #expect(transport.requests.isEmpty)
}

// MARK: - The reply

@Test func onlyTwoHundredsCountAsSent() async {
    for status in [200, 201, 204] {
        let outcome = await client(RecordingTransport { _ in HTTPResponse(statusCode: status) }).send(FeedbackDraft(kind: .idea, message: "Thanks!"))
        #expect(outcome == .sent(id: nil))
        #expect(outcome.errorMessage == nil)
    }
    for status in [301, 404, 500, 502, 503] {
        let outcome = await client(RecordingTransport { _ in json(status, ["error": "Unknown product."]) }).send(FeedbackDraft(kind: .idea, message: "Thanks!"))
        #expect(outcome == .failed)
        #expect(outcome.errorMessage == "Couldn't send. Check your connection and try again.")
    }
}

@Test func fourHundredAndRateLimitShowTheServersSentence() async {
    let limited = await client(RecordingTransport { _ in
        json(429, ["error": "That's a lot of messages in a short time. Please try again in a few minutes."])
    }).send(FeedbackDraft(kind: .problem, message: "Again"))
    #expect(limited.errorMessage == "That's a lot of messages in a short time. Please try again in a few minutes.")
    let invalid = await client(RecordingTransport { _ in json(400, ["error": "Write a few words about it first."]) })
        .send(FeedbackDraft(kind: .problem, message: "abc"))
    #expect(invalid == .rejected("Write a few words about it first."))
    let bare = await client(RecordingTransport { _ in HTTPResponse(statusCode: 400, body: Data("<html>".utf8)) })
        .send(FeedbackDraft(kind: .problem, message: "abc"))
    #expect(bare == .failed)
}

@Test func noNetworkIsTheGenericFailure() async {
    let outcome = await client(OfflineFeedbackTransport()).send(FeedbackDraft(kind: .problem, message: "Offline"))
    #expect(outcome == .failed)
    let thrown = await client(RecordingTransport { _ in throw URLError(.timedOut) }).send(FeedbackDraft(kind: .problem, message: "Late"))
    #expect(thrown == .failed)
}

@Test func noAnswerWithinTheLimitIsAFailureAndTheRequestIsCancelled() async {
    let transport = RecordingTransport(delay: .seconds(30)) { _ in json(201, ["ok": true]) }
    let started = ContinuousClock.now
    let outcome = await client(transport, timeout: .milliseconds(100)).send(FeedbackDraft(kind: .problem, message: "Slow server"))
    #expect(outcome == .failed)
    #expect(ContinuousClock.now - started < .seconds(5))
    #expect(transport.requests.count == 1)
}

@Test func cancellingTheCallerCancelsTheSend() async {
    let transport = RecordingTransport(delay: .seconds(30)) { _ in json(201, ["ok": true]) }
    let task = Task { await client(transport).send(FeedbackDraft(kind: .idea, message: "Closing the window")) }
    try? await Task.sleep(for: .milliseconds(50))
    task.cancel()
    let started = ContinuousClock.now
    #expect(await task.value == .failed)
    #expect(ContinuousClock.now - started < .seconds(5))
}

// MARK: - What the form shows

@Test func summaryListsExactlyWhatIsSent() {
    #expect(context.summary == "MenuSprite 0.5.9 (20) · macOS 26.0 (25A354) · Mac16,5")
    var bare = context; bare.deviceModel = nil
    #expect(bare.summary == "MenuSprite 0.5.9 (20) · macOS 26.0 (25A354)")
}

@Test func osVersionDropsTheWordsAroundIt() {
    #expect(FeedbackContext.osVersion(from: "Version 26.0 (Build 25A354)") == "26.0 (25A354)")
    #expect(FeedbackContext.osVersion(from: "Version 27.0.1 (Build 27A5301e)") == "27.0.1 (27A5301e)")
}

@Test func thisMacReportsAModelName() {
    // Reads sysctl only. Apple Silicon names look like "Mac16,5"; a VM may say something else.
    let model = FeedbackContext.hardwareModel()
    #expect(model.map { !$0.isEmpty && !$0.contains("\0") } ?? true)
    let current = FeedbackContext.current(appName: "MenuSprite")
    #expect(current.platform == "macOS" && !current.osVersion.hasPrefix("Version"))
}
