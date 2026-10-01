import Foundation
import Testing
import AgentProtocol
import SystemMonitoring
@testable import SpriteSpec

@Test func specIdentityReadsIDAndName() throws {
    let spec = try JSONValue.parse(#"{"menusprite":1,"name":"PRs"}"#)
    #expect(SpriteSpecFormat.identity(of: spec).name == "PRs")
}

/// (a) Every gallery template reads back as a spec that rebuilds it exactly, and (b) that spec is stable.
@Test func everyTemplateRoundTripsExactly() throws {
    let environment = testEnvironment()
    for template in SpriteTemplates.all {
        let original = template.make(metric: metric)
        let spec = SpriteSpecFormat.emit(original, side: .right, files: [:], environment: environment)
        // Through text too, as the CLI and MCP carry it.
        let reread = try JSONValue.parse(spec.serialized(pretty: true))
        #expect(reread == spec, "\(template.id): pretty JSON did not read back")
        let (compiled, diagnostics) = SpriteSpecFormat.compile(reread, existing: original, environment: environment)
        #expect(diagnostics.errors.isEmpty, "\(template.id): \(diagnostics)")
        guard let compiled else { Issue.record("\(template.id) did not compile"); continue }
        #expect(compiled.config.design == original.design, "\(template.id): design changed\n\(spec.serialized(pretty: true))")
        #expect(compiled.config == original, "\(template.id): settings changed")
        #expect(compiled.files == nil && compiled.side == nil)
        #expect(SpriteSpecFormat.emit(compiled.config, side: .right, files: [:], environment: environment) == spec, "\(template.id): emit not stable")

        // Without the sprite it replaces (a spec copied to another Mac), only the ids a spec never carries
        // (a rule's branches, conditions and actions) are new.
        let (fresh, _) = SpriteSpecFormat.compile(spec, existing: nil, environment: environment)
        let design = try #require(fresh?.config.design)
        #expect(design.root == original.design?.root, "\(template.id)")
        #expect(design.variables == original.design?.variables, "\(template.id)")
        #expect(shape(design.rules) == shape(original.design?.rules ?? []), "\(template.id)")
        #expect(fresh?.config.id == original.id && fresh?.config.interval == original.interval && fresh?.config.symbol == original.symbol)
    }
}

@Test func templateSpecsReadWell() throws {
    let environment = testEnvironment()
    let ram = try #require(SpriteTemplates.template("memory.pressure")).make(metric: metric)
    let spec = SpriteSpecFormat.emit(ram, side: .right, files: [:], environment: environment)
    #expect(spec.keys.prefix(4) == ["menusprite", "id", "name", "icon"])
    #expect(spec["values"]?[1] == .object([JSONMember("id", "pressure"), JSONMember("reading", "memory.pressure")]))
    let when = spec["rules"]?[0]?["cases"]?[0]?["when"]?.string
    #expect(when == "pressure == 'Critical'")
    // A stored hex reads back as hex: writing it as "red" would turn the fixed colour into the adaptive one.
    #expect(spec["rules"]?[0]?["cases"]?[0]?["then"]?[0]?["color"] == "#FF453A")
    // The pace rules write their operands quoted and their colours as hex where no name matches.
    let claude = try #require(SpriteTemplates.template("ai.claudeSession")).make(metric: metric)
    let text = SpriteSpecFormat.emit(claude, side: .right, files: [:], environment: environment).serialized()
    #expect(text.contains(#"claude.pace == 'on track'"#) && text.contains(##""#34C759""##) && text.contains("claude is missing"))
}

@Test func showcaseCompilesCleanAndRoundTrips() throws {
    let environment = testEnvironment()
    let (first, diagnostics) = try compile(showcaseSpec)
    #expect(diagnostics.isEmpty, "\(diagnostics)")
    let compiled = try #require(first)
    let design = try #require(compiled.config.design)
    #expect(compiled.side == .left)
    #expect(compiled.files?.keys.sorted() == ["notes.txt", "prs.py"])
    #expect(compiled.config.name == "Showcase" && compiled.config.symbol == "sparkles" && !compiled.config.showInMenuBar)
    #expect(compiled.config.interval == 5)

    // What the spec says, as the studio's model.
    let directory = "/tmp/menusprite-tests/\(compiled.config.id.uuidString)"
    let prs = try #require(design.variable("prs")?.command)
    #expect(prs == CommandSource(command: "python3 prs.py", interval: 300, timeout: 20, output: .number, directory: directory, background: true))
    #expect(design.variable("prs")?.format.suffix == " open")
    #expect(design.variable("cpu")?.format.decimals == 1 && design.variable("cpu")?.format.showUnit == false)
    #expect(design.variable("temp")?.name == "CPU temperature · hottest mapped sensor")
    #expect(design.variable("ts")?.command?.output == .json && design.variable("ts")?.command?.path == "BackendState")
    #expect(design.root.id == "f" && design.root.style.padding == 4 && design.root.style.color == "auto")
    #expect(design.node("flame")?.style.color == "orange")
    #expect(design.node("pct")?.segments == [.value("cpu"), .literal("%")])
    let column = design.root.children[1]
    #expect(column.kind == .column && column.id == "f-1" && column.style.gap == 2 && column.style.justify == .even && column.name == "Reading")
    #expect(design.root.children[4].kind == .row && design.root.children[4].children[0].id == "f-4-0")
    #expect(design.node("label")?.style.shrinkToFit == true)

    let hot = design.rules[0]
    #expect(hot.id == "r0" && hot.branches.count == 1 && hot.branches[0].match == .all)
    #expect(hot.branches[0].conditions.map(\.comparison) == [.above, .atLeast])
    #expect(hot.branches[0].actions.map(\.kind) == [.color, .text] && hot.branches[0].actions.map(\.id) == ["r0-c0-a0", "r0-c0-a1"])
    #expect(hot.otherwise.first?.value == "inherit" && hot.otherwise.first?.id == "r0-e0")
    let pace = design.rules[1]
    #expect(pace.id == "pace" && pace.branches[1].match == .any && pace.branches[1].conditions[0].aspect == .pace)
    #expect(pace.branches[1].conditions[0].operand == "on track" && pace.branches[1].conditions[1].comparison == .isMissing)
    #expect(pace.branches[1].actions.map(\.value) == ["green", "0.5"])
    #expect(design.rules[2].enabled == false && design.rules[2].branches[0].actions.map(\.kind) == [.show, .symbol, .hide])
    #expect(design.rules[5].branches[0].match == .any)

    let board = try #require(design.board)
    #expect(board.width == 420 && !board.showHeader && board.root.id == "main" && board.root.style.spacing == 12)
    let blocks = board.root.children
    #expect(blocks[0].id == "status" && blocks[0].style.textStyle == .title && blocks[0].style.align == .center)
    #expect(blocks[1].children[0].id == "b-1-0" && blocks[1].children[0].detail == [.value("prs"), .literal(" of "), .value("stars")])
    #expect(blocks[1].children[1].style.maximum == 400 && blocks[1].children[1].segments == [.literal("CPU")])
    #expect(blocks[2].kind == .card && blocks[2].segments == [.literal("Details")] && blocks[2].style.background == "1C1C1E")
    #expect(blocks[2].children[4].kind == .spacer && blocks[2].children[4].style.spacing == 16)
    #expect(blocks[3].children.map { $0.action?.kind } == [.openURL, .runCommand, .openApp, .copyText, .refresh])
    let toggle = blocks[4]
    #expect(toggle.kind == .toggle && toggle.variable == "ts" && toggle.action == BoardAction(kind: .runCommand, value: "tailscale up")
            && toggle.offAction == BoardAction(kind: .runCommand, value: "tailscale down") && toggle.symbol == "network")
    #expect(blocks[5].command == CommandSource(command: "echo 'hi | sfimage=hand.wave'", interval: 30, timeout: 5, directory: directory))
    #expect(blocks[6].kind == .blocks && blocks[6].command?.interval == 60 && blocks[6].command?.timeout == 30 && blocks[6].command?.directory == directory)
    #expect(blocks[7].source == "chart.png" && blocks[7].style.height == 100)
    #expect(blocks[8].style.processKind == .cpu && blocks[8].style.limit == 6)
    #expect(blocks[9].kind == .energy && blocks[9].style.height == 500 && blocks[10].style.height == 520)
    #expect(blocks[11].name == "All readings" && blocks[12].name == "Footer")
    #expect(SpriteSpecFormat.commands(of: compiled.config).contains("tailscale down · on click"))

    // (a) emit then compile gives the same sprite; (b) emit is stable; through text as well.
    let spec = SpriteSpecFormat.emit(compiled.config, side: .left, files: compiled.files ?? [:], environment: environment)
    #expect(spec["side"] == "left" && spec["files"]?.keys == ["notes.txt", "prs.py"])
    let text = spec.serialized(pretty: true)
    #expect(!text.contains("directory") && !text.contains("\"r0\"") && !text.contains("\"f-1\""))
    let (again, againDiagnostics) = SpriteSpecFormat.compile(try JSONValue.parse(text), existing: compiled.config, environment: environment)
    #expect(againDiagnostics.isEmpty, "\(againDiagnostics)")
    #expect(again?.config == compiled.config)
    #expect(again?.files == compiled.files)
    #expect(SpriteSpecFormat.emit(try #require(again).config, side: .left, files: again?.files ?? [:], environment: environment) == spec)

    // (c) The same spec applied again (now replacing the sprite it made) builds the same design.
    let (applied, _) = try compile(showcaseSpec, existing: compiled.config)
    #expect(applied?.config.design == compiled.config.design)
    // And with no sprite to replace, the position-derived ids come out the same every time.
    let (other, _) = try compile(showcaseSpec)
    var otherDesign = try #require(other?.config.design)
    CommandRewrite.directories(in: &otherDesign, to: directory)
    #expect(otherDesign == design)
}

/// A design the studio made has random ids everywhere; the spec carries the ones that matter and the
/// sprite it replaces supplies the rest.
@Test func studioMadeDesignRoundTripsWithItsIDs() throws {
    let environment = testEnvironment()
    let (first, _) = try compile(showcaseSpec)
    var config = try #require(first?.config)
    config.design = reidentified(try #require(config.design))
    let spec = SpriteSpecFormat.emit(config, side: .right, files: ["prs.py": "x"], environment: environment)
    let (again, diagnostics) = SpriteSpecFormat.compile(spec, existing: config, environment: environment)
    #expect(diagnostics.isEmpty, "\(diagnostics)")
    #expect(again?.config.design == config.design)
    #expect(SpriteSpecFormat.emit(try #require(again).config, side: .right, files: ["prs.py": "x"], environment: environment) == spec)
}

@Test func emitUsesShorthandWhereItReadsBack() throws {
    let environment = testEnvironment()
    let (compiled, diagnostics) = try compile(#"""
    {"menusprite": 1, "name": "Short", "values": [{"id": "cpu", "reading": "cpu.usage"}],
     "face": ["{cpu}", {"text": "%", "size": 9}, ["a", "b"]]}
    """#)
    #expect(diagnostics.isEmpty)
    let spec = SpriteSpecFormat.emit(try #require(compiled).config, side: .right, files: [:], environment: environment)
    #expect(spec["face"] == .array(["{cpu}", .object([JSONMember("text", "%"), JSONMember("size", 9)]), ["a", "b"]]))
    #expect(spec["values"] == [.object([JSONMember("id", "cpu"), JSONMember("reading", "cpu.usage")])])
    #expect(spec["every"] == nil && spec["enabled"] == nil && spec["board"] == nil && spec["rules"] == nil)

    // A face that is the icon alone is left out, and an omitted face is the icon alone.
    let (plain, _) = try compile(#"{"menusprite": 1, "name": "Plain", "icon": "leaf"}"#)
    let design = try #require(plain?.config.design)
    #expect(design.root.children.map(\.symbol) == ["leaf"] && design.root.style.padding == 3 && design.board == nil)
    #expect(SpriteSpecFormat.emit(try #require(plain).config, side: .right, files: [:], environment: environment)["face"] == nil)

    // Literal braces that would read as a value come back in the exact list form.
    var config = try #require(compiled?.config)
    config.design?.root.children[0].segments = [.literal("{cpu}"), .value("cpu")]
    let tricky = SpriteSpecFormat.emit(config, side: .right, files: [:], environment: environment)
    #expect(tricky["face"]?[0]?["text"] == .array(["{cpu}", .object([JSONMember("value", "cpu")])]))
    #expect(SpriteSpecFormat.compile(tricky, existing: config, environment: environment).0?.config.design == config.design)
}

@Test func ruleTargetsAreWrittenOutSoMovingAPieceKeepsThem() throws {
    let environment = testEnvironment()
    let (compiled, _) = try compile(#"""
    {"menusprite": 1, "name": "T", "values": [{"id": "cpu", "reading": "cpu.usage"}],
     "face": ["CPU", "{cpu}"],
     "rules": [{"when": "cpu > 50", "then": [{"target": "f-1", "color": "red"}]}]}
    """#)
    let spec = SpriteSpecFormat.emit(try #require(compiled).config, side: .right, files: [:], environment: environment)
    // The targeted text carries its id even though it equals the derived one.
    #expect(spec["face"]?[1] == .object([JSONMember("text", "{cpu}"), JSONMember("id", "f-1")]))
    // An agent puts a piece in front: the rule still colours the value, and the new piece gets a fresh id.
    var edited = spec
    edited.set("face", .array([.string("!")] + (spec["face"]?.items ?? [])))
    let (moved, diagnostics) = SpriteSpecFormat.compile(edited, existing: compiled?.config, environment: environment)
    #expect(diagnostics.isEmpty, "\(diagnostics)")
    let design = try #require(moved?.config.design)
    #expect(design.node("f-1")?.segments == [.value("cpu")])
    #expect(design.root.children.map(\.id) == ["f-0", "f-1_2", "f-1"])
}

@Test func filesDecideWhereCommandsRun() throws {
    let spec = #"{"menusprite": 1, "name": "F", "values": [{"id": "n", "command": "./n.sh", "parse": "number"}], "face": "{n}"%@}"#
    func directory(_ files: String, hasFiles: Bool) throws -> (String?, [String: String]?) {
        let (compiled, diagnostics) = try compile(spec.replacingOccurrences(of: "%@", with: files), environment: testEnvironment(hasFiles: hasFiles))
        #expect(diagnostics.errors.isEmpty, "\(diagnostics)")
        return (compiled?.config.design?.variable("n")?.command?.directory, compiled?.files)
    }
    let (withFiles, files) = try directory(##", "files": {"n.sh": "#!/bin/sh\necho 4"}"##, hasFiles: false)
    #expect(withFiles?.hasPrefix("/tmp/menusprite-tests/") == true && files == ["n.sh": "#!/bin/sh\necho 4"])
    let (kept, keptFiles) = try directory("", hasFiles: true)
    #expect(kept != nil && keptFiles == nil)
    let (removed, removedFiles) = try directory(#", "files": {}"#, hasFiles: true)
    #expect(removed == nil && removedFiles == [:])
    let (none, noFiles) = try directory("", hasFiles: false)
    #expect(none == nil && noFiles == nil)
}

@Test func replacingASpriteKeepsWhatTheSpecDoesNotControl() throws {
    var existing = try #require(SpriteTemplates.template("cpu.stacked")).make(metric: metric)
    existing.fontSize = 15
    let (compiled, diagnostics) = try compile(#"{"menusprite": 1, "name": "Mine", "icon": "cpu", "every": 3, "enabled": false}"#, existing: existing)
    #expect(diagnostics.at("every").first?.severity == .warning)
    let config = try #require(compiled?.config)
    #expect(config.id == existing.id && config.templateID == "cpu.stacked" && config.fontSize == 15 && config.layout == existing.layout)
    #expect(config.name == "Mine" && config.symbol == "cpu" && config.interval == 2 && !config.enabled)
    #expect(config.metricIDs.isEmpty)
}

/// Test-only: the folder commands run in depends on the sprite's id, which differs between two new sprites.
enum CommandRewrite {
    static func directories(in design: inout SpriteDesign, to directory: String) {
        SpecCompiler.setDirectory(directory, in: &design)
    }
}
