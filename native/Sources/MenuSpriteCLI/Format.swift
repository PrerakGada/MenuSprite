import AgentProtocol
import Foundation

/// The human (and agent-readable) wording of answers. The CLI and the MCP tools share it, so an agent
/// reads the same text whichever way it reached MenuSprite.
enum Format {
    /// Columns aligned by the widest cell; the last column is never padded.
    static func table(_ header: [String]?, _ rows: [[String]], indent: Int = 0) -> String {
        let all = (header.map { [$0] } ?? []) + rows
        guard let columns = all.map(\.count).max(), columns > 0 else { return "" }
        let widths = (0..<columns).map { column in all.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0 }
        let margin = String(repeating: " ", count: indent)
        return all.map { row in
            let line = margin + row.enumerated().map { column, cell in column == row.count - 1 ? cell : cell.padded(to: widths[column]) }
                .joined(separator: "  ")
            // An empty last cell would leave padding hanging off the end.
            return String(line.reversed().drop { $0 == " " }.reversed())
        }.joined(separator: "\n") + "\n"
    }

    /// `path: message — hint`, the form agents fix specs from.
    static func diagnostic(_ diagnostic: SpecDiagnostic) -> String {
        "\(diagnostic.path.isEmpty ? "(spec)" : diagnostic.path): \(diagnostic.message)" + (diagnostic.hint.map { " — \($0)" } ?? "")
    }

    static func diagnostics(_ list: [SpecDiagnostic]) -> String {
        var text = ""
        let errors = list.filter { $0.severity == .error }
        let warnings = list.filter { $0.severity == .warning }
        if !errors.isEmpty { text += "Errors:\n" + errors.map { "  \(diagnostic($0))\n" }.joined() }
        if !warnings.isEmpty { text += "Warnings:\n" + warnings.map { "  \(diagnostic($0))\n" }.joined() }
        return text
    }

    /// The catalog as a table. Once sampled, every reading has a value or says why not, so a blank is never
    /// mistaken for "not asked".
    static func readings(_ readings: [ReadingInfo], sampled: Bool = false) -> String {
        let showsValue = sampled || readings.contains { $0.value != nil }
        let header = ["ID", "NAME", "UNIT", "GROUP"] + (showsValue ? ["VALUE"] : [])
        return table(header, readings.map { reading in
            [reading.id, reading.name, reading.unit, reading.group] + (showsValue ? [reading.value ?? reading.problem.map { "– \($0)" } ?? "–"] : [])
        })
    }

    static func sprites(_ sprites: [SpriteSummary]) -> String {
        table(["NAME", "ID", "STATE", "SIDE", "BOARD", "VALUES"], sprites.map { sprite in
            [sprite.name, String(sprite.id.prefix(8)), state(sprite), sprite.side, sprite.board, sprite.values.joined(separator: ", ")]
        })
    }

    /// "shown", "hidden" (running, not in the bar) or "off".
    static func state(_ sprite: SpriteSummary) -> String { !sprite.enabled ? "off" : sprite.menuBar ? "shown" : "hidden" }

    static func placement(_ sprite: SpriteSummary) -> String {
        guard sprite.enabled else { return "switched off" }
        guard sprite.menuBar else { return "running, hidden from the menu bar" }
        return sprite.side == "left" ? "in the menu bar, on the left strip" : "in the menu bar, on the right"
    }

    static func sprite(_ sprite: SpriteSummary) -> String {
        "“\(sprite.name)” (\(sprite.id.prefix(8))): \(placement(sprite)); \(sprite.board == "custom" ? "custom board" : "classic panel").\n"
    }

    /// The headline of an apply. `failedBlocks` comes from its preview: a spec can be valid and still draw a
    /// board whose script fails, and "valid" alone would read as "done".
    static func apply(_ result: ApplyResult, dryRun: Bool, failedBlocks: Int = 0) -> String {
        let name = "“\(result.sprite.name)”"
        let hasErrors = result.diagnostics.contains { $0.severity == .error }
        let failed = failedBlocks == 0 ? "" : "\(failedBlocks) board block\(failedBlocks == 1 ? "" : "s") failed to draw"
        var text: String
        if dryRun {
            text = hasErrors ? "Dry run: \(name) has errors; nothing was saved.\n"
                : failed.isEmpty ? "Dry run: \(name) is valid and would be \(result.created ? "created" : "replaced"). Nothing was saved.\n"
                : "Dry run: \(name) is valid, but \(failed). It would be \(result.created ? "created" : "replaced"); nothing was saved.\n"
        } else if result.saved {
            text = "\(result.created ? "Created" : "Updated") \(name) (id \(result.sprite.id)): \(placement(result.sprite))"
                + (failed.isEmpty ? ".\n" : "; but \(failed).\n")
        } else {
            text = "\(name) was not saved.\n"
        }
        text += diagnostics(result.diagnostics)
        if !result.sprite.commands.isEmpty {
            text += "Commands it runs:\n" + result.sprite.commands.map { "  \($0)\n" }.joined()
        }
        return text
    }

    static func values(_ states: [ValueState]) -> String {
        table(nil, states.map { state in
            [state.id, state.value.map { $0.isEmpty ? "(empty)" : $0 } ?? "no value", state.problem.map { "— \($0)" } ?? ""]
        }, indent: 2)
    }

    /// A render: failed board blocks first (with the end of their error output), then the pictures, the
    /// values, what each script block drew, and notes. `headline` starts with a count of failed blocks, for a
    /// preview that has no apply headline above it.
    static func render(_ result: RenderResult, headline: Bool = false) -> String {
        var text = ""
        let failed = result.failedBlocks
        if !failed.isEmpty {
            if headline { text += "\(failed.count) board block\(failed.count == 1 ? "" : "s") failed to draw.\n" }
            text += "Failed blocks:\n" + failed.map(block).joined()
        }
        if result.files.isEmpty { text += "Nothing was drawn.\n" }
        else {
            text += "Pictures:\n" + table(nil, result.files.map { file in
                [file.kind, file.appearance, file.path, "\(file.width)×\(file.height)"]
            }, indent: 2)
        }
        if !result.values.isEmpty { text += "Values:\n" + values(result.values) }
        let drawn = (result.blocks ?? []).filter { $0.problem == nil }
        if !drawn.isEmpty { text += "Board blocks:\n" + drawn.map(block).joined() }
        text += notes(result.notes)
        return text + diagnostics(result.diagnostics)
    }

    /// One script block: `board.blocks[2] (script `python3 prs.py`): …`, then its stderr's last lines or its rows.
    static func block(_ report: BlockReport) -> String {
        let command = report.command.count > 60 ? String(report.command.prefix(59)) + "…" : report.command
        var text = "  \(report.path) (\(report.kind) `\(command)`)"
        if let problem = report.problem {
            text += ": \(problem)\n"
            if let stderr = report.stderr { text += "    stderr ends:\n" + stderr.split(separator: "\n").map { "      \($0)\n" }.joined() }
        } else {
            let rows = report.rows ?? []
            let count = report.kind == "script" ? rows.filter { !$0.hasPrefix("…") && $0 != "---" }.count : 0
            text += report.kind == "script" ? (rows.isEmpty ? ": printed nothing, so it draws no rows\n" : ": \(count) row\(count == 1 ? "" : "s")\n") : ":\n"
            text += rows.map { "    \($0)\n" }.joined()
        }
        return text
    }

    /// Notes as a list; a note of several lines keeps its later lines indented under it.
    static func notes(_ notes: [String]) -> String {
        guard !notes.isEmpty else { return "" }
        return "Notes:\n" + notes.map { "  - " + $0.replacingOccurrences(of: "\n", with: "\n    ") + "\n" }.joined()
    }

    static func refresh(_ result: RefreshResult, sprite: String) -> String {
        "Ran “\(sprite)”'s commands again.\n" + (result.values.isEmpty ? "It has no values.\n" : "Values:\n" + values(result.values))
    }

    static func examples(_ examples: [AgentExamples.Example]) -> String {
        guard !examples.isEmpty else { return "No examples are built in yet.\n" }
        return table(["NAME", "WHAT IT SHOWS"], examples.map { [$0.name, $0.summary] })
            + "Read one with get_example (or menusprite examples <name>) and start from it.\n"
    }

    /// `forMCP`: an MCP client has no --json, so it gets far more of the output and a hint it can act on.
    static func run(_ result: RunResult, forMCP: Bool = false) -> String {
        var rows: [[String]] = []
        if let value = result.text { rows.append(["value", value.isEmpty ? "(empty)" : value]) }
        if let number = result.number { rows.append(["number", JSONValue.number(number).serialized()]) }
        if let problem = result.problem { rows.append(["problem", problem]) }
        rows.append(["status", (result.status.map { "exit \($0)" } ?? "killed") + String(format: " · %.2f s", result.elapsed)])
        var text = (result.problem == nil ? "" : "No value.\n") + table(nil, rows)
        let more = forMCP ? "narrow the command, e.g. | sed -n '400,800p', to see more" : "--json shows all"
        text += excerpt("output", result.output, limit: forMCP ? 400 : 40, more: more)
        text += excerpt("stderr", result.error, limit: forMCP ? 100 : 20, more: more)
        return text
    }

    /// The first `limit` lines of a stream, indented, with a count of the rest.
    static func excerpt(_ title: String, _ text: String, limit: Int, more: String = "--json shows all") -> String {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return "" }
        let lines = trimmed.components(separatedBy: "\n")
        var body = lines.prefix(limit).map { "  \($0)\n" }.joined()
        if lines.count > limit { body += "  … \(lines.count - limit) more lines (\(more))\n" }
        return "\(title):\n" + body
    }
}
