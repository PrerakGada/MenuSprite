import Foundation
import Testing
import AgentProtocol
import SystemMonitoring
@testable import SpriteSpec

private let design = SpriteDesign(variables: [
    SpriteVariable(id: "cpu", name: "CPU", source: .reading(metric: "cpu.usage")),
    SpriteVariable(id: "prs", name: "PRs", source: .command(CommandSource(command: "gh pr list | wc -l", output: .number)))
])

@Test func scriptBlocksReadAListOrAWrappedList() {
    let list = SpriteSpecFormat.scriptBlocks(#"[{"text": "Hello {cpu}", "font": "headline"}, {"divider": true}, "plain line"]"#,
                                             design: design, directory: nil)
    #expect(list.diagnostics.isEmpty, "\(list.diagnostics)")
    #expect(list.blocks.map(\.id) == ["s.0", "s.1", "s.2"])
    #expect(list.blocks[0].segments == [.literal("Hello "), .value("cpu")] && list.blocks[0].style.textStyle == .headline)
    #expect(list.blocks[2].kind == .text && list.blocks[2].segments == [.literal("plain line")])
    #expect(list.variables.isEmpty)

    let wrapped = SpriteSpecFormat.scriptBlocks(#"{"blocks": [{"card": [{"text": "a"}, {"value": "prs", "caption": "Open"}], "title": "PRs"}], "version": 2}"#,
                                                design: design, directory: nil)
    #expect(wrapped.blocks.count == 1 && wrapped.blocks[0].children.map(\.id) == ["s.0.0", "s.0.1"])
    #expect(wrapped.blocks[0].children[1].variable == "prs")
    #expect(wrapped.diagnostics.map(\.path) == ["version"] && wrapped.diagnostics[0].severity == .warning)
    // Redrawing the same output gives the same blocks.
    let again = SpriteSpecFormat.scriptBlocks(#"{"blocks": [{"card": [{"text": "a"}, {"value": "prs", "caption": "Open"}], "title": "PRs"}]}"#,
                                              design: design, directory: nil)
    #expect(again.blocks == wrapped.blocks)
}

@Test func literalDataBecomesFixedValues() throws {
    let output = #"""
    [{"gauge": 45, "max": 50, "caption": "Disk"},
     {"gauge": "cpu"},
     {"gauge": "12.5"},
     {"value": "12 GB", "caption": "Free"},
     {"value": 7},
     {"chart": [3, 5, 2.5]},
     {"stats": [{"name": "Open", "value": 12}, "cpu", {"name": "State", "value": "ok"}]},
     {"toggle": "Wi-Fi", "value": true, "on": "networksetup -setairportpower en0 on", "off": "networksetup -setairportpower en0 off"},
     {"button": "Close", "run": "gh pr close 1"}]
    """#
    let result = SpriteSpecFormat.scriptBlocks(output, design: design, directory: "/tmp/sprite")
    #expect(result.diagnostics.isEmpty, "\(result.diagnostics)")
    let blocks = result.blocks
    #expect(blocks[0].variable == "s.0" && blocks[0].style.maximum == 50 && blocks[0].segments == [.literal("Disk")])
    #expect(blocks[1].variable == "cpu")
    #expect(blocks[2].variable == "s.2" && blocks[3].variable == "s.3" && blocks[4].variable == "s.4" && blocks[5].variable == "s.5")
    #expect(blocks[6].variables == ["s.6.0", "cpu", "s.6.2"])
    #expect(blocks[7].variable == "s.7" && blocks[7].action?.value.hasSuffix(" on") == true && blocks[7].offAction?.kind == .runCommand)
    #expect(blocks[8].action == BoardAction(kind: .runCommand, value: "gh pr close 1"))
    let constants = Dictionary(uniqueKeysWithValues: result.variables.map { ($0.id, $0) })
    func text(_ id: String) -> String? { if case .constant(let text)? = constants[id]?.source { text } else { nil } }
    #expect(text("s.0") == "45" && text("s.2") == "12.5" && text("s.3") == "12 GB" && text("s.4") == "7")
    #expect(text("s.5") == "3,5,2.5" && text("s.6.0") == "12" && constants["s.6.0"]?.name == "Open" && text("s.6.2") == "ok")
    #expect(text("s.7") == "true")
    // Fixed values never take a design value's id.
    #expect(Set(result.variables.map(\.id)).isDisjoint(with: design.variables.map(\.id)))
}

@Test func scriptsCannotPrintCommandsOrPanels() {
    let result = SpriteSpecFormat.scriptBlocks(#"[{"processes": "cpu"}, {"text": "kept"}, {"row": [{"script": "rm -rf ~"}, {"blocks": "x"}, {"energy": true}]}]"#,
                                               design: design, directory: nil)
    #expect(result.blocks.map(\.id) == ["s.1", "s.2"])
    #expect(result.blocks[1].children.isEmpty)
    #expect(result.diagnostics.map(\.path) == ["[0].processes", "[2].row[0].script", "[2].row[1].blocks", "[2].row[2].energy"])
    #expect(result.diagnostics.allSatisfy { $0.severity == .error })
}

@Test func scriptOutputErrorsSayWhere() {
    let broken = SpriteSpecFormat.scriptBlocks("[\n  {\"text\": \"a\",}\n]", design: design, directory: nil)
    #expect(broken.blocks.isEmpty)
    #expect(broken.diagnostics.first?.message.contains("line 2, column") == true)
    #expect(SpriteSpecFormat.scriptBlocks(#"{"text": "a"}"#, design: design, directory: nil).diagnostics.first?.severity == .error)
    let bad = SpriteSpecFormat.scriptBlocks(#"[{"gauge": "lots"}, {"chart": [1, "x"]}, {"output": "free text"}, {"text": "{nope} {cpu}"}]"#,
                                            design: design, directory: nil)
    #expect(bad.diagnostics.map(\.path) == ["[0].gauge", "[1].chart", "[2].output", "[3].text"])
    #expect(bad.diagnostics.last?.severity == .warning)
    #expect(bad.blocks.last?.segments == [.literal("{nope}"), .literal(" "), .value("cpu")])
}

@Test func scriptBlocksAreCappedAndImagesResolved() {
    let many = "[" + Array(repeating: #"{"text": "x"}"#, count: 250).joined(separator: ",") + "]"
    let result = SpriteSpecFormat.scriptBlocks(many, design: design, directory: nil)
    #expect(result.blocks.count == 200)
    #expect(result.diagnostics.count == 1 && result.diagnostics[0].path == "[200]")
    let images = SpriteSpecFormat.scriptBlocks(#"[{"image": "out.png"}, {"image": "/abs.png"}, {"image": "https://x.y/a.png"}, {"image": "~/a.png"}]"#,
                                               design: design, directory: "/tmp/sprite")
    #expect(images.blocks.map(\.source) == ["/tmp/sprite/out.png", "/abs.png", "https://x.y/a.png", "~/a.png"])
}

@Test func schemaIsJSON() throws {
    let schema = try JSONValue.parse(SpecSchema.json)
    #expect(schema["$schema"] == "https://json-schema.org/draft/2020-12/schema")
    let defs = try #require(schema["$defs"])
    for name in ["value", "node", "rule", "action", "board", "block", "color", "template"] { #expect(defs[name] != nil, "\(name)") }
    #expect(schema["properties"]?.keys == SpecCompiler.topKeys)
    // One alternative per block kind, besides the bare string.
    #expect(defs["block"]?["oneOf"]?.items?.count == SpecCompiler.blockKinds.count + 1)
    #expect(defs["node"]?["oneOf"]?.items?.count == SpecCompiler.nodeKinds.count + 3)
    #expect(defs["blockProps"]?["properties"]?.keys == SpecCompiler.blockProperties)
    #expect(defs["nodeProps"]?["properties"]?.keys == SpecCompiler.nodeProperties)
    #expect(defs["value"]?["properties"]?.keys == SpecCompiler.valueKeys)
}
