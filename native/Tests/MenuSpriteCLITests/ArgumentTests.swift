import Testing
@testable import MenuSpriteCLI

@Test func parsesWordsOptionsAndFlags() throws {
    let apply = try Arguments.parse(["apply", "spec.json", "--dry-run", "--preview", "out", "--json"])
    #expect(apply == Invocation(verb: "apply", words: ["spec.json"], options: ["preview": "out"], flags: ["dry-run", "json"]))
    #expect(try Arguments.parse(["apply", "--preview=shots", "-"]).options["preview"] == "shots")
    #expect(try Arguments.parse(["apply", "--preview=shots", "-"]).words == ["-"])

    let preview = try Arguments.parse(["preview", "My", "Sprite", "--both", "--no-board", "--out=/tmp/x"])
    #expect(preview.joined == "My Sprite")
    #expect(preview.flags == ["both", "no-board"])
    #expect(preview.option("out") == "/tmp/x")

    let run = try Arguments.parse(["run", "gh pr list", "--parse", "number", "--timeout", "5", "--sprite", "PRs"])
    #expect(run.joined == "gh pr list")
    #expect(run.options == ["parse": "number", "timeout": "5", "sprite": "PRs"])

    // After --, everything is a word: a command's own options are not menusprite's.
    let raw = try Arguments.parse(["run", "--", "gh", "pr", "list", "--json", "number"])
    #expect(raw.joined == "gh pr list --json number")
    #expect(!raw.json)

    #expect(try Arguments.parse(["side", "GitHub", "PRs", "left"]).words == ["GitHub", "PRs", "left"])
    #expect(try Arguments.parse(["readings"]).words.isEmpty)
    #expect(try Arguments.parse(["readings", "battery", "--sample"]).has("sample"))
}

@Test func helpAndVersionShortcuts() throws {
    #expect(try Arguments.parse([]).verb == "help")
    #expect(try Arguments.parse(["--help"]).verb == "help")
    #expect(try Arguments.parse(["-h", "apply"]) == Invocation(verb: "help", words: ["apply"]))
    #expect(try Arguments.parse(["--version"]).verb == "version")
    // A verb's own --help skips the argument count.
    #expect(try Arguments.parse(["apply", "--help"]).has("help"))
    #expect(try Arguments.parse(["side", "-h"]).has("help"))
}

@Test func rejectsBadArgumentsWithTheMissingPiece() {
    func message(_ arguments: [String]) -> String? {
        do { _ = try Arguments.parse(arguments); return nil } catch let error as UsageError { return error.message } catch { return "\(error)" }
    }
    #expect(message(["frobnicate"]) == "Unknown command “frobnicate”.")
    #expect(message(["--json"])?.contains("Options go after a command") == true)
    #expect(message(["apply", "x.json", "--bogus"]) == "Unknown option --bogus for apply.")
    #expect(message(["apply", "x.json", "--preview"]) == "--preview needs a value.")
    #expect(message(["apply", "x.json", "--dry-run=yes"]) == "--dry-run takes no value.")
    #expect(message(["validate", "a.json", "b.json"])?.contains("does not take “b.json”") == true)
    #expect(message(["apply"]) == "apply is missing <file|->.")
    #expect(message(["side", "PRs"]) == "side is missing left|right.")
    #expect(message(["get"]) == "get is missing <sprite>.")
    #expect(message(["list", "-x"]) == "Unknown option -x for list.")
    #expect(message(["list", "extra"])?.contains("does not take") == true)
}

@Test func everyVerbInTheContractExistsAndHasHelp() {
    let contract = ["guide", "schema", "readings", "list", "get", "validate", "apply", "preview", "run", "refresh", "examples", "remove",
                    "enable", "disable", "show", "hide", "side", "open", "mcp", "setup", "version", "help"]
    #expect(Arguments.verbs.map(\.name) == contract)
    for verb in Arguments.verbs { #expect(Help.text(for: verb).hasPrefix("Usage: menusprite \(verb.name)")) }
    #expect(Help.general.contains("Exit status: 0"))
}

@Test func repeatedValueOptionsKeepTheirOrder() throws {
    let preview = try Arguments.parse(["preview", "PRs", "--value", "prs=12", "--value=state=Running", "--light"])
    #expect(preview.list("value") == ["prs=12", "state=Running"])
    #expect(preview.joined == "PRs")
    let apply = try Arguments.parse(["apply", "s.json", "--preview", "out", "--both", "--value", "session.pace=over"])
    #expect(apply.options == ["preview": "out"])
    #expect(apply.list("value") == ["session.pace=over"])
    #expect(apply.has("both"))
    #expect(try Arguments.parse(["run", "python3 v.py", "--files", "draft.json"]).option("files") == "draft.json")
    #expect(try Arguments.parse(["examples"]).words.isEmpty)
    #expect(try Arguments.parse(["refresh", "GitHub", "PRs"]).joined == "GitHub PRs")
    #expect(throws: UsageError.self) { try Arguments.parse(["refresh"]) }
}
