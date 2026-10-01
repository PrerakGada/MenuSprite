import Foundation
import Testing
@testable import SystemMonitoring

@Test func boardBlocksStackRowAndMoveLikeTheMenuBarTree() {
    let a = BoardBlock.text("A"), b = BoardBlock.text("B"), c = BoardBlock.text("C")
    var board = BoardDesign(root: .stack([a, b]))
    // Beside B in a stack: B becomes a row of B and C.
    let wrapped = board.insert(c, at: .right, of: b.id); #expect(wrapped)
    #expect(board.root.children[1].kind == .row && board.root.children[1].children.map(\.id) == [b.id, c.id])
    // Moving C under A puts it back in the stack; the one-block row folds away.
    let moved = board.move(c.id, to: .below, of: a.id); #expect(moved)
    #expect(board.root.children.map(\.id) == [a.id, c.id, b.id])
    // Dropping on an empty card puts the block inside it.
    let card = BoardBlock(kind: .card, name: "Card")
    board.root.children.append(card)
    let inside = board.insert(.text("D"), at: .above, of: card.id); #expect(inside)
    #expect(board.root.find(card.id)?.children.count == 1)
    let cycle = board.move(card.id, to: .below, of: board.root.find(card.id)!.children[0].id); #expect(!cycle)
}

@Test func boardsRoundTripAndPruneWithTheirSprite() throws {
    var design = SpriteDesign(root: .row([DesignNode.text([.value("cpu")])]),
                              variables: [SpriteVariable(id: "cpu", name: "CPU", source: .reading(metric: "cpu.usage")),
                                          SpriteVariable(id: "ram", name: "RAM", source: .reading(metric: "memory.usage"))])
    let value = BoardBlock(kind: .value, variable: "ram")
    let stats = BoardBlock(kind: .stats, variables: ["cpu", "ram"])
    design.board = BoardDesign(root: .stack([value, stats]))
    design.rules = [SpriteRule(branches: [RuleBranch(conditions: [RuleCondition(variable: "ram", comparison: .above, operand: "80")],
                                                     actions: [RuleAction(kind: .color, target: value.id, value: "FF453A")])])]
    let decoded = try JSONDecoder().decode(SpriteDesign.self, from: JSONEncoder().encode(design))
    #expect(decoded == design)
    #expect(design.boardReadingIDs == ["memory.usage", "cpu.usage"])
    // A rule aimed at a board block survives pruning; deleting its value empties the block's binding.
    design.prune()
    #expect(design.rules[0].branches[0].actions.count == 1)
    design.variables.removeAll { $0.id == "ram" }; design.prune()
    #expect(design.board?.root.find(value.id)?.variable == nil)
    #expect(design.board?.root.find(stats.id)?.variables == ["cpu"])
    // A sprite saved before boards decodes with none (its classic panel).
    let legacy = try JSONDecoder().decode(SpriteDesign.self, from: Data(#"{"root":{"kind":"row"},"variables":[],"rules":[]}"#.utf8))
    #expect(legacy.board == nil)
}

@Test func scriptLinesReadSwiftBarStyleParameters() {
    let lines = ScriptLine.parse("""
    Build passing | color=green sfimage=checkmark.circle
    ---
    Open PR | href=https://github.com bash="gh pr view --web" size=12
    --Nested | color=#ff9f0a font=Menlo
    """)
    #expect(lines.count == 4)
    #expect(lines[0].text == "Build passing" && lines[0].color == "green" && lines[0].symbol == "checkmark.circle")
    #expect(lines[1].isDivider)
    #expect(lines[2].href == "https://github.com" && lines[2].bash == "gh pr view --web" && lines[2].size == 12)
    #expect(lines[3].depth == 1 && lines[3].text == "Nested" && lines[3].color == "FF9F0A" && lines[3].monospaced)
}
