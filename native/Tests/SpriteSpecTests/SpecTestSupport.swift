import Foundation
import AgentProtocol
import SystemMonitoring
@testable import SpriteSpec

/// The base catalog, symbols that all exist except those starting "bogus", and a fixed folder per sprite.
func testEnvironment(hasFiles: Bool = false) -> SpecEnvironment {
    let catalog = Dictionary(MonitoringCatalog.base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return SpecEnvironment(metric: { catalog[$0] }, readingIDs: { MonitoringCatalog.base.map(\.id) },
                           symbolExists: { !$0.hasPrefix("bogus") },
                           spriteDirectory: { "/tmp/menusprite-tests/\($0.uuidString)" },
                           hasFiles: { _ in hasFiles })
}

func metric(_ id: String) -> Metric? { MonitoringCatalog.base.first { $0.id == id } }

func compile(_ text: String, existing: SpriteConfiguration? = nil, environment: SpecEnvironment = testEnvironment())
    throws -> (CompiledSprite?, [SpecDiagnostic]) {
    SpriteSpecFormat.compile(try JSONValue.parse(text), existing: existing, environment: environment)
}

extension Array where Element == SpecDiagnostic {
    var errors: [SpecDiagnostic] { filter { $0.severity == .error } }
    var warnings: [SpecDiagnostic] { filter { $0.severity == .warning } }
    func at(_ path: String) -> [SpecDiagnostic] { filter { $0.path == path } }
}

/// A design with every id replaced by a studio-style random one (rule targets follow), so emit has to
/// carry ids rather than lean on the position-derived ones.
func reidentified(_ design: SpriteDesign) -> SpriteDesign {
    var map: [String: String] = [:]
    func renamed(_ node: DesignNode) -> DesignNode {
        var copy = node
        copy.id = DesignNode.newID(); map[node.id] = copy.id
        copy.children = node.children.map { renamed($0) }
        return copy
    }
    func renamed(_ block: BoardBlock) -> BoardBlock {
        var copy = block
        copy.id = DesignNode.newID(); map[block.id] = copy.id
        copy.children = block.children.map { renamed($0) }
        return copy
    }
    var result = design
    result.root = renamed(design.root)
    if let board = design.board { result.board?.root = renamed(board.root) }
    func action(_ action: RuleAction) -> RuleAction {
        var copy = action; copy.id = DesignNode.newID(); copy.target = map[action.target] ?? action.target; return copy
    }
    result.rules = design.rules.map { rule in
        var copy = rule
        copy.id = DesignNode.newID()
        copy.branches = rule.branches.map { branch in
            var b = branch
            b.id = DesignNode.newID()
            b.conditions = branch.conditions.map { var c = $0; c.id = DesignNode.newID(); return c }
            b.actions = branch.actions.map(action)
            return b
        }
        copy.otherwise = rule.otherwise.map(action)
        return copy
    }
    return result
}

/// Rules without the ids of their branches, conditions and actions, which a spec does not carry.
func shape(_ rules: [SpriteRule]) -> [String] {
    rules.map { rule in
        let branches = rule.branches.map { branch in
            branch.match.rawValue + ":" + branch.conditions.map { "\($0.variable).\($0.aspect.rawValue) \($0.comparison.rawValue) \($0.operand)" }.joined(separator: ",")
                + "→" + branch.actions.map { "\($0.target) \($0.kind.rawValue) \($0.value)" }.joined(separator: ",")
        }
        return "\(rule.id) \(rule.name) \(rule.enabled) [\(branches.joined(separator: " | "))] else " + rule.otherwise.map { "\($0.target) \($0.kind.rawValue) \($0.value)" }.joined(separator: ",")
    }
}

/// A spec that uses every part of the grammar, and should compile without a single diagnostic.
let showcaseSpec = #"""
{
  "menusprite": 1,
  "name": "Showcase",
  "icon": "sparkles",
  "enabled": true,
  "menuBar": false,
  "side": "left",
  "every": 5,
  "values": [
    {"id": "cpu", "reading": "cpu.usage", "name": "CPU", "decimals": 1, "unit": false},
    {"id": "temp", "reading": "sensor.cpuTemperature", "fahrenheit": true},
    {"id": "down", "reading": "network.download", "bits": true},
    {"id": "charge", "reading": "battery.charge"},
    {"id": "claude", "reading": "ai.claude.session"},
    {"id": "prs", "command": "python3 prs.py", "every": "5m", "timeout": 20, "parse": "number", "suffix": " open", "background": true},
    {"id": "stars", "command": "gh repo view --json stargazerCount", "parse": "json", "path": "stargazerCount", "every": 90},
    {"id": "logs", "command": "tail -n 20 /tmp/x.log", "every": "1h"},
    {"id": "ts", "command": "tailscale status --json", "parse": "json", "path": "BackendState", "name": "Tailscale"},
    {"id": "hello", "text": "Hi"}
  ],
  "face": {"row": [
      {"icon": "flame", "id": "flame", "size": 13, "color": "orange"},
      {"column": [
          {"text": "CPU", "id": "label", "size": 8, "weight": "semibold", "tabular": false, "shrink": true, "opacity": 0.8, "align": "leading"},
          {"text": "{cpu}%", "id": "pct", "size": 12, "weight": "heavy"}
      ], "gap": 2, "justify": "even", "name": "Reading"},
      {"bar": "cpu", "id": "bar", "size": 9},
      {"battery": "charge", "chargeInside": false},
      ["{prs}", {"text": "★ {stars}", "hidden": true, "id": "starsText"}],
      "{hello}"
    ], "gap": 6, "padding": 4, "color": "auto", "justify": "spaceBetween"},
  "rules": [
    {"name": "Hot", "when": "cpu > 80 and temp >= 90", "then": [{"target": "pct", "color": "red", "text": "{cpu}!"}],
     "else": [{"target": "pct", "color": "inherit"}]},
    {"id": "pace", "name": "Pace", "cases": [
        {"when": "claude.pace == 'over'", "then": [{"target": "label", "color": "#FF0000"}]},
        {"when": "claude.pace == 'on track' or claude is missing", "then": [{"target": "label", "color": "green", "opacity": 0.5}]}
      ], "else": [{"target": "label", "color": "yellow"}]},
    {"name": "PRs", "enabled": false, "when": "prs is present",
     "then": [{"target": "starsText", "show": true}, {"target": "flame", "icon": "flame.fill", "hide": true}]},
    {"name": "Board", "when": "ts contains Running", "then": [{"target": "status", "color": "green"}, {"target": "gauge", "hide": true}]},
    {"name": "Down", "when": "down <= 1000 and down != 0 and down < 5", "then": [{"target": "bar", "color": "teal"}]},
    {"name": "Missing", "when": "hello is missing", "match": "any", "then": [{"target": "card", "opacity": 0.3}]}
  ],
  "board": {
    "width": 420, "header": false, "id": "main", "spacing": 12, "padding": 4,
    "blocks": [
      {"text": "Pull requests", "font": "title", "id": "status", "align": "center"},
      {"row": [
         {"value": "prs", "caption": "Open", "font": "huge", "detail": "{prs} of {stars}"},
         {"gauge": "cpu", "id": "gauge", "max": 400, "caption": "CPU", "detail": "{cpu} used", "color": "blue"}
      ], "spacing": 6},
      {"card": [
         {"chart": "cpu", "caption": "CPU history", "height": 40},
         {"chart": "prs", "caption": "PRs"},
         {"stats": ["cpu", "temp", "down"]},
         {"divider": true},
         {"space": 16},
         {"output": "logs", "height": 120}
      ], "title": "Details", "id": "card", "background": "#1C1C1E"},
      {"row": [
        {"button": "Open", "icon": "safari", "open": "https://github.com/pulls"},
        {"button": "Run", "run": "gh pr list"},
        {"button": "Activity", "app": "Activity Monitor"},
        {"button": "Copy", "copy": "CPU {cpu}"},
        {"button": "Refresh", "refresh": true, "icon": "arrow.clockwise"}
      ]},
      {"toggle": "Tailscale", "value": "ts", "on": "tailscale up", "off": "tailscale down", "icon": "network"},
      {"script": "echo 'hi | sfimage=hand.wave'", "every": 30, "timeout": 5},
      {"blocks": "python3 prs.py --blocks", "every": "1m", "timeout": 30},
      {"image": "chart.png", "height": 100, "opacity": 0.9},
      {"processes": "cpu", "limit": 6},
      {"energy": true, "height": 500},
      {"accounts": true},
      {"readings": true, "name": "All readings"},
      {"stack": [{"text": "{hello} there", "font": "mono", "color": "gray"}], "spacing": 4, "name": "Footer"}
    ]
  },
  "files": {"prs.py": "#!/usr/bin/env python3\nprint(3)\n", "notes.txt": "x"}
}
"""#
