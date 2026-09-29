import AppKit
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
