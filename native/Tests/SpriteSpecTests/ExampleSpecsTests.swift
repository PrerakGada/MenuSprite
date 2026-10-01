import Foundation
import Testing
import AgentProtocol
import SystemMonitoring
@testable import SpriteSpec

// What agents copy from: the example sprites in `examples/sprites/` (compiled into the menusprite command as
// `AgentExamples`) and the complete specs in the authoring guide. An example that stops compiling would teach
// every agent that reads it a mistake, so each one must compile without a single diagnostic, read back exactly,
// and the blocks its scripts print must parse cleanly.

/// The repository root, found from this file: native/Tests/SpriteSpecTests/ExampleSpecsTests.swift.
private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let examplesFolder = repository.appendingPathComponent("examples/sprites", isDirectory: true)

private func exampleFiles() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: examplesFolder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// Every ```json block of the guide that is a whole spec (its JSON starts with {"menusprite").
private func guideSpecs() -> [String] {
    var specs: [String] = [], current: [String]?
    for line in AgentGuide.markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if current == nil {
            if line.trimmingCharacters(in: .whitespaces) == "```json" { current = [] }
        } else if line.trimmingCharacters(in: .whitespaces) == "```" {
            let block = current!.joined(separator: "\n")
            if block.filter({ !$0.isWhitespace }).hasPrefix("{\"menusprite\"") { specs.append(block) }
            current = nil
        } else {
            current!.append(line)
        }
    }
    return specs
}

/// Compiles a spec, expecting no errors and no warnings, and checks it reads back exactly as `get` then `apply` would.
private func compileCleanly(_ text: String, _ label: String) throws -> SpriteConfiguration? {
    let environment = testEnvironment()
    let (compiled, diagnostics) = SpriteSpecFormat.compile(try JSONValue.parse(text), existing: nil, environment: environment)
    #expect(diagnostics.isEmpty, "\(label): \(diagnostics.map(\.description).joined(separator: "\n"))")
    guard let compiled else { return nil }
    let emitted = SpriteSpecFormat.emit(compiled.config, side: compiled.side ?? .right, files: compiled.files ?? [:], environment: environment)
    let (again, more) = SpriteSpecFormat.compile(emitted, existing: compiled.config, environment: environment)
    #expect(more.isEmpty, "\(label), read back: \(more.map(\.description).joined(separator: "\n"))")
    #expect(again?.config == compiled.config, "\(label) does not read back as it was written")
    return compiled.config
}

private func design(of example: String) throws -> SpriteDesign {
    let example = try #require(AgentExamples.named(example), "no example \(example)")
    let compiled = SpriteSpecFormat.compile(try JSONValue.parse(example.json), existing: nil, environment: testEnvironment()).0
    return try #require(compiled?.config.design, "\(example.name) does not compile")
}

/// The one-line summaries in examples/sprites/README.md, by example name.
private func readmeSummaries() throws -> [String: String] {
    let text = try String(contentsOf: examplesFolder.appendingPathComponent("README.md"), encoding: .utf8)
    var found: [String: String] = [:]
    for line in text.split(separator: "\n").map(String.init) where line.hasPrefix("| `") {
        let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard cells.count == 2, cells[0].hasPrefix("`"), cells[0].hasSuffix("`") else { continue }
        found[String(cells[0].dropFirst().dropLast())] = cells[1]
    }
    return found
}

@Test func exampleSpritesCompileWithoutDiagnostics() throws {
    let files = try exampleFiles()
    #expect(files.count >= 8, "examples/sprites holds \(files.count) specs")
    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        let config = try compileCleanly(text, file.lastPathComponent)
        // A sprite that carries files runs every command in its folder.
        if let config, let files = try JSONValue.parse(text)["files"]?.members, !files.isEmpty {
            let expected = testEnvironment().spriteDirectory(config.id)
            for variable in config.design?.commandVariables ?? [] { #expect(variable.command?.directory == expected, "\(file.lastPathComponent): \(variable.id)") }
            for command in config.design?.boardScriptCommands ?? [] { #expect(command.directory == expected, "\(file.lastPathComponent): \(command.command)") }
        }
    }
}

/// `AgentExamples` (what list_examples and get_example serve) is generated from the folder by
/// scripts/embed-agent-examples.py; this fails when someone edits an example and forgets to run it.
@Test func embeddedExamplesMatchTheFolder() throws {
    let files = try exampleFiles()
    let summaries = try readmeSummaries()
    let hint = "run python3 scripts/embed-agent-examples.py"
    #expect(AgentExamples.all.map(\.name) == files.map { $0.deletingPathExtension().lastPathComponent }, "\(hint)")
    for file in files {
        let name = file.deletingPathExtension().lastPathComponent
        guard let example = AgentExamples.named(name) else { continue }
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(example.json == text.trimmingCharacters(in: .newlines), "\(name) differs from examples/sprites/\(name).json: \(hint)")
        #expect(summaries[name] != nil, "examples/sprites/README.md has no row for \(name)")
        #expect(example.summary == summaries[name], "\(name)'s summary differs from the README's: \(hint)")
        #expect(!example.summary.isEmpty && !example.summary.contains("\n"))
    }
    #expect(Set(summaries.keys) == Set(AgentExamples.all.map(\.name)), "README rows without an example: \(Set(summaries.keys).subtracting(AgentExamples.all.map(\.name)))")
    #expect(AgentExamples.named("GITHUB-PRS")?.name == "github-prs")
}

/// Every example whose face shows a command value has a rule for when that value is missing, so a broken
/// command never looks like a quiet zero: the pattern the guide teaches.
@Test func examplesShowFailureApartFromZero() throws {
    for example in AgentExamples.all {
        let design = try design(of: example.name)
        let shown = Set(design.root.flattened.flatMap(\.referencedVariables))
        let missingChecked = Set(design.rules.flatMap { $0.branches.flatMap(\.conditions) }.filter { $0.comparison == .isMissing }.map(\.variable))
        for variable in design.commandVariables where shown.contains(variable.id) {
            #expect(missingChecked.contains(variable.id), "\(example.name): the face shows \(variable.id) but no rule handles it missing")
        }
    }
}

/// The examples that teach "one command, many values": the values (and the script block) named here must be
/// one run, and each value must find its number or text in what that command really prints.
@Test func sharedCommandsAreOneRunAndReadTheirValues() throws {
    // git-repo-status and homebrew-outdated: the face's value reads the first printed block from the board's own script.
    let printed: [(example: String, value: String, output: String, expected: Double)] = [
        ("git-repo-status", "dirty", #"[{"row": [{"value": 15, "caption": "Uncommitted"}, {"value": 7, "caption": "To push"}, {"value": 18, "caption": "Clean"}]}, {"card": [], "title": "Needs attention"}]"#, 15),
        ("homebrew-outdated", "outdated", #"[{"value": 17, "caption": "Upgrades waiting", "detail": "12 formulae · 5 apps"}]"#, 17),
    ]
    for (example, id, output, expected) in printed {
        let design = try design(of: example)
        let source = try #require(design.variable(id)?.command, "\(example): \(id)")
        let script = try #require(design.boardScriptCommands.first, "\(example) has no script block")
        #expect(source.execution == script.execution, "\(example): \(id) and the board's script are not one run")
        #expect(CommandOutputReader(output).value(for: source).number == expected, "\(example): \(id)")
        #expect(SpriteSpecFormat.scriptBlocks(output, design: design, directory: "/tmp/sprite").diagnostics.isEmpty)
    }
    // network-switches and weather: several values read one command's JSON.
    let tailscale = #"{"BackendState": "Running", "Self": {"TailscaleIPs": ["100.64.0.1", "fd7a::1"]}, "CurrentTailnet": {"Name": "example.github"}}"#
    let wttr = #"{"current_condition": [{"temp_C": "33", "weatherDesc": [{"value": "Sunny"}]}]}"#
    let groups: [(example: String, ids: [String], output: String, expected: [String])] = [
        ("network-switches", ["ts", "address", "tailnet"], tailscale, ["Running", "100.64.0.1", "example.github"]),
        ("weather", ["temp", "sky"], wttr, ["33", "Sunny"]),
    ]
    for (example, ids, output, expected) in groups {
        let design = try design(of: example)
        let sources = try ids.map { id in try #require(design.variable(id)?.command, "\(example): \(id)") }
        #expect(Set(sources.map(\.execution)).count == 1, "\(example): \(ids) are not one run")
        let reader = CommandOutputReader(output)
        #expect(sources.map { reader.value(for: $0).text } == expected, "\(example)")
        #expect(reader.documentParses == 1)
    }
}

@Test func guideSpecsCompileWithoutDiagnostics() throws {
    let specs = guideSpecs()
    #expect(specs.count >= 2, "the guide has \(specs.count) complete specs")
    for (index, spec) in specs.enumerated() {
        _ = try compileCleanly(spec, "guide example \(index + 1)")
    }
}

/// The guide lands in an agent's context: it must stay compact.
@Test func guideStaysCompact() {
    #expect(AgentGuide.markdown.count < 21_500, "the guide is \(AgentGuide.markdown.count) characters")
    #expect(AgentGuide.markdown.hasPrefix("# MenuSprite authoring guide"))
}

/// The guide names every built-in example, so an agent knows what get_example can give it.
@Test func guideListsEveryExample() {
    for example in AgentExamples.all { #expect(AgentGuide.markdown.contains("`\(example.name)`"), "the guide does not mention \(example.name)") }
}

/// The guide's script (example 1) prints blocks that parse cleanly, and the script is a real, executable file.
@Test func guideScriptPrintsValidBlocks() throws {
    let spec = try #require(guideSpecs().first { $0.contains("\"blocks\": \"python3 prs.py\"") })
    let script = try #require(try JSONValue.parse(spec)["files"]?["prs.py"]?.string)
    #expect(script.hasPrefix("#!/usr/bin/env python3\n"))
    #expect(script.contains("--limit"), "gh stops at 30 without --limit")
    // What it printed against a real account, trimmed.
    let output = #"[{"card": [{"stack": [{"text": "chat system implementation", "lines": 1}, {"text": "acme/admin #76", "font": "caption", "color": "gray"}], "spacing": 2, "open": "https://github.com/acme/admin/pull/76"}], "title": "Waiting for your review"}]"#
    let parsed = SpriteSpecFormat.scriptBlocks(output, design: SpriteDesign(), directory: nil)
    #expect(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
    #expect(parsed.blocks.map(\.kind) == [.card])
    #expect(parsed.blocks.first?.children.first?.action?.kind == .openURL, "each PR row opens its page")
}

/// Output the example sprites' scripts printed on a real Mac (trimmed, names changed), parsed as the board would.
@Test func exampleScriptsPrintValidBlocks() throws {
    let outputs: [(example: String, output: String)] = [
        ("github-prs", #"""
        [{"card": [{"stack": [{"text": "chat system {\u200bimplementation}", "lines": 1}, {"text": "acme/admin #76 · octo · 245d", "font": "caption", "color": "gray", "lines": 1}], "spacing": 2, "open": "https://github.com/acme/admin/pull/76"}], "title": "Waiting for your review · 1"},
         {"card": [{"text": "You have no open pull requests.", "font": "caption", "color": "gray"}], "title": "Your pull requests · 0"}]
        """#),
        ("github-prs", #"""
        [{"text": "GitHub did not answer", "font": "headline", "icon": "exclamationmark.triangle"}, {"text": "To get started with GitHub CLI, please run:  gh auth login", "font": "caption", "color": "gray"},
         {"text": "If you are signed out, run gh auth login in Terminal, then Refresh.", "font": "caption"}]
        """#),
        ("docker-containers", #"""
        [{"row": [{"value": 4, "caption": "Running"}, {"value": 22, "caption": "Stopped"}, {"value": 9, "caption": "Images"}]},
         {"card": [{"row": [{"stack": [{"text": "local-redis", "lines": 1, "truncate": "middle"}, {"text": "redis:7-alpine · Up 37 hours · port 6379", "font": "caption", "color": "gray", "lines": 1}], "spacing": 1},
                            {"toggle": "", "value": true, "color": "green", "fit": true, "on": "docker start local-redis", "off": "docker stop local-redis"}]},
                   {"row": [{"stack": [{"text": "company-23828f6d-0bdc-4bb2-a8b6-d0f4098d5eed-database-1", "lines": 1, "truncate": "middle"}, {"text": "postgres:18 · Exited (255) 2 weeks ago", "font": "caption", "color": "gray", "lines": 1}], "spacing": 1},
                            {"toggle": "", "value": false, "color": "green", "fit": true, "on": "docker start company-db-1", "off": "docker stop company-db-1"}]},
                   {"text": "and 14 more in Docker Desktop", "font": "caption", "color": "gray"}], "title": "Containers"}]
        """#),
        ("docker-containers", #"""
        [{"text": "Docker is not running", "font": "headline", "icon": "exclamationmark.triangle"}, {"text": "Cannot connect to the Docker daemon", "font": "caption", "color": "gray"}]
        """#),
        ("git-repo-status", #"""
        [{"row": [{"value": 2, "caption": "Uncommitted"}, {"value": 1, "caption": "To push"}, {"value": 18, "caption": "Clean"}]},
         {"card": [{"row": [{"stack": [{"text": "monorepo", "lines": 1, "truncate": "middle"}, {"text": "main", "font": "caption", "color": "gray", "lines": 1}], "spacing": 1},
                            {"text": "2 changed · 8 to push", "font": "caption", "color": "orange", "fit": true}], "run": "open -a Terminal /Users/example/Developer/monorepo"},
                   {"text": "and 5 more", "font": "caption", "color": "gray"}], "title": "Needs attention"}]
        """#),
        ("homebrew-outdated", #"""
        [{"value": 17, "caption": "Upgrades waiting", "detail": "12 formulae · 5 apps"},
         {"card": [{"stats": [{"name": "aws-c-common", "value": "1.0.1 → 1.0.2"}, {"name": "and 2 more", "value": ""}]}], "title": "Formulae"},
         {"card": [{"stats": [{"name": "codex", "value": "0.159.0 → 0.159.3"}]}], "title": "Apps"}]
        """#),
        ("weather", #"""
        [{"row": [{"value": "33°", "caption": "Ahmedabad", "font": "huge", "detail": "Sunny"},
                  {"stats": [{"name": "Feels like", "value": "33°"}, {"name": "Humidity", "value": "34%"}, {"name": "Wind", "value": "10 km/h N"}, {"name": "UV index", "value": "8"}]}]},
         {"card": [{"chart": [35.0, 33.0, 30.0, 28.0, 28.0, 26.0, 30.0, 35.0], "caption": "Temperature, every 3 hours", "height": 44, "color": "orange"},
                   {"text": "Rain chance up to 4%", "font": "caption", "color": "gray"}], "title": "Next 24 hours"},
         {"card": [{"row": [{"text": "Today", "icon": "sun.max.fill"}, {"text": "26° – 35° · Sunny", "color": "gray", "lines": 1}]},
                   {"row": [{"text": "Tomorrow", "icon": "cloud.rain.fill"}, {"text": "26° – 36° · Patchy rain nearby", "color": "gray", "lines": 1}]}], "title": "Next days"}]
        """#),
    ]
    for (example, output) in outputs {
        let design = try design(of: example)
        #expect(design.board?.root.flattened.contains { $0.kind == .blocks } == true, "\(example) draws script blocks")
        let parsed = SpriteSpecFormat.scriptBlocks(output, design: design, directory: "/tmp/sprite")
        #expect(parsed.diagnostics.isEmpty, "\(example): \(parsed.diagnostics.map(\.description).joined(separator: "\n"))")
        #expect(!parsed.blocks.isEmpty, "\(example) drew nothing")
    }
}
