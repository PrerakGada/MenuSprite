import Foundation
import Testing
import AgentProtocol
import SystemMonitoring
@testable import SpriteSpec

// Keys added after the blind trials: colour names that adapt, clickable blocks, action timeouts, line limits,
// natural widths, icons on text, clock times, day-long intervals; and the diagnostics the trials asked for.

/// Compiles, then checks that emit → compile gives the same sprite and emit is stable.
private func roundTrips(_ text: String, file: String = #fileID, line: Int = #line) throws -> (SpriteConfiguration, JSONValue, [SpecDiagnostic]) {
    let environment = testEnvironment()
    let (compiled, diagnostics) = try compile(text)
    let config = try #require(compiled?.config, "\(diagnostics)")
    let spec = SpriteSpecFormat.emit(config, side: .right, files: [:], environment: environment)
    let (again, more) = SpriteSpecFormat.compile(try JSONValue.parse(spec.serialized(pretty: true)), existing: config, environment: environment)
    #expect(more.errors.isEmpty, "\(more)")
    #expect(again?.config == config, "did not read back:\n\(spec.serialized(pretty: true))")
    #expect(SpriteSpecFormat.emit(try #require(again?.config), side: .right, files: [:], environment: environment) == spec)
    return (config, spec, diagnostics)
}

@Test func colourNamesAreStoredAsNamesAndHexAsHex() throws {
    let (config, spec, diagnostics) = try roundTrips(#"""
    {"menusprite": 1, "name": "C", "face": [{"text": "a", "color": "Orange", "id": "a"}, {"text": "b", "color": "#ff9f0a"}, {"text": "c", "color": "grey"}],
     "rules": [{"when": "x == 1", "then": [{"target": "a", "color": "red"}], "else": [{"target": "a", "color": "FF453A"}]}],
     "values": [{"id": "x", "text": "1"}],
     "board": {"blocks": [{"text": "d", "background": "teal", "color": "#123456"}]}}
    """#)
    #expect(diagnostics.isEmpty, "\(diagnostics)")
    let design = try #require(config.design)
    #expect(design.root.children.map(\.style.color) == ["orange", "FF9F0A", "gray"])
    #expect(design.rules[0].branches[0].actions[0].value == "red" && design.rules[0].otherwise[0].value == "FF453A")
    #expect(design.board?.root.children[0].style.background == "teal" && design.board?.root.children[0].style.color == "123456")
    #expect(spec["face"]?[0]?["color"] == "orange" && spec["face"]?[1]?["color"] == "#FF9F0A")
    #expect(spec["rules"]?[0]?["else"]?[0]?["color"] == "#FF453A" && spec["board"]?["blocks"]?[0]?["background"] == "teal")
}

@Test func blocksBesidesButtonsTakeOneClickAction() throws {
    let (config, spec, diagnostics) = try roundTrips(#"""
    {"menusprite": 1, "name": "Clicks", "values": [{"id": "cpu", "reading": "cpu.usage"}],
     "board": {"blocks": [
       {"text": "PR #12", "open": "https://github.com/x/y/pull/12"},
       {"stack": [{"text": "title"}, {"text": "sub"}], "run": "gh pr checkout 12", "timeout": 120},
       {"value": "cpu", "copy": "CPU {cpu}"},
       {"row": [{"text": "a"}], "app": "Activity Monitor"},
       {"card": [{"text": "c"}], "title": "Card", "refresh": true},
       {"image": "https://x.y/a.png", "open": "https://x.y"},
       {"stats": ["cpu"], "run": "true"},
       {"button": "Long", "run": "sleep 100", "timeout": 300},
       {"toggle": "T", "value": "cpu", "on": "a", "off": "b", "timeout": 90}
     ]}}
    """#)
    #expect(diagnostics.isEmpty, "\(diagnostics)")
    let blocks = try #require(config.design?.board?.root.children)
    #expect(blocks.map { $0.action?.kind } == [.openURL, .runCommand, .copyText, .openApp, .refresh, .openURL, .runCommand, .runCommand, .runCommand])
    #expect(blocks[1].action == BoardAction(kind: .runCommand, value: "gh pr checkout 12", timeout: 120))
    #expect(blocks[7].action?.timeout == 300 && blocks[8].action?.timeout == 90 && blocks[8].offAction?.timeout == 90)
    #expect(blocks[0].action?.timeout == nil)
    #expect(spec["board"]?["blocks"]?[1]?["timeout"] == 120 && spec["board"]?["blocks"]?[0]?["open"] == "https://github.com/x/y/pull/12")
    #expect(SpriteSpecFormat.commands(of: config).contains("gh pr checkout 12 · on click"))
}

@Test func clickActionsAreCheckedLikeAButtons() throws {
    let (compiled, diagnostics) = try compile(#"""
    {"menusprite": 1, "name": "Clicks", "values": [{"id": "cpu", "reading": "cpu.usage"}],
     "board": {"blocks": [
       {"text": "two", "open": "https://x", "run": "y"},
       {"gauge": "cpu", "open": "https://x", "timeout": 5},
       {"text": "t", "timeout": 5},
       {"text": "t", "open": "https://x", "timeout": 5},
       {"button": "b", "run": "x", "timeout": 900}
     ]}}
    """#)
    #expect(compiled == nil)
    #expect(diagnostics.at("board.blocks[0]").first?.message.contains("run and open") == true)
    #expect(diagnostics.at("board.blocks[1].open").first?.severity == .warning && diagnostics.at("board.blocks[1].timeout").first?.severity == .warning)
    #expect(diagnostics.at("board.blocks[2].timeout").first?.message.contains("runs none") == true)
    #expect(diagnostics.at("board.blocks[3].timeout").first?.message.contains("finish at once") == true)
    #expect(diagnostics.at("board.blocks[4].timeout").first?.message.contains("became 600") == true)
    #expect(diagnostics.errors.count == 1)
}

@Test func linesTruncateFitAndTextIcons() throws {
    let (config, spec, diagnostics) = try roundTrips(#"""
    {"menusprite": 1, "name": "Rows", "values": [{"id": "cpu", "reading": "cpu.usage"}],
     "board": {"blocks": [
       {"row": [{"text": "engaze-20db1e4e-c8c6d324-database-1", "lines": 1, "truncate": "middle", "icon": "shippingbox.fill"},
                {"value": "cpu", "fit": true, "lines": 2},
                {"button": "Stop", "run": "x", "lines": 1, "truncate": "head", "fit": true}]}
     ]}}
    """#)
    #expect(diagnostics.isEmpty, "\(diagnostics)")
    let row = try #require(config.design?.board?.root.children.first?.children)
    #expect(row[0].style.lines == 1 && row[0].style.truncate == .middle && row[0].symbol == "shippingbox.fill" && !row[0].style.fit)
    #expect(row[1].style.fit && row[1].style.lines == 2 && row[1].style.truncate == .tail)
    #expect(row[2].style.truncate == .head && row[2].style.fit)
    #expect(spec["board"]?["blocks"]?[0]?["row"]?[0]?["truncate"] == "middle" && spec["board"]?["blocks"]?[0]?["row"]?[1]?["fit"] == true)

    let (_, warnings) = try compile(#"""
    {"menusprite": 1, "name": "Rows", "values": [{"id": "cpu", "reading": "cpu.usage"}],
     "board": {"fit": true, "blocks": [{"text": "a", "fit": true}, {"text": "b", "truncate": "middle"}, {"chart": "cpu", "lines": 1},
                                       {"text": "c", "lines": 1.5}, {"text": "d", "truncate": "start"}, {"text": "e", "icon": "bogus.x"}]}}
    """#)
    #expect(warnings.at("board.fit").first?.severity == .warning)
    #expect(warnings.at("board.blocks[0].fit").first?.message.contains("in a stack") == true)
    #expect(warnings.at("board.blocks[1].truncate").first?.hint == "add \"lines\": 1")
    #expect(warnings.at("board.blocks[2].lines").first?.message.contains("button, text and value") == true)
    #expect(warnings.at("board.blocks[3].lines").first?.message.contains("became 2") == true)
    #expect(warnings.at("board.blocks[4].truncate").first?.severity == .error)
    #expect(warnings.at("board.blocks[5].icon").first?.severity == .warning)
}

@Test func clockIsForDurations() throws {
    let (config, spec, diagnostics) = try roundTrips(#"""
    {"menusprite": 1, "name": "Reset", "values": [{"id": "reset", "reading": "ai.claude.sessionReset", "clock": true}, {"id": "up", "reading": "system.uptime"}],
     "face": "{reset} {up}"}
    """#)
    #expect(diagnostics.isEmpty, "\(diagnostics)")
    #expect(config.design?.variable("reset")?.format.clock == true && config.design?.variable("up")?.format.clock == false)
    #expect(spec["values"]?[0]?["clock"] == true && spec["values"]?[1]?["clock"] == nil)

    let (_, warnings) = try compile(#"""
    {"menusprite": 1, "name": "Reset", "values": [{"id": "cpu", "reading": "cpu.usage", "clock": true}, {"id": "n", "command": "echo 5", "clock": true}],
     "face": "{cpu} {n}"}
    """#)
    #expect(warnings.at("values[0].clock").first?.message.contains("percent") == true)
    // A command's number counts as seconds from its run, so clock is fine there.
    #expect(warnings.at("values[1].clock").isEmpty)
}

@Test func commandsRunAsRarelyAsOnceADay() throws {
    for every in [#""1d""#, #""24h""#, "86400", #""1 day""#] {
        let (compiled, diagnostics) = try compile(#"{"menusprite": 1, "name": "D", "values": [{"id": "n", "command": "brew update", "every": \#(every)}], "board": {"blocks": [{"script": "x", "every": \#(every)}]}}"#)
        #expect(diagnostics.isEmpty, "\(every): \(diagnostics)")
        #expect(compiled?.config.design?.variable("n")?.command?.interval == 86400 && compiled?.config.design?.board?.root.children[0].command?.interval == 86400)
    }
    let (_, warnings) = try compile(#"{"menusprite": 1, "name": "D", "values": [{"id": "n", "command": "x", "every": "2d"}]}"#)
    #expect(warnings.at("values[0].every").first?.message.contains("became 86400") == true)
    #expect(SpecDuration.json(86400) == "1d" && SpecDuration.json(172800) == "2d" && SpecDuration.json(7200) == "2h" && SpecDuration.json(90) == 90)
    #expect(SpecDuration.seconds("1 second") == 1 && SpecDuration.seconds("2 days") == 172800 && SpecDuration.seconds("5 mins") == 300)
}

@Test func commandValuesAndScriptsAlwaysCarryEvery() throws {
    let (config, spec, _) = try roundTrips(#"""
    {"menusprite": 1, "name": "E", "values": [{"id": "n", "command": "echo 1"}, {"id": "cpu", "reading": "cpu.usage"}],
     "face": "{n}", "board": {"blocks": [{"script": "echo hi"}, {"blocks": "python3 b.py", "every": 300}]}}
    """#)
    #expect(config.design?.variable("n")?.command?.interval == 60)
    // The default is written, so an agent reading the sprite back has a key to change.
    #expect(spec["values"]?[0]?["every"] == "1m" && spec["values"]?[1]?["every"] == nil)
    #expect(spec["board"]?["blocks"]?[0]?["every"] == "1m" && spec["board"]?["blocks"]?[1]?["every"] == "5m")
}

@Test func trialDiagnostics() throws {
    let (compiled, diagnostics) = try compile(#"""
    {"menusprite": 1, "name": "T", "every": 60,
     "values": [{"id": "n", "command": "echo 1", "parse": "number", "background": true}],
     "face": {"row": [{"column": [{"bar": "n", "id": "bar"}, {"text": "{n}"}]}, {"bar": "n"}], "id": "root"},
     "rules": [{"when": "n > 1", "then": [{"target": "root", "opacity": 0.4}]}],
     "board": {"blocks": [{"chart": "n", "max": 50}, {"gauge": "n", "max": 50}]}}
    """#)
    #expect(compiled != nil && diagnostics.errors.isEmpty, "\(diagnostics)")
    // A top-level every on a sprite of commands does nothing.
    #expect(diagnostics.at("every").first?.message.contains("reads none") == true)
    // A level bar in a column, but not one in a row.
    #expect(diagnostics.at("face.row[0].column[0].bar").first?.hint?.contains("row") == true)
    #expect(diagnostics.at("face.row[1].bar").isEmpty)
    // A chart scales itself; a gauge uses max.
    #expect(diagnostics.at("board.blocks[0].max").first?.severity == .warning && diagnostics.at("board.blocks[1].max").isEmpty)
    // Opacity on a container is drawn, so a rule dimming the whole face is not questioned.
    #expect(!diagnostics.contains { $0.path.hasPrefix("rules") })
    #expect(diagnostics.count == 3, "\(diagnostics)")

    // With a reading, the top-level every is what paces it.
    #expect(try compile(#"{"menusprite": 1, "name": "T", "every": 10, "values": [{"id": "c", "reading": "cpu.usage"}], "face": "{c}"}"#).1.isEmpty)
}

@Test func scriptBlocksTakeTheNewKeys() {
    let design = SpriteDesign(variables: [SpriteVariable(id: "cpu", name: "CPU", source: .reading(metric: "cpu.usage"))])
    let output = #"""
    [{"row": [{"stack": [{"text": "repo-name-that-is-long", "lines": 1, "truncate": "middle", "icon": "folder"},
                         {"text": "main · 3 files", "font": "caption", "color": "gray"}], "open": "https://github.com/x"},
              {"text": "3", "fit": true, "copy": "{cpu}"}]},
     {"button": "Pull", "run": "git pull", "timeout": 120, "lines": 1},
     {"toggle": "T", "value": true, "on": "a", "off": "b", "timeout": 20},
     {"text": "x", "open": "a", "app": "b"},
     {"stack": [], "fit": true}]
    """#
    let result = SpriteSpecFormat.scriptBlocks(output, design: design, directory: nil)
    let blocks = result.blocks
    let row = blocks[0].children
    #expect(row[0].action == BoardAction(kind: .openURL, value: "https://github.com/x"))
    #expect(row[0].children[0].style.lines == 1 && row[0].children[0].style.truncate == .middle && row[0].children[0].symbol == "folder")
    #expect(row[0].children[1].style.color == "gray")
    #expect(row[1].style.fit && row[1].action?.kind == .copyText)
    #expect(blocks[1].action?.timeout == 120 && blocks[1].style.lines == 1)
    #expect(blocks[2].action?.timeout == 20 && blocks[2].offAction?.timeout == 20)
    // Two actions are refused (the block still draws, without one); a fit at the top of what a script prints is
    // not questioned, since its parent is not known.
    #expect(result.diagnostics.map(\.path) == ["[3]"] && result.diagnostics[0].severity == .error, "\(result.diagnostics)")
    #expect(blocks.count == 5 && blocks[3].action == nil)
}

@Test func iconLevelBindsAValueAndRoundTrips() throws {
    let (config, spec, diagnostics) = try roundTrips(#"""
    {"menusprite": 1, "name": "Wi-Fi", "face": [{"icon": "wifi", "level": "signal", "id": "bars"}, {"icon": "menusprite.bluetooth"}],
     "values": [{"id": "signal", "reading": "wifi.signal"}]}
    """#)
    #expect(diagnostics.isEmpty, "\(diagnostics)")
    let design = try #require(config.design)
    #expect(design.root.children[0].variable == "signal")
    #expect(design.displayedReadingIDs == ["wifi.signal"])
    #expect(spec["face"]?[0]?["level"] == "signal")
}

@Test func levelOnANonIconIsFlagged() throws {
    let (_, diagnostics) = try compile(#"""
    {"menusprite": 1, "name": "X", "face": [{"text": "{signal}", "level": "signal"}], "values": [{"id": "signal", "reading": "wifi.signal"}]}
    """#)
    #expect(diagnostics.contains { $0.message.contains("Only an icon takes a level") })
}
