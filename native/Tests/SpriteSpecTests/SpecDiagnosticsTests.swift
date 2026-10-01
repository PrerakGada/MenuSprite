import Foundation
import Testing
import AgentProtocol
import SystemMonitoring
@testable import SpriteSpec

@Test func unknownKeysWarnWithTheClosestKey() throws {
    let (compiled, diagnostics) = try compile(#"""
    {"menusprite": 1, "name": "x", "colour": "red",
     "face": {"text": "a", "colour": "red", "sizee": 12},
     "board": {"blocks": [{"text": "b", "fnot": "title"}], "widht": 300}}
    """#)
    #expect(compiled != nil)
    #expect(diagnostics.errors.isEmpty)
    #expect(diagnostics.at("face.colour").first?.hint == "did you mean color?")
    #expect(diagnostics.at("face.sizee").first?.hint == "did you mean size?")
    #expect(diagnostics.at("board.blocks[0].fnot").first?.hint == "did you mean font?")
    #expect(diagnostics.at("board.widht").first?.hint == "did you mean width?")
    #expect(diagnostics.at("colour").first?.severity == .warning)
}

@Test func badReadingSuggestsTheRealOne() throws {
    let (compiled, diagnostics) = try compile(#"{"menusprite": 1, "name": "x", "values": [{"id": "cpu", "reading": "cpu.usag"}], "face": "{cpu}"}"#)
    #expect(compiled == nil)
    let error = try #require(diagnostics.at("values[0].reading").first)
    #expect(error.severity == .error && error.hint?.contains("cpu.usage") == true)
    // The reference to the value that failed is not reported a second time.
    #expect(diagnostics.errors.count == 1)
}

@Test func duplicateIDsAreErrors() throws {
    let (compiled, diagnostics) = try compile(#"""
    {"menusprite": 1, "name": "x", "face": [{"text": "a", "id": "x"}, {"text": "b", "id": "x"}],
     "board": {"blocks": [{"text": "c", "id": "x"}]},
     "values": [{"id": "v", "text": "1"}, {"id": "v", "text": "2"}],
     "rules": [{"id": "r", "when": "v == 1", "then": []}, {"id": "r", "when": "v == 2", "then": []}]}
    """#)
    #expect(compiled == nil)
    #expect(diagnostics.at("face[1].id").first?.message.contains("face[0]") == true)
    #expect(diagnostics.at("board.blocks[0].id").first?.severity == .error)
    #expect(diagnostics.at("values[1].id").first?.severity == .error)
    #expect(diagnostics.at("rules[1].id").first?.severity == .error)
}

@Test func whenGrammarRefusesMixedJoinsAndExplainsMistakes() throws {
    let base = #"{"menusprite": 1, "name": "x", "values": [{"id": "cpu", "reading": "cpu.usage"}], "face": {"text": "{cpu}", "id": "v"}, "rules": [%@]}"#
    func diagnostics(_ rule: String) throws -> [SpecDiagnostic] { try compile(base.replacingOccurrences(of: "%@", with: rule)).1 }

    let mixed = try diagnostics(#"{"when": "cpu > 1 and cpu < 5 or cpu == 3", "then": [{"target": "v", "color": "red"}]}"#)
    #expect(mixed.at("rules[0].when").first?.message.contains("not both") == true)
    let reading = try diagnostics(#"{"when": "cpu.usage > 5", "then": [{"target": "v", "hide": true}]}"#)
    #expect(reading.at("rules[0].when").first?.hint?.contains("the value cpu reads cpu.usage") == true)
    let word = try diagnostics(#"{"when": "cpu > high", "then": [{"target": "v", "hide": true}]}"#)
    #expect(word.at("rules[0].when").first?.message.contains("compares numbers") == true)
    let quote = try diagnostics(#"{"when": "cpu == 'open", "then": [{"target": "v", "hide": true}]}"#)
    #expect(quote.at("rules[0].when").first?.message.contains("never closed") == true)
    let target = try diagnostics(#"{"cases": [{"when": "cpu > 1", "then": [{"target": "vv", "color": "red"}]}, {"when": "cpu ~ 2"}]}"#)
    #expect(target.at("rules[0].cases[0].then[0].target").first?.hint == "did you mean v?")
    #expect(target.at("rules[0].cases[1].when").first?.severity == .error)
    let both = try diagnostics(#"{"when": "cpu > 1", "then": [], "cases": []}"#)
    #expect(both.at("rules[0]").first?.message.contains("not both") == true)
    let effect = try diagnostics(#"{"when": "cpu > 1", "then": [{"target": "v"}, {"target": "v", "hide": false}]}"#)
    #expect(effect.at("rules[0].then[0]").first?.severity == .error && effect.at("rules[0].then[1].hide").first?.message.contains("show") == true)

    // The grammar itself: bare words, quotes with escapes, aliases.
    let parsed = try SpecWhen.parse(#"a.pace == on track or b is present or c != 'it\'s' or d contains "x y""#)
    #expect(parsed.match == .any)
    #expect(parsed.conditions == [
        .init(variable: "a", aspect: .pace, comparison: .equals, operand: "on track"),
        .init(variable: "b", aspect: .value, comparison: .isPresent, operand: ""),
        .init(variable: "c", aspect: .value, comparison: .notEquals, operand: "it's"),
        .init(variable: "d", aspect: .value, comparison: .contains, operand: "x y")])
    for operand in ["45", "-1.5", "on track", "it's", #"say "hi" it's"#, #"back\slash"#, "a and b", "", "x>y"] {
        let branch = RuleBranch(conditions: [RuleCondition(variable: "v", comparison: .equals, operand: operand)], actions: [])
        #expect(try SpecWhen.parse(SpecWhen.string(branch)).conditions.first?.operand == operand, "\(operand)")
    }
}

@Test func nodesAndBlocksNeedExactlyOneKindKey() throws {
    let (compiled, diagnostics) = try compile(#"""
    {"menusprite": 1, "name": "x",
     "face": {"row": [{"text": "a", "icon": "flame"}, {"txt": "b"}]},
     "board": {"blocks": [{"card": [{"gauge": "nope", "chart": "nope"}]}, {"type": "text"}]}}
    """#)
    #expect(compiled == nil)
    let two = try #require(diagnostics.at("face.row[0]").first)
    #expect(two.message.contains("text") && two.message.contains("icon"))
    #expect(diagnostics.at("face.row[1]").first?.hint?.contains("did you mean text") == true)
    #expect(diagnostics.at("board.blocks[0].card[0]").first?.message.contains("gauge and chart") == true)
    #expect(diagnostics.at("board.blocks[1]").first?.severity == .error)
}

@Test func coloursAreCheckedAndNormalised() throws {
    let (compiled, diagnostics) = try compile(#"""
    {"menusprite": 1, "name": "x", "face": [{"text": "a", "color": "reddish"}, {"text": "b", "color": "#12ab3f"}, {"text": "c", "color": "Teal"}],
     "board": {"blocks": [{"text": "d", "background": "fuchsia"}]}}
    """#)
    #expect(compiled == nil)
    #expect(diagnostics.at("face[0].color").first?.hint == "did you mean red?")
    #expect(diagnostics.at("board.blocks[0].background").first?.severity == .error)
    #expect(diagnostics.errors.count == 2)
    // Names are kept as names (adaptive system colours); hex stays hex and reads back with its "#".
    #expect(SpecColor.parse("#12ab3f", keywords: []) == "12AB3F" && SpecColor.parse("Teal", keywords: []) == "teal")
    #expect(SpecColor.parse("grey", keywords: []) == "gray" && SpecColor.parse("FF453A", keywords: []) == "FF453A")
    #expect(SpecColor.json("FF453A") == "#FF453A" && SpecColor.json("red") == "red" && SpecColor.json("12AB3F") == "#12AB3F")
    #expect(SpecColor.json("inherit") == "inherit")
}

@Test func templatesNameValuesNotReadings() throws {
    let (compiled, diagnostics) = try compile(#"""
    {"menusprite": 1, "name": "x", "values": [{"id": "ram", "reading": "memory.usage"}],
     "face": ["{cpu}", "{cpu.usage}", "{rma}"]}
    """#)
    #expect(compiled == nil)
    #expect(diagnostics.at("face[0]").first?.message == "“{cpu}” names no value.")
    #expect(diagnostics.at("face[1]").first?.hint == "add {\"id\": \"usage\", \"reading\": \"cpu.usage\"} to values and write {usage}")
    #expect(diagnostics.at("face[2]").first?.hint == "did you mean {ram}?")
}

@Test func everyProblemIsReportedInOnePass() throws {
    let (compiled, diagnostics) = try compile(#"""
    {"name": "", "icon": "bogus.symbol", "every": 3,
     "values": [{"id": "1 bad", "reading": "cpu.usage"}, {"id": "a", "command": "x", "every": "10d", "timeout": 0, "parse": "jsn"},
                {"id": "b"}, {"id": "c", "reading": "cpu.usage", "command": "y"}, {"reading": "cpu.usage"}],
     "face": {"row": [{"bar": "zzz"}, {"icon": "bogus.flame"}]},
     "board": {"width": 900, "blocks": [{"button": "Go", "run": "a", "open": "https://x"}, {"processes": "gpu"}, {"chart": "a"}]},
     "files": {"../evil": "x", "ok.sh": 3}}
    """#)
    #expect(compiled == nil)
    let paths = Set(diagnostics.map(\.path))
    for path in ["menusprite", "name", "icon", "every", "values[0].id", "values[1].every", "values[1].timeout", "values[1].parse",
                 "values[2]", "values[3]", "values[4]", "face.row[0].bar", "face.row[1].icon", "board.width", "board.blocks[0]",
                 "board.blocks[1].processes", "board.blocks[2].chart", "files[\"../evil\"]", "files[\"ok.sh\"]"] {
        #expect(paths.contains(path), "no diagnostic at \(path): \(diagnostics)")
    }
    #expect(diagnostics.at("values[1].every").first?.severity == .warning)
    #expect(diagnostics.at("board.width").first?.message.contains("became 560") == true)
    #expect(diagnostics.at("icon").first?.severity == .warning)
}

@Test func misplacedKeysAreNamedForWhatTheyAre() throws {
    let (compiled, diagnostics) = try compile(#"""
    {"menusprite": 1, "name": "x", "values": [{"id": "n", "command": "echo 1", "parse": "number", "unit": false},
                                               {"id": "r", "reading": "cpu.usage", "every": 5}],
     "face": [{"text": "hi", "font": "title"}],
     "board": {"blocks": [{"text": "t", "caption": "c"}, {"stats": ["n"], "title": "T"}, {"script": "echo", "every": 1},
                          {"toggle": "Wi-Fi"}, {"button": "Nothing"}, {"chart": "n"}, {"space": 10, "spacing": 4}]}}
    """#)
    #expect(compiled != nil)
    #expect(diagnostics.errors.isEmpty, "\(diagnostics)")
    #expect(diagnostics.at("values[0].unit").first != nil && diagnostics.at("values[1].every").first != nil)
    #expect(diagnostics.at("face[0].font").first?.message.contains("size and weight") == true)
    #expect(diagnostics.at("board.blocks[0].caption").first != nil)
    #expect(diagnostics.at("board.blocks[1].title").first?.message == "Only a card draws its title.")
    #expect(diagnostics.at("board.blocks[2].every").first?.message.contains("became 2") == true)
    #expect(diagnostics.at("board.blocks[3]").count == 2)
    #expect(diagnostics.at("board.blocks[4]").first?.hint == "add run, open, app, copy or refresh")
    #expect(diagnostics.at("board.blocks[5].chart").first?.hint == "add \"background\": true to the value n")
    #expect(diagnostics.at("board.blocks[6].spacing").first != nil)
    #expect(compiled?.config.design?.board?.root.children[1].segments == [.literal("T")])
}

@Test func versionAndIdentityAreChecked() throws {
    #expect(try compile(#"{"menusprite": 2, "name": "x"}"#).1.at("menusprite").first?.severity == .error)
    #expect(try compile(#"{"menusprite": 1, "name": "x", "id": "github-prs"}"#).1.at("id").first?.severity == .error)
    #expect(try compile(#"[1]"#).1.first?.message.contains("object") == true)
    let long = String(repeating: "n", count: 50)
    let (compiled, diagnostics) = try compile(#"{"menusprite": 1, "name": "\#(long)", "side": "left"}"#)
    #expect(compiled?.config.name.count == 40 && diagnostics.at("name").first?.severity == .warning && compiled?.side == .left)
    let id = UUID()
    #expect(try compile(#"{"menusprite": 1, "name": "x", "id": "\#(id.uuidString)"}"#).0?.config.id == id)
    #expect(SpriteSpecFormat.identity(of: try JSONValue.parse(#"{"id": "\#(id.uuidString)", "name": "PRs"}"#)) == (id, "PRs"))
}

@Test func commonSlipsGetPointedHints() throws {
    let (_, diagnostics) = try compile(#"""
    {"menusprite": 1, "name": "x", "values": ["cpu.usage", {"id": "cpu", "reading": "cpu.usage"}],
     "face": {"text": "{cpu}", "id": "v"},
     "rules": [{"when": "cpu > 80%", "then": [{"target": "v", "color": "red"}]},
               {"when": "cpu > 1 && cpu < 5", "then": [{"target": "v", "color": "red"}]}]}
    """#)
    #expect(diagnostics.at("values[0]").first?.hint == #"{"id": "usage", "reading": "cpu.usage"}"#)
    #expect(diagnostics.at("rules[0].when").first?.hint == "write 80, without the %")
    #expect(diagnostics.at("rules[1].when").isEmpty)
    #expect(try SpecWhen.parse("a > 1 || b < 2").match == .any)
}
