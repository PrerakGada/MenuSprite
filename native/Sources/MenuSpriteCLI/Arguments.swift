/// One verb's shape. Hand-parsed so the command stays a small binary with no dependencies.
struct Verb: Sendable {
    var name: String
    var usage: String
    var summary: String
    /// Fewest and most words after the verb. `nil` = any number, joined with spaces, so a sprite name or a
    /// command need not be quoted.
    var minimum = 0
    var maximum: Int? = 0
    /// Options that take a value (`--out dir` or `--out=dir`).
    var values: Set<String> = []
    /// Options that take a value and may be repeated (`--value a=1 --value b=2`), kept in order.
    var lists: Set<String> = []
    var flags: Set<String> = []
    /// More to say in `menusprite help <verb>`.
    var notes = ""
}

struct Invocation: Equatable, Sendable {
    var verb: String
    var words: [String] = []
    var options: [String: String] = [:]
    var lists: [String: [String]] = [:]
    var flags: Set<String> = []
    var json: Bool { flags.contains("json") }
    func has(_ flag: String) -> Bool { flags.contains(flag) }
    func option(_ name: String) -> String? { options[name] }
    func list(_ name: String) -> [String] { lists[name] ?? [] }
    /// Every word as one: a sprite name or a command typed without quotes.
    var joined: String { words.joined(separator: " ") }
}

struct UsageError: Error, Equatable, CustomStringConvertible {
    var message: String
    /// The verb whose usage line helps, when there is one.
    var verb: String?
    init(_ message: String, verb: String? = nil) { self.message = message; self.verb = verb }
    var description: String { message }
}

enum Arguments {
    /// Options every verb takes.
    static let globalFlags: Set<String> = ["json", "help"]

    static let verbs: [Verb] = [
        Verb(name: "guide", usage: "guide", summary: "The authoring guide (Markdown). Start here."),
        Verb(name: "schema", usage: "schema", summary: "The JSON Schema of the sprite spec."),
        Verb(name: "readings", usage: "readings [search] [--sample]",
             summary: "Reading ids, names, units and groups; --sample adds each one's current value.",
             maximum: nil, flags: ["sample"]),
        Verb(name: "list", usage: "list", summary: "Your sprites: name, id, state, side, board kind and values."),
        Verb(name: "get", usage: "get <sprite>", summary: "A sprite as a spec, with its files. Edit it and apply it back.",
             minimum: 1, maximum: nil),
        Verb(name: "validate", usage: "validate <file|->", summary: "Check a spec without saving it.", minimum: 1, maximum: 1),
        Verb(name: "apply", usage: "apply <file|-> [--dry-run] [--preview <dir>] [--dark|--light|--both] [--value <id>=<value>]",
             summary: "Create a sprite, or replace the one with the same id or name.",
             minimum: 1, maximum: 1, values: ["preview"], lists: ["value"], flags: ["dry-run", "dark", "light", "both"],
             notes: """
                 --dry-run checks the spec and saves nothing. --preview <dir> also draws the face and board there, in both \
                 dark and light mode unless --dark or --light says otherwise. --value id=value (repeatable) draws a stand-in \
                 instead of that value's live one in the pictures: --value free=12 --value state=Running --value session.pace=over.
                 """),
        Verb(name: "preview", usage: "preview <sprite|file|-> [--out <dir>] [--dark|--light|--both] [--no-board] [--no-face] [--value <id>=<value>]",
             summary: "Draw the face and board to PNG files with live values, without saving anything.",
             minimum: 1, maximum: nil, values: ["out"], lists: ["value"], flags: ["dark", "light", "both", "no-board", "no-face"],
             notes: """
                 A path that exists (or -) is read as a draft spec; anything else names a saved sprite. Without --out the pictures \
                 go to a new folder under $TMPDIR. Drawing runs the sprite's commands once. --value id=value (repeatable) draws a \
                 stand-in instead of that value's live one: a number, text, true/false, null (missing), or for a Claude/Codex limit id.pace=over.
                 """),
        Verb(name: "run", usage: "run '<command>' [--parse text|number|json] [--path <p>] [--timeout <s>] [--sprite <sprite> | --files <spec>]",
             summary: "Run a command exactly as a command value would and show what it parses to.",
             minimum: 1, maximum: nil, values: ["parse", "path", "timeout", "sprite", "files"],
             notes: """
                 Quote the command so its own options are not read as menusprite's. Exits 1 when the command gives no value. \
                 --sprite runs it in a saved sprite's folder; --files <spec.json|-> runs it in a temporary folder holding that \
                 draft spec's files (SPRITE_DIR set), so a script can be tried before the sprite is saved.
                 """),
        Verb(name: "refresh", usage: "refresh <sprite>", summary: "Run a sprite's commands again now and show its values.",
             minimum: 1, maximum: nil,
             notes: "For a script that finished a long job (one a button started) to update the menu bar at once. Commands see MENUSPRITE_TRIGGER=refresh."),
        Verb(name: "examples", usage: "examples [name]", summary: "The example sprites, or one example's spec (JSON) to start from.",
             maximum: 1),
        Verb(name: "remove", usage: "remove <sprite>", summary: "Delete a sprite and its folder.", minimum: 1, maximum: nil),
        Verb(name: "enable", usage: "enable <sprite>", summary: "Switch a sprite on.", minimum: 1, maximum: nil),
        Verb(name: "disable", usage: "disable <sprite>", summary: "Switch a sprite off: nothing of it runs.", minimum: 1, maximum: nil),
        Verb(name: "show", usage: "show <sprite>", summary: "Show a sprite in the menu bar.", minimum: 1, maximum: nil),
        Verb(name: "hide", usage: "hide <sprite>", summary: "Hide a sprite from the menu bar (it keeps running).", minimum: 1, maximum: nil),
        Verb(name: "side", usage: "side <sprite> left|right", summary: "Move a sprite to the left strip or the right side.",
             minimum: 2, maximum: nil),
        Verb(name: "open", usage: "open <sprite>", summary: "Pop the sprite's board open on screen.", minimum: 1, maximum: nil),
        Verb(name: "mcp", usage: "mcp", summary: "Serve MCP on stdio, for AI agents (see setup)."),
        Verb(name: "setup", usage: "setup <claude|codex|cursor|claude-desktop|antigravity> [--print]",
             summary: "Register the MCP server with an agent; --print shows the change without making it.",
             maximum: 1, flags: ["print"]),
        Verb(name: "version", usage: "version", summary: "This command's version, and the running app's."),
        Verb(name: "help", usage: "help [command]", summary: "This help, or one command's.", maximum: 1),
    ]

    static func verb(named name: String) -> Verb? { verbs.first { $0.name == name } }

    static func parse(_ arguments: [String]) throws -> Invocation {
        guard let first = arguments.first else { return Invocation(verb: "help") }
        switch first {
        case "-h", "--help": return Invocation(verb: "help", words: Array(arguments.dropFirst().prefix(1)))
        case "-v", "--version": return Invocation(verb: "version", flags: arguments.contains("--json") ? ["json"] : [])
        default: break
        }
        guard let verb = verb(named: first) else {
            throw UsageError(first.hasPrefix("-") ? "Options go after a command: \(first)." : "Unknown command “\(first)”.")
        }
        var invocation = Invocation(verb: verb.name)
        var index = 1
        var onlyWords = false
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if onlyWords || argument == "-" || !argument.hasPrefix("-") { invocation.words.append(argument); continue }
            if argument == "--" { onlyWords = true; continue }
            if argument == "-h" { invocation.flags.insert("help"); continue }
            guard argument.hasPrefix("--") else { throw UsageError("Unknown option \(argument) for \(verb.name).", verb: verb.name) }
            var name = String(argument.dropFirst(2))
            var inline: String?
            if let equals = name.firstIndex(of: "=") {
                inline = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }
            if verb.values.contains(name) || verb.lists.contains(name) {
                let value: String
                if let inline { value = inline }
                else if index < arguments.count { value = arguments[index]; index += 1 }
                else { throw UsageError("--\(name) needs a value.", verb: verb.name) }
                if verb.lists.contains(name) { invocation.lists[name, default: []].append(value) } else { invocation.options[name] = value }
            } else if verb.flags.contains(name) || globalFlags.contains(name) {
                guard inline == nil else { throw UsageError("--\(name) takes no value.", verb: verb.name) }
                invocation.flags.insert(name)
            } else {
                throw UsageError("Unknown option --\(name) for \(verb.name).", verb: verb.name)
            }
        }
        if invocation.has("help") { return invocation }
        if invocation.words.count < verb.minimum {
            // The usage line's required words ("<file|->", "left|right"), outside any [optional] part, name what is missing.
            var required: [String] = [], word = "", depth = 0
            for character in verb.usage + " " {
                if character == "[" { depth += 1 } else if character == "]" { depth -= 1 }
                else if depth == 0, character == " " { if !word.isEmpty { required.append(word); word = "" } }
                else if depth == 0 { word.append(character) }
            }
            let missing = required.dropFirst(1 + invocation.words.count).joined(separator: " ")
            throw UsageError("\(verb.name) is missing \(missing.isEmpty ? "an argument" : missing).", verb: verb.name)
        }
        if let maximum = verb.maximum, invocation.words.count > maximum {
            let extra = invocation.words[maximum...].joined(separator: " ")
            throw UsageError("\(verb.name) does not take “\(extra)”. Quote a value that has spaces.", verb: verb.name)
        }
        return invocation
    }
}

enum Help {
    static var general: String {
        let width = Arguments.verbs.map(\.name.count).max() ?? 0
        let lines = Arguments.verbs.map { "  \($0.name.padded(to: width))  \($0.summary)" }.joined(separator: "\n")
        return """
        menusprite: build and change MenuSprite sprites (the menu-bar items and the boards they open) from the
        shell or an AI agent. Everything goes through the running MenuSprite app.

        Usage: menusprite <command> [arguments] [--json]

        \(lines)

        <sprite> is a name (any case), an id, or an id prefix of at least 4 characters.
        A spec is a JSON file, or - for standard input. Every command takes --json for the raw answer.
        Exit status: 0 done, 1 a spec, argument or command problem, 2 MenuSprite is not available.
        Agents: menusprite setup claude (or codex, cursor, claude-desktop, antigravity). Start with: menusprite guide

        """
    }

    static func text(for verb: Verb) -> String {
        "Usage: menusprite \(verb.usage)\n\n\(verb.summary)\n" + (verb.notes.isEmpty ? "" : "\n\(verb.notes)\n")
    }
}

extension String {
    /// Pads with spaces to `width` characters (by Character, so an accented name lines up).
    func padded(to width: Int) -> String { count >= width ? self : self + String(repeating: " ", count: width - count) }
}
