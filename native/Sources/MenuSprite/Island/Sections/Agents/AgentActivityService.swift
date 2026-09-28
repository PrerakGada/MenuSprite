import AIAccounts
import Foundation
import IslandKit

/// A turn that is working right now.
struct AgentLiveTurn: Equatable, Identifiable, Sendable {
    var id: String
    var agent: AgentKind
    /// The session's title (a rename, else Claude Code's own), when there is one.
    var title: String?
    var project: String?
    var model: String?
    var startedAt: Date
    var tokens: AgentTokens
    /// API list-price value of what was priced; nil when nothing could be.
    var cost: Double?
    var unpriced: Bool
    /// Part of the turn was written before the look-back limit: its spend is a minimum.
    var partial: Bool

    var name: String { title ?? project ?? agent.productName }
}

/// What the activity reader knows, published only when it changes.
struct AgentActivitySnapshot: Equatable, Sendable {
    var loaded = false
    /// Oldest first.
    var working: [AgentLiveTurn] = []
    var lastActivity: [AgentKind: Date] = [:]
    /// Agents that have left anything on this Mac.
    var seen: Set<AgentKind> = []

    /// Each working agent once, in the order their turns began.
    var workingAgents: [AgentKind] {
        var result: [AgentKind] = []
        for turn in working where !result.contains(turn.agent) { result.append(turn.agent) }
        return result
    }

    var earliestStart: Date? { working.map(\.startedAt).min() }
    var outputTokens: Int { working.reduce(0) { $0 + $1.tokens.output } }
    /// Summed value of the working turns, nil when none of it could be priced.
    var cost: Double? {
        let priced = working.compactMap(\.cost)
        return priced.isEmpty ? nil : priced.reduce(0, +)
    }
    var costIsMinimum: Bool { working.contains { $0.unpriced || $0.partial } }
    /// Some working turn began before what was read of it: token counts are a minimum.
    var tokensAreMinimum: Bool { working.contains(where: \.partial) }
}

/// A turn that just ended, for the "finished" notice.
struct AgentFinishedTurn: Sendable {
    var agent: AgentKind
    var duration: Double
    var endedAt: Date
    /// False for an interruption, an abort or an API error.
    var completed: Bool
    /// False while the first pass is still reading what happened before the island started.
    var armed: Bool
    var cost: Double?
    var title: String?
    var project: String?
}

/// The main-thread face of the activity reader. Starts the reader only when asked and drops it and
/// everything it read when stopped; results from a stopped reader are ignored.
@MainActor
final class AgentActivityService: ObservableObject {
    @Published private(set) var snapshot = AgentActivitySnapshot()
    var onFinish: ((AgentFinishedTurn) -> Void)?
    var onChange: (() -> Void)?

    private let paths: AgentPaths
    private var engine: AgentActivityEngine?
    private var engineID = UUID()
    private var configuration: AgentActivityConfiguration?

    init(paths: AgentPaths = .standard) { self.paths = paths }

    var isRunning: Bool { engine != nil }

    /// Runs with this configuration, or stops with nil.
    func run(_ configuration: AgentActivityConfiguration?) {
        guard let configuration else { stop(); return }
        if let engine {
            guard configuration != self.configuration else { return }
            self.configuration = configuration
            engine.update(configuration)
            return
        }
        let id = UUID()
        let box = AgentServiceBox(self)
        engineID = id
        self.configuration = configuration
        let engine = AgentActivityEngine(paths: paths, configuration: configuration,
                                         publish: Self.publisher(box, id), finish: Self.finisher(box, id), price: Self.price)
        self.engine = engine
        engine.start()
    }

    func stop() {
        engine?.stop()
        engine = nil
        configuration = nil
        engineID = UUID()
        if snapshot != AgentActivitySnapshot() {
            snapshot = AgentActivitySnapshot()
            onChange?()
        }
    }

    fileprivate func receive(_ snapshot: AgentActivitySnapshot, from id: UUID) {
        guard id == engineID, engine != nil, snapshot != self.snapshot else { return }
        self.snapshot = snapshot
        onChange?()
    }

    fileprivate func receive(_ turn: AgentFinishedTurn, from id: UUID) {
        guard id == engineID, engine != nil else { return }
        onFinish?(turn)
    }

    // The engine's callbacks run on its queue: they must not be main-actor closures.

    nonisolated private static func publisher(_ box: AgentServiceBox, _ id: UUID) -> AgentActivityEngine.Publish {
        { snapshot in DispatchQueue.main.async { MainActor.assumeIsolated { box.service?.receive(snapshot, from: id) } } }
    }

    nonisolated private static func finisher(_ box: AgentServiceBox, _ id: UUID) -> AgentActivityEngine.Finish {
        { turn in DispatchQueue.main.async { MainActor.assumeIsolated { box.service?.receive(turn, from: id) } } }
    }

    nonisolated static func price(_ model: String, _ tokens: AgentTokens) -> Double? {
        ModelPricing.cost(TokenBreakdown(input: tokens.input, cacheWrite5m: tokens.cacheWrite5m, cacheWrite1h: tokens.cacheWrite1h,
                                         cacheRead: tokens.cacheRead, output: tokens.output), model: model)
    }
}

/// Lets the engine's queue reach the service without keeping it alive.
private final class AgentServiceBox: @unchecked Sendable {
    weak var service: AgentActivityService?
    init(_ service: AgentActivityService) { self.service = service }
}
