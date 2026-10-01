import AgentProtocol
import Foundation
import SystemMonitoring

/// The sprite spec: the JSON agents and people write, compiled into a `SpriteConfiguration` and emitted
/// back from one. The stored format is unchanged; this is a separate, versioned authoring contract.
/// Spec: `docs/agent-authoring.md` ("The sprite spec, version 1").
public enum SpriteSpecFormat {
    public static let version = 1
}

public enum SpriteSide: String, Codable, Sendable, CaseIterable {
    case left, right
}

/// What compiling, validating and emitting need from the app.
public struct SpecEnvironment: Sendable {
    /// A reading in the live catalog (discovered sensors included), or nil if the Mac has no such reading.
    public var metric: @Sendable (String) -> Metric?
    /// Every reading id in the catalog, for "did you mean" hints.
    public var readingIDs: @Sendable () -> [String]
    /// Whether an SF Symbol name exists on this Mac.
    public var symbolExists: @Sendable (String) -> Bool
    /// The folder a sprite's files live in.
    public var spriteDirectory: @Sendable (UUID) -> String
    /// Whether that folder already holds files (a spec that omits `files` keeps them).
    public var hasFiles: @Sendable (UUID) -> Bool

    public init(metric: @escaping @Sendable (String) -> Metric?,
                readingIDs: @escaping @Sendable () -> [String],
                symbolExists: @escaping @Sendable (String) -> Bool = { _ in true },
                spriteDirectory: @escaping @Sendable (UUID) -> String,
                hasFiles: @escaping @Sendable (UUID) -> Bool = { _ in false }) {
        self.metric = metric; self.readingIDs = readingIDs; self.symbolExists = symbolExists
        self.spriteDirectory = spriteDirectory; self.hasFiles = hasFiles
    }
}

/// A spec turned into what the app saves.
public struct CompiledSprite: Sendable {
    /// Ready for `MonitoringStore.save`. Its id is the existing sprite's, the spec's `id`, or new.
    public var config: SpriteConfiguration
    /// Nil when the spec does not say.
    public var side: SpriteSide?
    /// The files to write into the sprite's folder: nil keeps what is there, empty removes them all.
    public var files: [String: String]?
    /// Warnings only; a spec with errors does not compile.
    public var diagnostics: [SpecDiagnostic]
    public init(config: SpriteConfiguration, side: SpriteSide?, files: [String: String]?, diagnostics: [SpecDiagnostic]) {
        self.config = config; self.side = side; self.files = files; self.diagnostics = diagnostics
    }
}

extension SpriteSpecFormat {
    /// The `id` and `name` a spec names, so the app can find the sprite it replaces before compiling. The name
    /// is the one the sprite is saved under (`normalizedName`), so a long name finds the sprite it made.
    public static func identity(of spec: JSONValue) -> (id: UUID?, name: String?) {
        (spec["id"]?.string.flatMap(UUID.init(uuidString:)), spec["name"]?.string.map(normalizedName))
    }

    /// A name as it is saved: trimmed and cut to 40 characters, as `SpriteConfiguration.normalize()` cuts it,
    /// then trimmed again so a cut that ends on a space leaves none (no spec name, being trimmed, could match it).
    public static func normalizedName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Compiles `spec`. `existing` is the sprite it replaces (its id and settings-form fields are kept).
    /// Returns nil with at least one error diagnostic when the spec cannot be saved.
    ///
    /// Every problem is reported in one pass, each with the path it was found at. Nodes, blocks and rules
    /// without an `id` get one derived from their position, and a rule's branches, conditions and actions
    /// keep the ids of `existing`'s rule with the same id; so the same spec always builds the same design,
    /// and `compile(emit(c), existing: c)` gives back `c`.
    public static func compile(_ spec: JSONValue, existing: SpriteConfiguration?, environment: SpecEnvironment) -> (CompiledSprite?, [SpecDiagnostic]) {
        SpecCompiler(environment: environment).compile(spec, existing: existing)
    }

    /// The spec for a saved sprite, with defaults left out and shorthand used where it reads better.
    /// Commands' `directory` is never written: `files` implies it.
    public static func emit(_ config: SpriteConfiguration, side: SpriteSide, files: [String: String], environment: SpecEnvironment) -> JSONValue {
        SpecEmitter.emit(config, side: side, files: files, environment: environment)
    }

    /// A script-blocks command's output (a JSON list of blocks, or `{"blocks": [...]}`) as board blocks.
    /// Ids derive from each block's position, so redrawing keeps identity. Blocks may name the sprite's
    /// own values; literal data a script prints instead (`{"gauge": 45}`, `{"value": "12 GB"}`,
    /// `{"chart": [3, 5, 2]}`) comes back as extra fixed-text `variables` the blocks refer to, which the
    /// board draws alongside the design's own. `directory` is the sprite's folder.
    ///
    /// Every kind is allowed except `blocks`, `script` and the four premade panels; a block of those is
    /// reported and left out while the rest still draw. At most 200 blocks are read. A relative image path
    /// is resolved against `directory` (else the home folder), where the script ran.
    public static func scriptBlocks(_ output: String, design: SpriteDesign, directory: String?)
        -> (blocks: [BoardBlock], variables: [SpriteVariable], diagnostics: [SpecDiagnostic]) {
        SpecCompiler.scriptBlocks(output, design: design, directory: directory)
    }

    /// Every command a sprite runs: command values, script rows, script blocks, buttons and switches.
    ///
    /// Scheduled commands are listed once per run, as the runtime runs them: values and script blocks with the
    /// same command, every, timeout and folder share one process, so `python3 x.py · every 15s · shared by 4`
    /// is one process every 15 s, not four. Commands that run only on a click follow, marked as such.
    public static func commands(of config: SpriteConfiguration) -> [String] {
        guard let design = config.design else { return [] }
        var order: [CommandSource] = [], users: [CommandSource: Int] = [:], boardOnly: Set<CommandSource> = []
        func add(_ source: CommandSource, boardOnly isBoard: Bool) {
            var key = source.normalized; key.output = .text; key.path = ""; key.background = false
            if users[key] == nil { order.append(key); if isBoard { boardOnly.insert(key) } } else if !isBoard { boardOnly.remove(key) }
            users[key, default: 0] += 1
        }
        for variable in design.variables { if let command = variable.command { add(command, boardOnly: false) } }
        for block in design.board?.root.flattened ?? [] where block.kind == .script || block.kind == .blocks {
            if let command = block.command { add(command, boardOnly: true) }
        }
        func every(_ seconds: Double) -> String {
            let whole = Int(seconds)
            return whole % 3600 == 0 ? "\(whole / 3600)h" : whole % 60 == 0 ? "\(whole / 60)m" : "\(whole)s"
        }
        var result = order.map { key in
            let shared = (users[key] ?? 1) > 1 ? " · shared by \(users[key] ?? 1)" : ""
            return "\(key.command) · every \(every(key.interval))\(boardOnly.contains(key) ? " while the board is open" : "")\(shared)"
        }
        var clicks: [String] = []
        for block in design.board?.root.flattened ?? [] {
            for action in [block.action, block.offAction].compactMap({ $0 }) where action.kind == .runCommand && !clicks.contains(action.value) {
                clicks.append(action.value)
            }
        }
        result += clicks.map { "\($0) · on click" }
        return result
    }
}
