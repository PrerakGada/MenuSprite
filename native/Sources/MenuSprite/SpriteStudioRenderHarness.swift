import AppKit
import SpriteSpec
import SwiftUI
import SystemMonitoring

/// Draws sprites and the sprite studio to PNG files without showing anything or saving a change.
///
///     MenuSprite --sprite-studio-render <dir> [--from <monitoring.json>] [--wait <seconds>]
///
/// It works on a copy of the saved sprites (Prerak's own by default) inside `<dir>`, samples once,
/// and writes `compare.png`: every sprite as the old settings drew it beside its converted design,
/// on a dark and a light bar, with the width and differing-pixel count in `report.txt`.
@MainActor
enum SpriteStudioRenderHarness {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--sprite-studio-render"), arguments.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1])
        let wait = arguments.firstIndex(of: "--wait").flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil } ?? 3
        NSApplication.shared.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = arguments.firstIndex(of: "--from").flatMap { arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MenuSprite/monitoring.json")
        let copy = directory.appendingPathComponent("render-monitoring.json")
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.copyItem(at: source, to: copy)
        let store = MonitoringStore(configurationURL: copy)
        Task { @MainActor in
            _ = await store.sampleAllForValidation()
            try? await Task.sleep(for: .seconds(wait))
            _ = await store.sampleAllForValidation()
            if !arguments.contains("--live-ai") {
                store.injectReadingsForValidation(["ai.claude.session": Reading(42), "ai.claude.weekly": Reading(67),
                                                   "ai.codex.weekly": Reading(8), "ai.codex.session": Reading(100)])
            }
            var report: [String] = []
            writeComparison(store: store, to: directory.appendingPathComponent("compare.png"), report: &report)
            await writeStudio(store: store, directory: directory, report: &report)
            await writeBoards(store: store, directory: directory, report: &report)
            for (label, source) in [
                ("number", CommandSource(command: "echo 'load: 42.5 items'", output: .number)),
                ("json", CommandSource(command: "echo '{\"data\":{\"items\":[{\"n\":7}]}}'", output: .json, path: "data.items.0.n")),
                ("text", CommandSource(command: "printf 'first line\\nsecond'", output: .text)),
                ("timeout", CommandSource(command: "sleep 30; echo late", timeout: 1)),
                ("runaway", CommandSource(command: "yes", timeout: 10)),
                ("failure", CommandSource(command: "echo nope >&2; exit 3"))
            ] {
                let result = await CommandVariableRunner.execute(source.normalized)
                report.append("command \(label): text \(result.text ?? "nil") number \(result.number.map { String($0) } ?? "nil") problem \(result.problem ?? "none") in \(String(format: "%.2f", result.elapsed)) s")
            }
            try? report.joined(separator: "\n").write(to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            print(report.joined(separator: "\n"))
            exit(0)
        }
        NSApplication.shared.run()
    }

    private static let scale: CGFloat = 4

    /// The window with a sprite open in the studio, and the studio alone with a piece selected.
    static func writeStudio(store: MonitoringStore, directory: URL, report: inout [String]) async {
        let names = ["RAM", "Weekly AI usage", "Network"]
        for (index, name) in names.enumerated() {
            guard let config = store.sprites.first(where: { $0.name == name }) ?? store.sprites.first else { continue }
            for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] where index == 0 || suffix == "dark" {
                let model = StudioModel(config: config, store: store)
                // Select the first piece that shows a value, as a click on the canvas would.
                model.selection = model.design.root.flattened.first { $0.kind == .text && !$0.referencedVariables.isEmpty }?.id
                let view = HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(store.sprites) { sprite in
                            VStack(alignment: .leading, spacing: 5) {
                                MenuBarChip(config: sprite, store: store)
                                Text(sprite.name).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .padding(8).frame(width: 250, alignment: .leading)
                            .background(sprite.id == config.id ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                        Spacer()
                    }.padding(8).frame(width: 270)
                    Divider()
                    SpriteStudio(model: model, store: store, close: {})
                }
                .frame(width: 1400, height: 900)
                .background(Color(nsColor: .windowBackgroundColor))
                let url = directory.appendingPathComponent("studio-\(index)-\(suffix).png")
                await snapshot(view, appearance: appearance, size: NSSize(width: 1400, height: 900), to: url)
                model.close()
                report.append("studio \(name) \(suffix) → \(url.lastPathComponent)")
            }
        }
    }

    /// Board mode in the studio (RAM's board started from its classic panel) and a showcase board
    /// drawn exactly as the click-open panel draws it.
    static func writeBoards(store: MonitoringStore, directory: URL, report: inout [String]) async {
        guard let ram = store.sprites.first(where: { $0.name == "RAM" }) ?? store.sprites.first,
              let cpu = store.sprites.first(where: { $0.name == "CPU" }) ?? store.sprites.first else { return }
        var ramBoard = ram
        ramBoard.design?.board = BoardDesign.starter(for: ram)
        let model = StudioModel(config: ramBoard, store: store)
        model.showingBoard = true
        model.boardSelection = model.design.board?.root.children.last?.id
        let studio = SpriteStudio(model: model, store: store, close: {}).frame(width: 1400, height: 900)
        await snapshot(studio, appearance: .darkAqua, size: NSSize(width: 1400, height: 900), to: directory.appendingPathComponent("board-studio-ram.png"))
        model.close()
        report.append("board studio RAM → board-studio-ram.png")

        var showcase = cpu
        var design = showcase.design ?? SpriteDesign()
        let cpuID = design.variables.first?.id ?? "cpu"
        design.variables.append(SpriteVariable(id: "uptime", name: "Uptime", source: .command(CommandSource(command: "uptime | sed 's/.*up \\([^,]*\\),.*/\\1/'", interval: 60))))
        var huge = BoardBlock(kind: .value, name: "Now", variable: cpuID); huge.style.textStyle = .huge
        let gauge = BoardBlock(kind: .gauge, name: "Gauge", variable: cpuID)
        var card = BoardBlock(kind: .card, name: "Card", children: [BoardBlock(kind: .row, children: [huge, gauge])], segments: [.literal("CPU right now")])
        card.style.spacing = 8
        var chart = BoardBlock(kind: .chart, name: "Chart", variable: cpuID); chart.style.height = 40
        let stats = BoardBlock(kind: .stats, name: "Stats", variables: [cpuID, "uptime"])
        let script = BoardBlock(kind: .script, name: "Script", command: CommandSource(command: """
        echo "Homebrew | sfimage=mug color=orange"
        echo "--$(ls /opt/homebrew/Cellar 2>/dev/null | wc -l | tr -d ' ') formulae installed | font=Menlo"
        echo "---"
        echo "Open the MenuSprite site | href=https://menusprite.prerakgada.in sfimage=safari"
        """, interval: 60))
        let button = BoardBlock(kind: .button, name: "Button", segments: [.literal("Show top CPU process")], symbol: "terminal",
                                action: BoardAction(kind: .runCommand, value: "ps -Ao comm,%cpu -r | sed -n 2p"))
        var list = BoardBlock(kind: .processes, name: "Processes"); list.style.processKind = .cpu; list.style.limit = 5
        design.board = BoardDesign(root: .stack([card, chart, stats, BoardBlock(kind: .divider), script, button, list], spacing: 12), width: 380)
        showcase.design = design
        store.preview(design: design)
        store.openBoard(showcase.id)
        for command in design.commandVariables.compactMap(\.command) + design.boardScriptCommands { await store.commands.run(command) }
        let live = BoardView(config: showcase, environment: BoardEnvironment(monitoring: store, power: nil))
            .background(Color(nsColor: .windowBackgroundColor))
        await snapshot(live.frame(width: 380, height: 860, alignment: .top), appearance: .darkAqua,
                       size: NSSize(width: 380, height: 860), to: directory.appendingPathComponent("board-live-showcase.png"))
        store.closeBoard(showcase.id); store.preview(design: nil)
        report.append("board live showcase → board-live-showcase.png")
        await writeNewBlocks(store: store, base: cpu, directory: directory, report: &report)
        await writeAgentBlocks(store: store, base: cpu, directory: directory, report: &report)
        writeFaceOpacity(store: store, base: cpu, to: directory.appendingPathComponent("face-opacity.png"), report: &report)
    }

    /// What agents asked for in their trials, in one board: gauges and switches that show their colour
    /// off-screen (this window is never key), clickable rows and links, text cut to a line, a row whose
    /// figure takes its natural width, script rows with weight, length and adaptive colours, and a script
    /// row and script block that fail with the end of their stderr.
    static func writeAgentBlocks(store: MonitoringStore, base: SpriteConfiguration, directory: URL, report: inout [String]) async {
        var showcase = base
        var design = showcase.design ?? SpriteDesign()
        design.variables += [
            SpriteVariable(id: "disk", name: "Disk", source: .constant(text: "72")),
            SpriteVariable(id: "on", name: "On", source: .constant(text: "on")),
            SpriteVariable(id: "off", name: "Off", source: .constant(text: "off")),
            SpriteVariable(id: "count", name: "Count", source: .constant(text: "1,284"))
        ]
        func gauge(_ caption: String, color: String) -> BoardBlock {
            var block = BoardBlock(kind: .gauge, name: caption, segments: [.literal(caption)], variable: "disk")
            block.style.color = color; return block
        }
        let gauges = BoardBlock(kind: .card, name: "Gauges", children: [gauge("Accent (no colour)", color: "inherit"), gauge("teal", color: "teal"),
                                                                        gauge("#FF453A", color: "FF453A")], segments: [.literal("Gauges")])
        func toggle(_ title: String, value: String, color: String) -> BoardBlock {
            var block = BoardBlock(kind: .toggle, name: title, segments: [.literal(title)], variable: value, symbol: "power",
                                   action: BoardAction(value: "true"), offAction: BoardAction(value: "true"))
            block.style.color = color; return block
        }
        let switches = BoardBlock(kind: .card, name: "Switches", children: [toggle("On, accent", value: "on", color: "inherit"),
                                                                            toggle("On, orange", value: "on", color: "orange"),
                                                                            toggle("Off", value: "off", color: "orange")], segments: [.literal("Switches")])
        var link = BoardBlock.text("A clickable row that opens a link", style: .body)
        link.symbol = "link"; link.action = BoardAction(kind: .openURL, value: "https://menusprite.prerakgada.in")
        var pr = BoardBlock(kind: .stack, children: [BoardBlock.text("#327 Fix the long name wrapping in rows", style: .headline),
                                                    BoardBlock.text("opened 2 h ago by prerak", style: .caption)], style: { var s = BoardStyle(); s.spacing = 2; return s }())
        pr.action = BoardAction(kind: .openURL, value: "https://github.com")
        var run = BoardBlock.text("A clickable row that runs a command", style: .body)
        run.symbol = "play.circle"; run.action = BoardAction(kind: .runCommand, value: "echo ran")
        var cut = BoardBlock.text("2f9c1e7a-4b6d-4c1e-9a8f-0b2d3c4e5f60-compose-service-web-1", style: .mono)
        cut.style.lines = 1; cut.style.truncate = .middle
        var name = BoardBlock.text("SBMP-Canteen-Cookbook/hungrybrain_monorepo-worktrees/zeptomail", style: .body)
        name.style.lines = 1
        var figure = BoardBlock.text("{count} files", style: .headline); figure.segments = [.value("count"), .literal(" files")]
        figure.style.fit = true; figure.style.align = .trailing
        let fitRow = BoardBlock(kind: .row, name: "Fit row", children: [name, figure])
        var named = BoardBlock.text("Teal fill by name", style: .caption); named.style.background = "teal"
        let rows = BoardBlock(kind: .script, name: "Script rows", command: CommandSource(command: """
        echo "Section header | weight=bold"
        echo "Helvetica-Bold header | font=Helvetica-Bold color=orange"
        echo "A very long pull request title that would wrap onto a second line | length=40 href=https://github.com"
        echo "Adaptive green | color=green sfimage=checkmark.circle.fill"
        echo "Runs a command | bash='echo hi' sfimage=terminal"
        """, interval: 60))
        let failing = BoardBlock(kind: .script, name: "Failing rows", command: CommandSource(command: """
        echo "Partial row before the failure"
        printf 'Traceback (most recent call last):\\n  File "prs.py", line 12, in <module>\\n    raise SystemExit(done.stderr.strip().splitlines()[0] if done.stderr else "gh failed and said nothing at all about why")\\nSystemExit: gh: authentication token expired (run gh auth login)\\n' >&2
        exit 1
        """, interval: 60))
        let failingBlocks = BoardBlock(kind: .blocks, name: "Failing blocks", command: CommandSource(command: """
        python3 -c 'raise ValueError("rate limited until 14:05")'
        """, interval: 60))
        design.board = BoardDesign(root: .stack([gauges, switches, link, pr, run, cut, fitRow, named, BoardBlock(kind: .divider), rows,
                                                 BoardBlock(kind: .divider), failing, failingBlocks], spacing: 12), width: 380)
        showcase.design = design
        store.preview(design: design)
        store.openBoard(showcase.id)
        try? await Task.sleep(for: .milliseconds(400))
        for command in design.boardScriptCommands { await store.commands.run(command) }
        for (suffix, appearance) in [("", NSAppearance.Name.darkAqua), ("-light", .aqua)] {
            let live = BoardView(config: showcase, environment: BoardEnvironment(monitoring: store, power: nil))
                .background(Color(nsColor: .windowBackgroundColor))
            let name = "board-agent-blocks\(suffix).png"
            await snapshot(live.frame(width: 380, height: 1260, alignment: .top), appearance: appearance,
                           size: NSSize(width: 380, height: 1260), to: directory.appendingPathComponent(name))
            report.append("board agent blocks → \(name)")
        }
        store.closeBoard(showcase.id); store.preview(design: nil)

        // The inspector with a clickable text selected: lines, icon and its click action.
        let model = StudioModel(config: showcase, store: store)
        model.showingBoard = true
        model.boardSelection = run.id
        await snapshot(SpriteStudio(model: model, store: store, close: {}).frame(width: 1400, height: 1500), appearance: .darkAqua,
                       size: NSSize(width: 1400, height: 1500), to: directory.appendingPathComponent("board-studio-clickable.png"))
        model.boardSelection = figure.id
        await snapshot(SpriteStudio(model: model, store: store, close: {}).frame(width: 1400, height: 1500), appearance: .darkAqua,
                       size: NSSize(width: 1400, height: 1500), to: directory.appendingPathComponent("board-studio-fit.png"))
        model.close()
        report.append("board studio clickable → board-studio-clickable.png, fit → board-studio-fit.png")
    }

    /// The same face with its whole row at full opacity and at 0.35: a container's opacity reaches its pieces.
    static func writeFaceOpacity(store: MonitoringStore, base: SpriteConfiguration, to url: URL, report: inout [String]) {
        let height = NSStatusBar.system.thickness
        var faded = base.design ?? SpriteDesign()
        faded.root.style.opacity = 0.35
        guard let full = store.renderDesign(base, design: base.design ?? SpriteDesign(), height: height),
              let dim = store.renderDesign(base, design: faded, height: height) else { return }
        let size = NSSize(width: (full.size.width + dim.size.width) * scale + 60, height: height * scale + 20)
        let picture = NSImage(size: size, flipped: false) { rect in
            NSColor(white: 0.1, alpha: 1).setFill(); rect.fill()
            tinted(full.image, dark: true).draw(in: NSRect(x: 20, y: 10, width: full.size.width * scale, height: height * scale))
            tinted(dim.image, dark: true).draw(in: NSRect(x: 40 + full.size.width * scale, y: 10, width: dim.size.width * scale, height: height * scale))
            return true
        }
        guard let tiff = picture.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        report.append("face opacity: full signature \(full.signature.suffix(40)) · faded \(dim.signature.suffix(40)) → \(url.lastPathComponent)")
    }

    /// The blocks agents lean on: a command that prints blocks (literal gauge, value, chart and stats, and
    /// a button), an image a script wrote, switches, detail lines, fills, and a command value's chart.
    static func writeNewBlocks(store: MonitoringStore, base: SpriteConfiguration, directory: URL, report: inout [String]) async {
        let scratch = directory.appendingPathComponent("new-blocks", isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let picture = scratch.appendingPathComponent("picture.png")
        writePicture(to: picture)

        var showcase = base
        var design = showcase.design ?? SpriteDesign()
        let cpuID = design.variables.first { $0.readingID == "cpu.usage" }?.id ?? design.variables.first?.id ?? "cpu"
        var load = CommandSource(command: "echo $(( RANDOM % 40 + 20 ))", interval: 2, output: .number)
        load.directory = scratch.path
        design.variables += [
            SpriteVariable(id: "used", name: "Used", source: .constant(text: "9.4 GB")),
            SpriteVariable(id: "limit", name: "Limit", source: .constant(text: "16 GB")),
            SpriteVariable(id: "memory", name: "Memory", source: .constant(text: "58.75")),
            SpriteVariable(id: "focus", name: "Focus", source: .constant(text: "off")),
            SpriteVariable(id: "vpn", name: "VPN", source: .command(CommandSource(command: "echo Connected", interval: 30))),
            SpriteVariable(id: "load", name: "Load", source: .command(load))
        ]

        var value = BoardBlock(kind: .value, name: "Now", variable: cpuID, detail: [.literal("across "), .value("used")])
        value.segments = [.literal("CPU")]
        var gauge = BoardBlock(kind: .gauge, name: "Memory", segments: [.literal("Memory")], variable: "memory",
                               detail: [.value("used"), .literal(" of "), .value("limit")])
        gauge.style.color = "30D158"
        var card = BoardBlock(kind: .card, name: "Filled card", children: [BoardBlock(kind: .row, children: [value, gauge])],
                              segments: [.literal("Fill and detail")])
        card.style.background = "1E3A5F"; card.style.spacing = 8
        var chart = BoardBlock(kind: .chart, name: "Command chart", segments: [.literal("Load (a command value)")], variable: "load")
        chart.style.height = 36
        let vpn = BoardBlock(kind: .toggle, name: "VPN", segments: [.literal("VPN")], variable: "vpn", symbol: "lock.shield",
                             action: BoardAction(kind: .runCommand, value: "echo up"), offAction: BoardAction(kind: .runCommand, value: "echo down"))
        let focus = BoardBlock(kind: .toggle, name: "Focus", segments: [.literal("Focus")], variable: "focus", symbol: "moon",
                               action: BoardAction(kind: .runCommand, value: "true"), offAction: BoardAction(kind: .runCommand, value: "true"))
        var image = BoardBlock(kind: .image, name: "Picture", source: picture.path); image.style.height = 90
        var missing = BoardBlock(kind: .image, name: "Missing", source: "not-written-yet.png"); missing.style.height = 56
        var note = BoardBlock.text("Yellow fill, so the text turns black", style: .caption); note.style.background = "FFD60A"
        var printed = CommandSource(command: """
        cat <<JSON
        {"blocks": [
          {"card": [
            {"row": [{"value": "12.4 GB", "caption": "Cache"}, {"gauge": 62, "caption": "Quota", "detail": "62 of 100"}]},
            {"chart": [3, 5, 2, 8, 6, 9, 7, 11], "caption": "Builds per day", "height": 36},
            {"stats": [{"name": "Open", "value": 3}, {"name": "Merged", "value": 12}, "\(cpuID)"]}
          ], "title": "Printed by a script", "background": "#2C2C2E"},
          {"row": [{"image": "picture.png", "height": 48}, {"toggle": "Printed switch", "value": true, "on": "true", "off": "true"}]},
          {"text": "CPU now {\(cpuID)} · from $PWD", "font": "caption"},
          {"text": "A printed row that opens a link", "open": "https://menusprite.prerakgada.in"},
          {"button": "Say hello", "icon": "hand.wave", "run": "echo hello"}
        ]}
        JSON
        """, interval: 30)
        printed.directory = scratch.path
        let blocks = BoardBlock(kind: .blocks, name: "Script blocks", command: printed)
        design.board = BoardDesign(root: .stack([card, chart, vpn, focus, image, missing, note, BoardBlock(kind: .divider), blocks], spacing: 12), width: 380)
        showcase.design = design
        store.preview(design: design)
        store.openBoard(showcase.id)
        // Let the store's demand settle first, so the runs below land where the board looks.
        try? await Task.sleep(for: .milliseconds(400))
        for _ in 0..<8 { await store.commands.run(load) }
        for command in design.commandVariables.compactMap(\.command) + design.boardScriptCommands { await store.commands.run(command) }
        let output = store.commands.result(for: printed)?.output ?? ""
        let parsed = SpriteSpecFormat.scriptBlocks(output, design: design, directory: scratch.path)
        report.append("script blocks: \(parsed.blocks.count) blocks, \(parsed.variables.count) literal values, diagnostics \(parsed.diagnostics.map(\.description))")
        report.append("load history: \(store.commands.points(for: load).map { BoardChartSeries.compact($0.value) }.joined(separator: " "))")
        for (suffix, appearance) in [("", NSAppearance.Name.darkAqua), ("-light", .aqua)] {
            let live = BoardView(config: showcase, environment: BoardEnvironment(monitoring: store, power: nil))
                .background(Color(nsColor: .windowBackgroundColor))
            let name = "board-new-blocks\(suffix).png"
            await snapshot(live.frame(width: 380, height: 1180, alignment: .top), appearance: appearance,
                           size: NSSize(width: 380, height: 1180), to: directory.appendingPathComponent(name))
            report.append("board new blocks → \(name)")
        }
        store.closeBoard(showcase.id); store.preview(design: nil)

        // The studio's inspector for each new kind, with the block selected as a click would.
        for (label, selected) in [("switch", vpn.id), ("script-blocks", blocks.id), ("image", image.id), ("fill", note.id)] {
            let model = StudioModel(config: showcase, store: store)
            model.showingBoard = true
            model.boardSelection = selected
            // Tall enough that the inspector shows its Look section without scrolling.
            let studio = SpriteStudio(model: model, store: store, close: {}).frame(width: 1400, height: 1500)
            await snapshot(studio, appearance: .darkAqua, size: NSSize(width: 1400, height: 1500),
                           to: directory.appendingPathComponent("board-studio-\(label).png"))
            model.close()
            report.append("board studio \(label) → board-studio-\(label).png")
        }

        // Where commands run: the sprite's folder with SPRITE_DIR, else home; Homebrew and user bins first on PATH.
        for (label, source) in [
            ("in folder", CommandSource(command: "pwd; echo \"$SPRITE_DIR\"", directory: scratch.path)),
            ("no folder", CommandSource(command: "pwd; echo \"[${SPRITE_DIR}]\"", directory: scratch.appendingPathComponent("absent").path)),
            ("path", CommandSource(command: "echo $PATH | tr ':' ' '"))
        ] {
            let result = await CommandVariableRunner.execute(source.normalized, parse: false)
            report.append("command \(label): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " | ")) \(result.problem ?? "")")
        }
        let quiet = await CommandVariableRunner.execute(CommandSource(command: "true").normalized, parse: false)
        report.append("action printing nothing: problem \(quiet.problem ?? "none"), status \(quiet.status.map(String.init) ?? "nil")")
    }

    /// A small gradient PNG standing in for a chart a script drew.
    static func writePicture(to url: URL) {
        let size = NSSize(width: 320, height: 120)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(starting: NSColor(calibratedRed: 0.36, green: 0.27, blue: 0.86, alpha: 1),
                       ending: NSColor(calibratedRed: 0.18, green: 0.82, blue: 0.62, alpha: 1))?.draw(in: rect, angle: 0)
            let bars: [CGFloat] = [0.3, 0.55, 0.42, 0.8, 0.65, 0.9, 0.5]
            NSColor.white.withAlphaComponent(0.85).setFill()
            for (index, height) in bars.enumerated() {
                NSBezierPath(roundedRect: NSRect(x: 24 + CGFloat(index) * 40, y: 14, width: 24, height: (rect.height - 40) * height),
                             xRadius: 4, yRadius: 4).fill()
            }
            ("PNG written by a script" as NSString).draw(at: NSPoint(x: 14, y: rect.height - 22), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func snapshot<V: View>(_ view: V, appearance: NSAppearance.Name, size: NSSize, to url: URL) async {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(2500))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.contentView = nil
    }

    static func writeComparison(store: MonitoringStore, to url: URL, report: inout [String]) {
        let height = NSStatusBar.system.thickness
        var rows: [(String, NSImage, NSImage)] = []
        for config in store.sprites where config.enabled {
            let icon: ReadoutIcon = config.isBatteryItem ? .battery(store.batteryGlyph(ceiling: nil, for: config)) : .symbol(config.symbol)
            let old = StackedReadout.image(columns: store.menuColumns(config), config: config, height: height, icon: icon)
            let design = config.design ?? SpriteDesign.migrated(from: config, metric: store.knownMetric)
            guard let new = store.renderDesign(config, design: design, height: height) else { continue }
            rows.append((config.name, old, new.image))
            let dark = difference(old, new.image, dark: true), light = difference(old, new.image, dark: false)
            report.append("\(config.name): old \(Int(old.size.width)) pt, new \(Int(new.size.width)) pt · differing pixels dark \(dark), light \(light) · “\(store.designText(design))”")
        }
        let nameWidth: CGFloat = 170
        let column = (rows.map { max($0.1.size.width, $0.2.size.width) }.max() ?? 60) * scale + 30
        let rowHeight = height * scale + 16
        let size = NSSize(width: nameWidth + column * 4, height: 30 + rowHeight * CGFloat(rows.count))
        let picture = NSImage(size: size, flipped: true) { _ in
            NSColor(white: 0.18, alpha: 1).setFill(); NSRect(origin: .zero, size: size).fill()
            let header: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
            for (index, title) in ["old · dark", "new · dark", "old · light", "new · light"].enumerated() {
                (title as NSString).draw(at: NSPoint(x: nameWidth + column * CGFloat(index) + 10, y: 8), withAttributes: header)
            }
            for (row, (name, old, new)) in rows.enumerated() {
                let y = 30 + rowHeight * CGFloat(row)
                (name as NSString).draw(at: NSPoint(x: 10, y: y + rowHeight / 2 - 8), withAttributes: header)
                for (index, (image, dark)) in [(old, true), (new, true), (old, false), (new, false)].enumerated() {
                    let bar = NSRect(x: nameWidth + column * CGFloat(index) + 6, y: y + 4, width: column - 12, height: height * scale)
                    (dark ? NSColor(white: 0.1, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill(); bar.fill()
                    let tile = tinted(image, dark: dark)
                    tile.draw(in: NSRect(x: bar.minX + 8, y: bar.minY, width: image.size.width * scale, height: height * scale))
                }
            }
            return true
        }
        guard let tiff = picture.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        report.append("compare → \(url.path)")
    }

    /// A template image drawn the way the menu bar would draw it on that bar.
    static func tinted(_ image: NSImage, dark: Bool) -> NSImage {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        return NSImage(size: image.size, flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                image.draw(in: rect)
                if image.isTemplate { (dark ? NSColor.white : NSColor.black).set(); rect.fill(using: .sourceAtop) }
            }
            return true
        }
    }

    /// Pixels that differ noticeably between the two drawings at 2×, over the wider of the two.
    static func difference(_ a: NSImage, _ b: NSImage, dark: Bool) -> Int {
        let width = Int(ceil(max(a.size.width, b.size.width) * 2)), height = Int(ceil(max(a.size.height, b.size.height) * 2))
        func pixels(_ image: NSImage) -> NSBitmapImageRep? {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            (dark ? NSColor(white: 0.1, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSRect(x: 0, y: 0, width: CGFloat(width) / 2, height: CGFloat(height) / 2).fill()
            NSGraphicsContext.current?.cgContext.scaleBy(x: 2, y: 2)
            tinted(image, dark: dark).draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        guard let left = pixels(a), let right = pixels(b) else { return -1 }
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                guard let p = left.colorAt(x: x, y: y), let q = right.colorAt(x: x, y: y) else { continue }
                if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent) + abs(p.blueComponent - q.blueComponent) > 0.3 { count += 1 }
            }
        }
        return count
    }
}
