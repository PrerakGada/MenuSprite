import AIAccounts
import Darwin
import Foundation

// "Report a Problem…" and "Send Feedback…" post one message to the shared product-feedback endpoint
// (company spec: product-feedback.md). Everything here is pure or goes through an injected transport,
// so tests and headless launches never reach the network. Only a 2xx counts as sent; there are no
// retries, no queue and no background sending.

/// What the person is telling us. The raw value is the API's `kind`.
public enum FeedbackKind: String, CaseIterable, Identifiable, Sendable {
    case problem, idea, feedback

    public var id: String { rawValue }

    /// The segment label in the form.
    public var label: String {
        switch self {
        case .problem: "Problem"
        case .idea: "Idea"
        case .feedback: "Other feedback"
        }
    }

    /// The window title while this kind is chosen.
    public var windowTitle: String { self == .problem ? "Report a Problem" : "Send Feedback" }

    /// The message box's placeholder.
    public func placeholder(appName: String) -> String {
        switch self {
        case .problem: "What happened, and what did you expect to happen?"
        case .idea: "What would make \(appName) better for you?"
        case .feedback: "Anything you'd like to tell me."
        }
    }
}

/// The only facts that travel with a message besides what the person typed. The form lists them
/// word for word (`summary`), so nothing goes that the person cannot see.
public struct FeedbackContext: Equatable, Sendable {
    public var appName: String
    public var version: String
    public var build: String
    public var platform: String
    public var osVersion: String
    /// `sysctl hw.model`, e.g. "Mac16,5". Optional in the API; left out when it cannot be read.
    public var deviceModel: String?

    public init(appName: String, version: String, build: String, platform: String = "macOS", osVersion: String, deviceModel: String?) {
        self.appName = appName; self.version = version; self.build = build
        self.platform = platform; self.osVersion = osVersion; self.deviceModel = deviceModel
    }

    /// This app, this Mac. Reads the bundle's version strings, the OS version and the model name only.
    public static func current(appName: String, bundle: Bundle = .main) -> FeedbackContext {
        let info = bundle.infoDictionary
        return FeedbackContext(appName: appName,
                               version: info?["CFBundleShortVersionString"] as? String ?? "dev",
                               build: info?["CFBundleVersion"] as? String ?? "dev",
                               osVersion: osVersion(from: ProcessInfo.processInfo.operatingSystemVersionString),
                               deviceModel: hardwareModel())
    }

    /// "Version 26.0 (Build 25A354)" → "26.0 (25A354)".
    static func osVersion(from description: String) -> String {
        description.replacingOccurrences(of: "Version ", with: "")
            .replacingOccurrences(of: "Build ", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    static func hardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1, size < 256 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
        let model = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return model.isEmpty ? nil : model
    }

    /// "MenuSprite 0.5.9 (20) · macOS 26.0 (25A354) · Mac16,5", shown under "Sent with your message:".
    public var summary: String {
        (["\(appName) \(version) (\(build))", "\(platform) \(osVersion)"] + [deviceModel].compactMap { $0 })
            .joined(separator: " · ")
    }

    /// "MenuSprite/0.5.9 (20; macOS 26.0 (25A354))".
    public var userAgent: String { "\(appName)/\(version) (\(build); \(platform) \(osVersion))" }
}

/// What the person typed. Nothing here is saved anywhere; it lives only as long as the window.
public struct FeedbackDraft: Equatable, Sendable {
    public var kind: FeedbackKind
    public var message: String
    public var name: String
    public var email: String

    public static let minimumCharacters = 3
    public static let maximumMessageLength = 5000
    public static let maximumNameLength = 100
    public static let maximumEmailLength = 254

    public init(kind: FeedbackKind, message: String = "", name: String = "", email: String = "") {
        self.kind = kind; self.message = message; self.name = name; self.email = email
    }

    var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Send is enabled once the message has at least three characters that are not spaces.
    public var canSend: Bool {
        message.unicodeScalars.lazy.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.prefix(Self.minimumCharacters).count
            >= Self.minimumCharacters
    }

    /// Why the server would refuse this, in the server's own words, so the answer comes without a round
    /// trip. Lengths are counted the way the server counts them (UTF-16).
    public var problem: String? {
        if trimmedMessage.utf16.count > Self.maximumMessageLength { return "That message is too long (5,000 characters at most)." }
        if trimmedName.utf16.count > Self.maximumNameLength || trimmedEmail.utf16.count > Self.maximumEmailLength {
            return "Your name or email is too long."
        }
        if !trimmedEmail.isEmpty, trimmedEmail.wholeMatch(of: /[^\s@]+@[^\s@]+\.[^\s@]+/) == nil {
            return "Enter a valid email, or leave it blank."
        }
        return nil
    }
}

/// How a send ended.
public enum FeedbackOutcome: Equatable, Sendable {
    case sent(id: String?)
    /// A 400 or 429 with the server's own sentence, shown as it is.
    case rejected(String)
    /// Anything else: another status, no network, or no answer within the time limit.
    case failed

    public static let couldNotSend = "Couldn't send. Check your connection and try again."

    /// The inline error, or nil once it is sent.
    public var errorMessage: String? {
        switch self {
        case .sent: nil
        case .rejected(let message): message
        case .failed: Self.couldNotSend
        }
    }
}

/// Stands in for the network wherever a real send must never happen: tests, validation, render and
/// measurement launches. It fails at once, so a press there reads "Couldn't send".
public struct OfflineFeedbackTransport: HTTPTransport {
    public init() {}
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw URLError(.notConnectedToInternet) }
}

/// Builds and sends one feedback request for one product.
public struct FeedbackClient: Sendable {
    public static let origin = URL(string: "https://api.prerakgada.in")!
    public let endpoint: URL
    public let context: FeedbackContext
    let transport: any HTTPTransport
    let timeout: Duration

    public init(product slug: String, context: FeedbackContext, transport: any HTTPTransport, timeout: Duration = .seconds(15)) {
        endpoint = Self.origin.appending(path: "v1/p/\(slug)/feedback")
        self.context = context
        self.transport = transport
        self.timeout = timeout
    }

    /// The body sent: what the person typed, then the facts the form lists. Empty name and email are
    /// left out rather than sent blank.
    struct Body: Encodable, Equatable {
        var kind: String
        var message: String
        var name: String?
        var email: String?
        var appVersion: String
        var build: String
        var platform: String
        var osVersion: String
        var deviceModel: String?
        var source = "app"
    }

    func body(for draft: FeedbackDraft) -> Body {
        Body(kind: draft.kind.rawValue, message: draft.trimmedMessage,
             name: draft.trimmedName.isEmpty ? nil : draft.trimmedName,
             email: draft.trimmedEmail.isEmpty ? nil : draft.trimmedEmail,
             appVersion: context.version, build: context.build, platform: context.platform,
             osVersion: context.osVersion, deviceModel: context.deviceModel)
    }

    public func request(for draft: FeedbackDraft) throws -> HTTPRequest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return HTTPRequest(method: "POST", url: endpoint,
                           headers: ["Content-Type": "application/json", "Accept": "application/json", "User-Agent": context.userAgent],
                           body: try encoder.encode(body(for: draft)),
                           timeout: Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18)
    }

    /// One attempt, at most `timeout` long. Cancelling the calling task cancels the request.
    public func send(_ draft: FeedbackDraft) async -> FeedbackOutcome {
        guard draft.canSend else { return .rejected("Write a few words about it first.") }
        if let problem = draft.problem { return .rejected(problem) }
        guard let request = try? request(for: draft) else { return .failed }
        let transport = self.transport, timeout = self.timeout
        let response = await withTaskGroup(of: HTTPResponse?.self) { group in
            group.addTask { try? await transport.send(request) }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return response.map(Self.outcome(for:)) ?? .failed
    }

    /// 2xx is sent; a 400 or 429 carrying `{"error": "…"}` shows that sentence; everything else is the
    /// generic failure.
    static func outcome(for response: HTTPResponse) -> FeedbackOutcome {
        let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        if response.isSuccess { return .sent(id: object?["id"] as? String) }
        if response.statusCode == 400 || response.statusCode == 429,
           let message = (object?["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            return .rejected(message)
        }
        return .failed
    }
}
