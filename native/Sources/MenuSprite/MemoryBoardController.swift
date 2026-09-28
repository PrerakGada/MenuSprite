import AppKit
import Combine
import SystemMonitoring

/// One native scrolling drawing surface, instead of a compositing surface for
/// each row. Ordinary NSButtons retain keyboard/VoiceOver behavior for actions.
@MainActor
final class MemoryBoardController: NSViewController {
    private let monitoring: MonitoringStore
    private let processes: MemoryBoardStore
    private let id: UUID
    private let configure: () -> Void
    private let close: () -> Void
    private var subscriptions: Set<AnyCancellable> = []
    private var document: MemoryDocumentView!
    private var scroll: NSScrollView!
    private var pending = false
    private var wasEnabled: Bool
    private var enableButton: NSButton!
    init(monitoring: MonitoringStore, processes: MemoryBoardStore, id: UUID, configure: @escaping () -> Void, close: @escaping () -> Void) {
        self.monitoring = monitoring; self.processes = processes; self.id = id; self.configure = configure; self.close = close
        wasEnabled = monitoring.sprites.first { $0.id == id }?.enabled == true
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let root = MemoryPanelBackground(frame: NSRect(x: 0, y: 0, width: 400, height: 780))
        view = root
        let heading = NSTextField(labelWithString: processes.kind.title)
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        let symbol = NSImageView(image: NSImage(systemSymbolName: processes.kind.symbol, accessibilityDescription: nil)!)
        symbol.contentTintColor = MemoryDocumentView.accent
        let refresh = iconButton("arrow.clockwise", label: "Refresh \(processes.kind.title)", action: #selector(refreshMemory))
        let dismiss = iconButton("xmark", label: "Close \(processes.kind.title) panel", action: #selector(dismissPanel))
        scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .none
        document = MemoryDocumentView(monitoring: monitoring, processes: processes, id: id)
        scroll.documentView = document
        let settings = NSButton(title: "Settings", image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)!, target: self, action: #selector(settings))
        let quit = NSButton(title: "Quit", image: NSImage(systemSymbolName: "power", accessibilityDescription: nil)!, target: self, action: #selector(quitApp))
        let activity = iconButton("arrow.up.forward.app", label: "Open Activity Monitor", action: #selector(activityMonitor))
        for button in [settings, quit] {
            button.isBordered = false; button.controlSize = .small; button.imagePosition = .imageLeft
            button.wantsLayer = true; button.layer?.cornerRadius = 6
            button.layer?.backgroundColor = NSColor(calibratedWhite: root.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.20 : 0.90, alpha: 1).cgColor
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        let line = NSBox(); line.boxType = .separator
        enableButton = NSButton(title: "Enable sprite", target: self, action: #selector(enableSprite)); enableButton.bezelStyle = .rounded
        for subview in [heading, symbol, refresh, dismiss, scroll!, settings, quit, activity, line, enableButton!] {
            subview.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), symbol.topAnchor.constraint(equalTo: root.topAnchor, constant: 17), symbol.widthAnchor.constraint(equalToConstant: 16), symbol.heightAnchor.constraint(equalToConstant: 16),
            heading.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 8), heading.centerYAnchor.constraint(equalTo: symbol.centerYAnchor),
            dismiss.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12), dismiss.centerYAnchor.constraint(equalTo: heading.centerYAnchor), dismiss.widthAnchor.constraint(equalToConstant: 22),
            refresh.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor, constant: -8), refresh.centerYAnchor.constraint(equalTo: heading.centerYAnchor), refresh.widthAnchor.constraint(equalToConstant: 22),
            activity.trailingAnchor.constraint(equalTo: refresh.leadingAnchor, constant: -8), activity.centerYAnchor.constraint(equalTo: heading.centerYAnchor), activity.widthAnchor.constraint(equalToConstant: 22),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 50), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: line.topAnchor, constant: -6),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor), line.trailingAnchor.constraint(equalTo: root.trailingAnchor), line.bottomAnchor.constraint(equalTo: settings.topAnchor, constant: -10),
            settings.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), settings.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            quit.leadingAnchor.constraint(equalTo: settings.trailingAnchor, constant: 8), quit.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12), quit.widthAnchor.constraint(equalTo: settings.widthAnchor), quit.centerYAnchor.constraint(equalTo: settings.centerYAnchor),
            enableButton.centerXAnchor.constraint(equalTo: root.centerXAnchor), enableButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 100)
        ])
        monitoring.objectWillChange.sink { [weak self] _ in self?.queueUpdate() }.store(in: &subscriptions)
        processes.objectWillChange.sink { [weak self] _ in self?.queueUpdate() }.store(in: &subscriptions)
        updateContents()
    }
    override func viewDidLayout() { super.viewDidLayout(); document?.frame.size.width = scroll.contentSize.width }
    private func queueUpdate() {
        guard !pending else { return }; pending = true
        DispatchQueue.main.async { [weak self] in self?.pending = false; self?.updateContents() }
    }
    private func updateContents() {
        let enabled = monitoring.sprites.first { $0.id == id }?.enabled == true
        if wasEnabled != enabled { wasEnabled = enabled; if enabled { processes.start() } else { processes.stop() } }
        enableButton.isHidden = enabled
        document.frame.size = NSSize(width: scroll.contentSize.width, height: document.requiredHeight)
        document.refreshAccessibilityAndTooltips()
        document.needsDisplay = true
    }
    private func iconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.isBordered = false; button.toolTip = label; button.setAccessibilityLabel(label); return button
    }
    @objc private func refreshMemory() { monitoring.refresh(); if wasEnabled { processes.refresh() } }
    @objc private func dismissPanel() { close() }
    @objc private func settings() { configure() }
    @objc private func enableSprite() { monitoring.setEnabled(id, true) }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func activityMonitor() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"), configuration: .init())
    }
}

@MainActor
private final class MemoryDocumentView: NSView {
    static let accent = NSColor(red: 0.13, green: 0.79, blue: 0.72, alpha: 1)
    private let monitoring: MonitoringStore
    private let processes: MemoryBoardStore
    private let id: UUID
    private var tips: [NSView.ToolTipTag: String] = [:]
    private var accessibleRows: [(String, NSRect)] = []
    private var accessibleElements: [MemoryAccessibleText] = []
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    private var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    private var enabled: Bool { monitoring.sprites.first { $0.id == id }?.enabled == true }
    private var consumers: [ProcessConsumerRate] { Array(processes.ranked.prefix(30)) }
    private var content: ProcessBoardContent { .init(kind: processes.kind, monitoring: monitoring, processes: processes) }
    private var listStartY: CGFloat { processes.kind == .memory ? 394 : 418 }
    private var laidOutRows: [(row: ProcessConsumerRate, y: CGFloat, height: CGFloat, indent: CGFloat)] {
        var y = listStartY
        return processes.visibleRows(limit: 30).map { item in
            let height: CGFloat = item.row.consumer.presentation.subtitle == nil ? 26 : 42
            defer { y += height }
            return (item.row, y, height, CGFloat(item.depth) * 18)
        }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The whole grouped row opens it, not only its small trailing chevron.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if enabled, let item = laidOutRows.first(where: { !$0.row.members.isEmpty && NSRect(x: 12, y: $0.y, width: bounds.width - 24, height: $0.height).contains(point) }) {
            processes.toggle(item.row.id); return
        }
        super.mouseDown(with: event)
    }
    private var rowsEnd: CGFloat { laidOutRows.last.map { $0.y + $0.height } ?? (listStartY + 40) }
    var requiredHeight: CGFloat { enabled ? rowsEnd + 72 : 140 }
    init(monitoring: MonitoringStore, processes: MemoryBoardStore, id: UUID) {
        self.monitoring = monitoring; self.processes = processes; self.id = id
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("\(processes.kind.title) details")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func bytes(_ id: String) -> String { MemoryBoardFormat.bytes(monitoring.readings[id]?.number) }
    private var stats: [(String, String)] { content.stats }
    private func text(_ value: String, at rect: NSRect, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, alignment: NSTextAlignment = .left, digits: Bool = false) {
        let resolved = color == .secondaryLabelColor ? NSColor(calibratedWhite: dark ? 0.68 : 0.40, alpha: 1) : color
        let style = NSMutableParagraphStyle(); style.alignment = alignment; style.lineBreakMode = .byTruncatingMiddle
        (value as NSString).draw(in: rect, withAttributes: [.font: digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: resolved, .paragraphStyle: style])
    }
    private func card(_ rect: NSRect) {
        NSColor(calibratedWhite: dark ? 0.18 : 0.94, alpha: 1).setFill(); NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11).fill()
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(calibratedWhite: dark ? 0.12 : 0.985, alpha: 1).setFill(); bounds.fill()
        let width = bounds.width - 24
        guard enabled else { text("This \(processes.kind.title) sprite is paused.", at: NSRect(x: 12, y: 16, width: width, height: 20), size: 14, color: .secondaryLabelColor, alignment: .center); return }
        card(NSRect(x: 12, y: 0, width: width, height: 126))
        let percentage = content.mainValue
        text(percentage, at: NSRect(x: 24, y: 10, width: width - 24, height: 42), size: 32, weight: .bold, digits: true)
        text(content.subtitle, at: NSRect(x: 24, y: 52, width: width - 24, height: 20), size: 13, weight: .medium, color: .secondaryLabelColor, digits: true)
        graph(in: NSRect(x: 24, y: 77, width: width - 24, height: 38))
        card(NSRect(x: 12, y: 136, width: width, height: 206))
        for (index, row) in stats.enumerated() {
            let y = 148 + CGFloat(index) * 26
            text(row.0, at: NSRect(x: 24, y: y, width: 130, height: 20), color: .secondaryLabelColor)
            if row.0 == "Pressure" {
                let color: NSColor = row.1 == "Normal" ? .systemGreen : row.1 == "Warning" ? .systemOrange : row.1 == "Critical" ? .systemRed : .secondaryLabelColor
                let pillWidth = ceil((row.1 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width) + 26
                let rect = NSRect(x: bounds.width - 24 - pillWidth, y: y - 1, width: pillWidth, height: 21)
                color.withAlphaComponent(0.12).setFill(); NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
                color.setFill(); NSBezierPath(ovalIn: NSRect(x: rect.minX + 8, y: y + 6.5, width: 7, height: 7)).fill()
                text(row.1, at: NSRect(x: rect.minX + 19, y: y, width: pillWidth - 22, height: 20), weight: .medium, color: color)
            } else { text(row.1, at: NSRect(x: 150, y: y, width: bounds.width - 174, height: 20), weight: .medium, alignment: .right, digits: true) }
        }
        card(NSRect(x: 12, y: 352, width: width, height: requiredHeight - 364))
        text(processes.kind.listTitle, at: NSRect(x: 24, y: 365, width: width - 24, height: 20), weight: .medium, color: .secondaryLabelColor)
        if processes.kind != .memory {
            let scope = processes.kind == .cpu ? "100% = one CPU core. Includes app helpers." : "CPU energy estimate; excludes GPU, display and other parts."
            text(scope, at: NSRect(x: 24, y: 388, width: width - 24, height: 18), size: 11, color: .secondaryLabelColor)
        }
        for item in laidOutRows {
            let row = item.row, consumer = row.consumer, presentation = consumer.presentation
            let y = item.y, indent = item.indent
            guard NSRect(x: 12, y: y, width: width, height: item.height).intersects(dirtyRect) else { continue }
            if indent > 0 {
                NSColor.separatorColor.setFill(); NSRect(x: 31, y: y, width: 1, height: item.height).fill()
            }
            let rect = NSRect(x: 24 + indent, y: y + 1, width: 16, height: 16)
            if let path = presentation.iconBundlePath, let icon = processes.icons[path] { icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
            else { NSImage(systemSymbolName: presentation.symbol, accessibilityDescription: nil)?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.65, respectFlipped: true, hints: nil) }
            text(presentation.title, at: NSRect(x: 48 + indent, y: y, width: bounds.width - 187 - indent, height: 20), weight: presentation.subtitle == nil ? .regular : .medium)
            if let subtitle = presentation.subtitle { text(subtitle, at: NSRect(x: 48 + indent, y: y + 19, width: bounds.width - 96 - indent, height: 17), size: 11, color: .secondaryLabelColor) }
            // A row asked to quit shows that instead of its reading: a cooperative
            // app is gone before the next sample, so a reading that has not moved
            // must not be the only thing the click appears to have done.
            if ProcessQuitArming.shared.isArmed(row.id) {
                text("quitting…", at: NSRect(x: bounds.width - 135, y: y + 1, width: 85, height: 18), size: 11, weight: .medium, color: .systemOrange, alignment: .right)
            } else {
                text(content.formatted(row), at: NSRect(x: bounds.width - 135, y: y, width: 85, height: 20), color: .secondaryLabelColor, alignment: .right, digits: true)
            }
        }
        if consumers.isEmpty {
            text(processes.loading ? "Reading processes…" : processes.emptyMessage, at: NSRect(x: 24, y: listStartY, width: width - 24, height: 40), color: .secondaryLabelColor)
        }
        let footY = rowsEnd + 4
        text(processes.kind.scope, at: NSRect(x: 24, y: footY, width: width - 24, height: 18), size: 11, color: .secondaryLabelColor)
        if let snapshot = processes.snapshot {
            let missing = snapshot.unavailableCount + max(0, snapshot.readableCount - processes.comparableCount)
            let detail = missing > 0 ? "\(missing) unavailable / awaiting interval · 5s refresh" : "Updates every 5 seconds while open"
            text(detail, at: NSRect(x: 24, y: footY + 19, width: width - 24, height: 18), size: 11, color: .secondaryLabelColor)
        }
        if let notice = processes.notice {
            text(notice, at: NSRect(x: 24, y: footY + 38, width: width - 24, height: 18), size: 11, weight: .medium, color: Self.accent)
        }
    }
    private func graph(in rect: NSRect) {
        let points = monitoring.history[processes.kind.summaryID] ?? []
        let ceiling = processes.kind == .power ? max(1, (points.map(\.value).max() ?? 1) * 1.1) : 100
        guard !points.isEmpty else { return }
        let line = NSBezierPath()
        for (index, point) in points.enumerated() {
            let p = NSPoint(x: rect.minX + rect.width * Double(index) / Double(max(1, points.count - 1)), y: rect.maxY - rect.height * min(ceiling, max(0, point.value)) / ceiling)
            if index == 0 { line.move(to: p) } else { line.line(to: p) }
        }
        let fill = line.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: points.count == 1 ? rect.minX : rect.maxX, y: rect.maxY)); fill.line(to: NSPoint(x: rect.minX, y: rect.maxY)); fill.close()
        NSGradient(starting: Self.accent.withAlphaComponent(0.22), ending: Self.accent.withAlphaComponent(0.01))?.draw(in: fill, angle: 90)
        Self.accent.setStroke(); line.lineWidth = 1.5; line.stroke()
    }
    private lazy var quitButtons = ProcessQuitButtons(processes: processes)
    private func layoutQuitButtons() {
        let rows = enabled ? laidOutRows : []
        quitButtons.layout(in: self, rows: rows.map { item in
            (item.row, NSRect(x: bounds.width - 44, y: item.y, width: 20, height: 20))
        })
    }
    func refreshAccessibilityAndTooltips() {
        layoutQuitButtons()
        defer { syncAccessibleElements() }
        removeAllToolTips(); tips = [:]; accessibleRows = []
        guard enabled else { accessibleRows = [("This \(processes.kind.title) sprite is paused", NSRect(x: 12, y: 16, width: 300, height: 20))]; return }
        accessibleRows.append(("\(processes.kind.title): \(content.mainValue)", NSRect(x: 24, y: 10, width: 300, height: 42)))
        for (index, row) in stats.enumerated() { accessibleRows.append((row.0 + ": " + row.1, NSRect(x: 24, y: 148 + CGFloat(index) * 26, width: 300, height: 20))) }
        for item in laidOutRows {
            let row = item.row, consumer = row.consumer
            let rect = NSRect(x: 24, y: item.y, width: max(0, bounds.width - 48), height: item.height)
            var label = "\(consumer.presentation.title), \(consumer.presentation.subtitle ?? "application"): \(content.formatted(row)), \(consumer.processCount) processes"
            if !row.members.isEmpty { label += processes.expanded.contains(row.id) ? ", expanded" : ", collapsed" }
            accessibleRows.append((label, rect))
            let tag = addToolTip(rect, owner: self, userData: nil)
            tips[tag] = content.tooltip(row)
        }
        toolTip = content.explanation + " Shared services may appear separately; ≥ marks a partial subtotal."
    }
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String { tips[tag] ?? "" }
    private func syncAccessibleElements() {
        accessibleElements = accessibleRows.enumerated().map { index, row in
            let element = index < accessibleElements.count ? accessibleElements[index] : MemoryAccessibleText()
            element.owner = self; element.setAccessibilityElement(true); element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel(row.0); element.setAccessibilityValue(row.0)
            element.setAccessibilityFrame(window?.convertToScreen(convert(row.1, to: nil)) ?? row.1)
            return element
        }
    }
    override func accessibilityChildren() -> [Any]? {
        for (element, row) in zip(accessibleElements, accessibleRows) {
            element.setAccessibilityFrame(window?.convertToScreen(convert(row.1, to: nil)) ?? row.1)
        }
        // The per-row quit buttons are real controls; keep them reachable.
        return (accessibleElements as [Any]) + NSAccessibility.unignoredChildren(from: subviews.filter { !$0.isHidden })
    }
}

@MainActor
private final class MemoryPanelBackground: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSColor(calibratedWhite: dark ? 0.12 : 0.985, alpha: 1).setFill(); bounds.fill()
    }
}

private final class MemoryAccessibleText: NSAccessibilityElement {
    weak var owner: NSView?
    override func accessibilityParent() -> Any? { owner }
}
