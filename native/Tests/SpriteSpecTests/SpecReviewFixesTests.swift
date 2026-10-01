import Foundation
import Testing
import AgentProtocol
import SystemMonitoring
@testable import SpriteSpec

// What the October 2026 review found in the compiler: nulls read as present, long names that never matched,
// commands cut silently, studio states that could not be read back, case-folded file names, unbounded hints,
// quadratic lookups, a schema narrower than the compiler, and conditions that could never hold.

// MARK: - A null counts as absent

@Test func everyTopLevelNullIsLikeLeavingTheKeyOut() throws {
    let existing = try #require(try compile(#"{"menusprite": 1, "name": "N"}"#).0?.config)
    let (nulls, diagnostics) = try compile(#"""
    {"menusprite": 1, "name": "N", "id": null, "icon": null, "enabled": null, "menuBar": null, "side": null, "every": null,
     "values": null, "face": null, "rules": null, "board": null, "files": null}
    """#, existing: existing)
    #expect(diagnostics.isEmpty, "\(diagnostics)")
    let compiled = try #require(nulls)
    #expect(compiled.config == existing && compiled.side == nil && compiled.files == nil)
}

@Test func boardNullRemovesTheBoard() throws {
    let (first, _) = try compile(showcaseSpec)
    let existing = try #require(first?.config)
    #expect(existing.design?.board != nil)
    let (replaced, diagnostics) = try compile(#"{"menusprite": 1, "name": "Showcase", "board": null}"#, existing: existing)
    #expect(diagnostics.errors.isEmpty, "\(diagnostics)")
    #expect(replaced?.config.design?.board == nil)
}

@Test func nullMembersInsideValuesNodesAndRulesAreAbsent() throws {
    let (compiled, diagnostics) = try compile(#"""
    {"menusprite": 1, "name": "N",
     "values": [{"id": "x", "reading": null, "command": "echo 1", "parse": "number", "name": null}],
     "face": [{"text": "{x}", "icon": null, "id": "t"}, {"bar": null}],
     "rules": [{"cases": [{"when": "x > 1", "then": [{"target": "t", "color": "red", "icon": null}]}], "when": null, "then": null}],
     "board": {"blocks": [{"value": null}, {"text": "a", "value": null}, {"toggle": "S", "value": null, "on": "true"}]}}
    """#)
    #expect(diagnostics.errors.isEmpty, "\(diagnostics)")
    let design = try #require(compiled?.config.design)
    #expect(design.variable("x")?.command?.command == "echo 1")
    #expect(design.root.children.map(\.kind) == [.text, .bar] && design.root.children[1].variable == nil)
    #expect(design.rules[0].branches.count == 1)
    #expect(design.board?.root.children.map(\.kind) == [.value, .text, .toggle])
    // A null member is not reported as an unknown key either.
    #expect(!diagnostics.contains { $0.path.hasSuffix(".icon") || $0.path.hasSuffix(".value") })
}

// MARK: - Long names

@Test func aLongNameIsSavedAndMatchedTheSameWay() throws {
    let long = "This is a very long sprite name that goes past forty characters"
    let spec = try JSONValue.parse(#"{"menusprite": 1, "name": "\#(long)"}"#)
    let (compiled, diagnostics) = SpriteSpecFormat.compile(spec, existing: nil, environment: testEnvironment())
    let name = try #require(compiled?.config.name)
    #expect(name == String(long.prefix(40)) && name.count == 40)
    #expect(diagnostics.at("name").first?.severity == .warning && diagnostics.at("name").first?.message.contains(name) == true)
    // apply looks the sprite up by identity(of:): the same name it was saved under.
    #expect(SpriteSpecFormat.identity(of: spec).name == name)

    // A cut that ends on a space leaves no trailing space, on either side.
    let spaced = String(repeating: "a", count: 39) + " tail"
    let spacedSpec = try JSONValue.parse(#"{"menusprite": 1, "name": "\#(spaced)"}"#)
    let saved = try #require(SpriteSpecFormat.compile(spacedSpec, existing: nil, environment: testEnvironment()).0?.config.name)
    #expect(saved == String(repeating: "a", count: 39))
    #expect(SpriteSpecFormat.identity(of: spacedSpec).name == saved)
    var normalized = try #require(SpriteSpecFormat.compile(spacedSpec, existing: nil, environment: testEnvironment()).0?.config)
    normalized.normalize()
    #expect(normalized.name == saved)
}

// MARK: - Command length

@Test func commandsLongerThanTheRuntimeRunsAreRefused() throws {
    let limit = SpecDefaults.commandLength
    let ok = "echo " + String(repeating: "x", count: limit - 5)
    let long = ok + "y"
    let (fine, fineDiagnostics) = try compile(#"{"menusprite": 1, "name": "N", "values": [{"id": "a", "command": "\#(ok)"}]}"#)
    #expect(fine != nil && fineDiagnostics.isEmpty, "\(fineDiagnostics)")
    let (compiled, diagnostics) = try compile(#"""
    {"menusprite": 1, "name": "N", "values": [{"id": "a", "command": "\#(long)"}],
     "board": {"blocks": [{"script": "\#(long)"}, {"blocks": "\#(long)"}, {"button": "Go", "run": "\#(long)"},
                          {"toggle": "T", "on": "\#(long)", "off": "\#(long)"}, {"text": "row", "run": "\#(long)"}]}}
    """#)
    #expect(compiled == nil)
    for path in ["values[0].command", "board.blocks[0].script", "board.blocks[1].blocks", "board.blocks[2].run",
                 "board.blocks[3].on", "board.blocks[3].off", "board.blocks[4].run"] {
        #expect(diagnostics.at(path).first?.severity == .error, "\(path): \(diagnostics.map(\.path))")
    }
    #expect(diagnostics.at("values[0].command").first?.hint?.contains("files") == true)
    // A script printing a block with such a command is told so too.
    let printed = SpriteSpecFormat.scriptBlocks(#"[{"button": "Go", "run": "\#(long)"}]"#, design: SpriteDesign(), directory: nil)
    #expect(printed.diagnostics.at("[0].run").first?.severity == .error)
}

// MARK: - What the studio saves half made reads back

@Test func studioUnfinishedStatesReadBackExactly() throws {
    let environment = testEnvironment()
    let (base, _) = try compile(#"""
    {"menusprite": 1, "name": "Studio", "values": [{"id": "cpu", "reading": "cpu.usage"}, {"id": "claude", "reading": "ai.claude.session"}],
     "face": {"text": "{cpu}", "id": "v"},
     "rules": [{"when": "cpu > 80", "then": [{"target": "v", "color": "red"}]}],
     "board": {"blocks": [{"text": "x"}]}}
    """#)
    var config = try #require(base?.config)
    var design = try #require(config.design)
    // A new image; a cleared run; a cleared script; a button switched from App to Link with the app's name left
    // in; a copy naming a value since deleted; a switch whose on command was cleared; an else-if just added (no
    // operand yet); a pace compared with "above", which the studio's pickers allow.
    design.board?.root.children += [
        BoardBlock(kind: .image, name: "Image", style: SpecDefaults.blockStyle(.image)),
        BoardBlock(kind: .button, name: "Button", segments: [.literal("Go")], action: BoardAction(kind: .runCommand, value: "")),
        BoardBlock(kind: .script, name: "Script rows", command: CommandSource(command: "", interval: 30)),
        BoardBlock(kind: .button, name: "Button", segments: [.literal("Web")], action: BoardAction(kind: .openURL, value: "Activity Monitor")),
        BoardBlock(kind: .button, name: "Button", segments: [.literal("Copy")], action: BoardAction(kind: .copyText, value: "hello {gone}")),
        BoardBlock(kind: .toggle, name: "Switch", segments: [.literal("S")], variable: "cpu",
                   action: BoardAction(kind: .runCommand, value: ""), offAction: BoardAction(kind: .runCommand, value: "echo off"))
    ]
    design.rules[0].branches.append(RuleBranch(conditions: [RuleCondition(variable: "cpu")], actions: []))
    design.rules[0].branches.append(RuleBranch(conditions: [RuleCondition(variable: "claude", aspect: .pace, comparison: .above, operand: "on track")],
                                               actions: [RuleAction(kind: .color, target: "v", value: "FF453A")]))
    config.design = design
    config.normalize()

    let spec = SpriteSpecFormat.emit(config, side: .right, files: [:], environment: environment)
    let (again, diagnostics) = SpriteSpecFormat.compile(try JSONValue.parse(spec.serialized()), existing: config, environment: environment)
    #expect(diagnostics.errors.isEmpty, "\(diagnostics)")
    #expect(diagnostics.warnings.count >= 8, "\(diagnostics)")
    #expect(again?.config == config)

    // As an agent's first write (no sprite holding that condition), the pace comparison is still refused.
    let (fresh, freshDiagnostics) = SpriteSpecFormat.compile(spec, existing: nil, environment: environment)
    #expect(fresh == nil && freshDiagnostics.errors.count == 1 && freshDiagnostics.errors[0].message.contains("pace"), "\(freshDiagnostics)")
}

// MARK: - Files

@Test func fileNamesThatDifferOnlyByCaseAreRefused() throws {
    let (compiled, diagnostics) = try compile(##"""
    {"menusprite": 1, "name": "F", "files": {"Run.sh": "#!/bin/sh\necho upper", "run.sh": "#!/bin/sh\necho lower", "other.sh": "x"}}
    """##)
    #expect(compiled == nil)
    let error = try #require(diagnostics.errors.first)
    #expect(diagnostics.errors.count == 1 && error.path == #"files["run.sh"]"# && error.message.contains("Run.sh"))
}

// MARK: - Bounded hints and lookups

@Test func distanceCountsEditsAndSwaps() {
    #expect(Fuzzy.distance("widht", "width") == 1 && Fuzzy.distance("fnot", "font") == 1)
    #expect(Fuzzy.distance("kitten", "sitting") == 3 && Fuzzy.distance("", "abc") == 3 && Fuzzy.distance("same", "SAME") == 0)
    #expect(Fuzzy.matches("cpu.usag", in: ["cpu.usage", "cpu.user", "memory.used"]) == ["cpu.usage", "cpu.user"])
    #expect(Fuzzy.matches(String(repeating: "x", count: 65), in: ["x"]).isEmpty)
}

@Test func hugeMistakesStayCheap() throws {
    let start = Date()
    // A whole script pasted into "reading", and a key the size of a file.
    let pasted = String(repeating: "cat /tmp/x | grep y; ", count: 1000)
    let key = String(repeating: "k", count: 100_000)
    let (_, diagnostics) = try compile(#"{"menusprite": 1, "name": "N", "values": [{"id": "a", "reading": "\#(pasted)"}], "\#(key)": 1}"#)
    #expect(diagnostics.at("values[0].reading").first?.severity == .error)
    // Many values, many references to values that do not exist: hints stop after a budget, and no
    // diagnostic lists every value.
    let values = (0..<1000).map { #"{"id": "v\#($0)", "text": "x"}"# }.joined(separator: ",")
    let refs = (0..<1000).map { #""{zz\#($0)}""# }.joined(separator: ",")
    let (_, many) = try compile(#"{"menusprite": 1, "name": "N", "values": [\#(values)], "face": [\#(refs)]}"#)
    #expect(many.errors.count >= 1000)
    #expect(many.allSatisfy { ($0.hint?.count ?? 0) < 300 }, "a hint grew with the spec")
    #expect(many.at("values").first?.message.contains("at most 100 values") == true)
    #expect(Date().timeIntervalSince(start) < 10, "took \(Date().timeIntervalSince(start)) s")
}

@Test func specsHaveSizeLimits() throws {
    let blocks = (0..<501).map { _ in #"{"divider": true}"# }.joined(separator: ",")
    let (compiled, diagnostics) = try compile(#"{"menusprite": 1, "name": "N", "board": {"blocks": [\#(blocks)]}}"#)
    #expect(compiled == nil && diagnostics.at("").first?.message.contains("at most 500") == true)
    let fine = (0..<400).map { _ in #"{"divider": true}"# }.joined(separator: ",")
    #expect(try compile(#"{"menusprite": 1, "name": "N", "face": "x", "board": {"blocks": [\#(fine)]}}"#).0 != nil)
}

// MARK: - The schema accepts what the compiler accepts

@Test func schemaTakesUnicodeValueIDsAndSpaceTrue() throws {
    let schema = try JSONValue.parse(SpecSchema.json)
    let defs = try #require(schema["$defs"])
    func matches(_ def: String, _ text: String) throws -> Bool {
        let pattern = try #require(defs[def]?["pattern"]?.string)
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    for id in ["cpu", "5h", "température", "温度", "a_b"] { #expect(try matches("valueID", id), "\(id)") }
    for id in ["cpu.usage", "a b", "a-b", ""] { #expect(try !matches("valueID", id), "\(id)") }
    for text in ["30s", "5m", "1h", "1d", "2 days", "90"] { #expect(try matches("durationText", text), "\(text)") }
    // Every id the compiler accepts, the schema accepts.
    for id in ["température", "x9", "_"] { #expect(SpecCompiler.isValueID(id)); #expect(try matches("valueID", id)) }
    let space = try #require(defs["block"]?["oneOf"]?.items?.first { $0["required"] == ["space"] })
    #expect(space["properties"]?["space"]?["anyOf"]?.items?.contains(.object([JSONMember("const", true)])) == true)
    #expect(try compile(#"{"menusprite": 1, "name": "T", "values": [{"id": "température", "reading": "cpu.usage"}], "face": "{température}", "board": {"blocks": [{"space": true}]}}"#).1.isEmpty)
}

// MARK: - Conditions that cannot behave as written

@Test func conditionsThatCannotHoldAreNamed() throws {
    let base = #"{"menusprite": 1, "name": "x", "values": [{"id": "bytes", "reading": "network.download"}, {"id": "claude", "reading": "ai.claude.session"}], "face": {"text": "{bytes}", "id": "v"}, "rules": [%@]}"#
    func diagnostics(_ when: String) throws -> [SpecDiagnostic] {
        try compile(base.replacingOccurrences(of: "%@", with: #"{"when": "\#(when)", "then": [{"target": "v", "hide": true}]}"#)).1
    }
    let thousands = try diagnostics("bytes > 1,000")
    #expect(thousands.errors.isEmpty && thousands.at("rules[0].when").first?.hint == "write 1000 for a number in the thousands")
    #expect(try diagnostics("bytes > 0,5").isEmpty)
    let pace = try diagnostics("claude.pace > 5")
    #expect(pace.at("rules[0].when").first?.severity == .error && pace.at("rules[0].when").first?.hint?.contains("on track") == true)
    #expect(try diagnostics("claude.pace == 'over'").isEmpty)
    let empty = try diagnostics("bytes > ''")
    #expect(empty.errors.isEmpty && empty.at("rules[0].when").first?.message.contains("nothing") == true)
}
