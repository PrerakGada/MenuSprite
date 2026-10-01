import Foundation
import Testing
@testable import SystemMonitoring

@Test func boardTidyKeepsStyledAndTargetedContainers() {
    let hi = BoardBlock.text("Hi"), other = BoardBlock.text("Other"), plainChild = BoardBlock.text("Plain")
    var filled = BoardBlock.stack([hi]); filled.id = "box"; filled.style.background = "334455"; filled.style.padding = 8
    var targeted = BoardBlock.stack([BoardBlock.text("T")]); targeted.id = "target"
    var clickable = BoardBlock(kind: .row, children: [BoardBlock.text("C")]); clickable.action = BoardAction(kind: .openURL, value: "https://example.com")
    let plain = BoardBlock(kind: .row, children: [plainChild])
    var design = SpriteDesign(root: .row([DesignNode.text([.literal("x")])]))
    design.board = BoardDesign(root: .stack([filled, targeted, clickable, plain, other]))
    design.rules = [SpriteRule(branches: [RuleBranch(conditions: [], actions: [RuleAction(kind: .hide, target: "target", value: "")])])]
    #expect(design.ruleTargets == ["target"])
    // Deleting an unrelated block folds only the plain one-block row; the filled, targeted and clickable wrappers stay.
    let targets = design.ruleTargets
    let deleted = design.board!.delete(other.id, keeping: targets); #expect(deleted)
    design.prune()
    let ids = design.board!.root.children.map(\.id)
    #expect(ids == ["box", "target", clickable.id, plainChild.id])
    #expect(design.board!.root.find("box")?.style.background == "334455")
    #expect(design.rules[0].branches[0].actions.count == 1)
    // An empty styled container is kept too; an empty plain one goes.
    var board = BoardDesign(root: .stack([BoardBlock(kind: .stack, children: [hi]), filled]))
    board.root.children[0].children = []
    board.root.children[1].children = []
    board.collapse()
    #expect(board.root.children.map(\.id) == ["box"])
}

@Test func commandsFollowTheSpriteFolder() {
    var design = SpriteDesign(root: .row([DesignNode.text([.value("a")])]),
                              variables: [SpriteVariable(id: "a", name: "A", source: .command(CommandSource(command: "echo 1"))),
                                          SpriteVariable(id: "b", name: "B", source: .reading(metric: "cpu.usage"))])
    let rows = BoardBlock(kind: .script, command: CommandSource(command: "python3 rows.py"))
    design.board = BoardDesign(root: .stack([.stack([rows])]))
    design.setCommandDirectory("/tmp/sprite")
    #expect(design.filesDirectory == "/tmp/sprite")
    #expect(design.boardScriptCommands.map(\.directory) == ["/tmp/sprite"])
    #expect(design.variables[1].command == nil)
    design.setCommandDirectory(nil)
    #expect(design.filesDirectory == nil)
}

@Test func scriptLinesReadWeightLengthAndAdaptiveColours() {
    let lines = ScriptLine.parse("""
    Open PRs | font=Helvetica-Bold color=orange
    A very long pull request title that goes on | length=12 tooltip="Full title"
    Quiet | weight=semibold color=Grey
    Code | font=Menlo-Bold color=#ff0000
    Plain | font=SF Pro
    """)
    #expect(lines[0].weight == "bold" && lines[0].color == "orange" && !lines[0].monospaced)
    #expect(lines[1].length == 12 && lines[1].shown == "A very long…" && lines[1].shown.count == 12 && lines[1].tooltip == "Full title")
    #expect(lines[2].weight == "semibold" && lines[2].color == "gray")
    #expect(lines[3].weight == "bold" && lines[3].monospaced && lines[3].color == "FF0000")
    #expect(lines[4].weight == nil && lines[4].length == nil && lines[4].shown == "Plain")
}
