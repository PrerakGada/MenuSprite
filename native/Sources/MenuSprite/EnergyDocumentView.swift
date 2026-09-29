import AppKit
import SystemMonitoring
import PowerControl

@MainActor
final class EnergyDocumentView: NSView {
    private let monitoring: MonitoringStore
    private let processes: MemoryBoardStore
    private let power: PowerStore
    var enabled = true
    var maximumAge: TimeInterval = 8
    var reducedMotion = false
    var limitExpanded = false
    var optionsExpanded = false
    var chartVisibility = [true, true, true]
    var showFlow = true
    /// Render harness only: where the limit handle sits when no limit is on.
    var previewLimit: Int?
    private var motionActive = false
    private var motionTimer: Timer?
    private var cachedFlow: EnergyFlow?
    private var cachedBreakdown: PowerBreakdown?
    private var cachedIcons: Set<String> = []
    private var cachedFlowImage: NSImage?
    private var cachedFlowSize = NSSize.zero
    private var cachedFlowDark = false
    private var renderingFlowCache = false
    private var accessibilityRows: [NSAccessibilityElement] = []
    private let violet = NSColor(red: 0.62, green: 0.48, blue: 0.98, alpha: 1)
    private let blue = NSColor(red: 0.39, green: 0.58, blue: 0.97, alpha: 1)
    private let green = NSColor(red: 0.42, green: 0.79, blue: 0.52, alpha: 1)
    private let amber = NSColor(red: 0.80, green: 0.66, blue: 0.38, alpha: 1)
    private let teal = NSColor(red: 0.38, green: 0.74, blue: 0.68, alpha: 1)
    private let barGreen = NSColor(red: 0.15, green: 0.57, blue: 0.30, alpha: 1)
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    private var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    private var muted: NSColor { NSColor(calibratedWhite: dark ? 0.69 : 0.39, alpha: 1) }
    private var foreground: NSColor { NSColor(calibratedWhite: dark ? 0.93 : 0.12, alpha: 1) }
    /// Glass: every surface is a faint wash with a hairline edge, as in AlDente.
    private var surface: NSColor { NSColor(calibratedWhite: dark ? 1 : 0, alpha: dark ? 0.065 : 0.045) }
    private var hairline: NSColor { NSColor(calibratedWhite: dark ? 1 : 0, alpha: dark ? 0.13 : 0.10) }
    /// Render harness only: a made-up flow to lay out instead of the live readings.
    var previewFlow: EnergyFlow?
    var flow: EnergyFlow { previewFlow ?? EnergyFlow(readings: monitoring.readings, maximumAge: maximumAge) }
    /// Something worth reading (a failed write, another battery app). Routine state is the bar's icons.
    private var issue: String? { power.notice ?? power.batteryControlReason }
    var limitOrigin: CGFloat { 48 + (issue == nil ? 0 : 36) }
    var optionsOrigin: CGFloat { limitOrigin + (limitExpanded ? 186 : 0) }
    var flowRect: NSRect { NSRect(x: 0, y: optionsOrigin + (optionsExpanded ? 104 : 0), width: bounds.width, height: showFlow ? flowLayout(flow, top: 0).height : 0) }
    private var appsTop: CGFloat { flowRect.maxY + (showFlow ? 8 : 0) }
    private var appsRect: NSRect {
        let layout = appsLayout
        let height: CGFloat = layout.rows.isEmpty ? 50 : layout.bottom - appsTop + 26 + (processes.notice == nil ? 0 : 17)
        return NSRect(x: 12, y: appsTop, width: bounds.width - 24, height: height)
    }
    private var chartRects: [NSRect] {
        var y = appsRect.maxY + 12
        return chartVisibility.map { visible in
            let rect = NSRect(x: 12, y: y, width: bounds.width - 24, height: visible ? 148 : 0)
            if visible { y += 160 }; return rect
        }
    }
    /// macOS's battery menu lists "Apps Using Significant Energy"; this is the CPU-energy
    /// equivalent: an app shows once it draws at least this much.
    static let significantWatts = 0.1
    /// Panel width wherever the dashboard is shown: wide enough for the flow's category pills
    /// beside the sources and the Mac (was 430 before the categories, 29 Sep).
    nonisolated static let preferredWidth: CGFloat = 560
    // MARK: Categories — where the system figure goes, and the apps list grouped the same way

    /// Info.plist facts per app bundle, read once while the dashboard lives.
    private var bundleFacts: [String: BundleFacts?] = [:]
    func category(of consumer: MemoryConsumer) -> PowerCategory {
        guard let path = consumer.bundlePath else { return PowerCategories.classify(consumer, facts: nil) }
        if bundleFacts[path] == nil { bundleFacts[path] = .some(BundleFacts.read(bundlePath: path)) }
        return PowerCategories.classify(consumer, facts: bundleFacts[path] ?? nil)
    }
    struct AppSection { let category: PowerCategory; let total: Double; let rows: [ProcessConsumerRate] }
    private struct Insight { let key: String; let breakdown: PowerBreakdown; let sections: [AppSection] }
    private var insightCache: Insight?
    /// Render harness only: a made-up breakdown to go with `previewFlow`.
    var previewBreakdown: PowerBreakdown?
    /// Rebuilt when a new process interval or new sensor figures arrive, not on every frame.
    private var insight: Insight {
        let f = flow, rows = processes.hasInterval ? processes.ranked : []
        let system: Double = f.system ?? -1, outside: Double = f.difference ?? -1
        let key = "\(processes.sampleCount)|\(rows.count)|\(system)|\(outside)"
        if let insightCache, insightCache.key == key { return insightCache }
        var totals: [PowerCategory: Double] = [:], grouped: [PowerCategory: [ProcessConsumerRate]] = [:]
        var categories: [String: PowerCategory] = [:]
        for row in rows {
            let kind = category(of: row.consumer); categories[row.id] = kind
            totals[kind, default: 0] += row.value
        }
        for row in rows.prefix(30) where row.value >= Self.significantWatts { grouped[categories[row.id] ?? .apps, default: []].append(row) }
        var sections: [AppSection] = []
        for (kind, members) in grouped { sections.append(AppSection(category: kind, total: totals[kind] ?? 0, rows: members)) }
        sections.sort { a, b in a.total == b.total ? a.category.rawValue < b.category.rawValue : a.total > b.total }
        let breakdown = PowerBreakdown.make(system: f.system, outside: f.difference, rows: rows) { categories[$0.id] ?? .apps }
        let result = Insight(key: key, breakdown: breakdown, sections: sections)
        insightCache = result; return result
    }
    var breakdown: PowerBreakdown { previewBreakdown ?? insight.breakdown }
    var appSections: [AppSection] { insight.sections }
    private struct AppsLayout {
        var headers: [(section: AppSection, y: CGFloat)] = []
        var rows: [(row: ProcessConsumerRate, y: CGFloat, height: CGFloat, indent: CGFloat)] = []
        var bottom: CGFloat
    }
    /// A header per category, its apps under it by energy, an opened group's members under the group.
    private var appsLayout: AppsLayout {
        var y = appsTop + 42, layout = AppsLayout(bottom: 0)
        for (index, section) in appSections.enumerated() {
            if index > 0 { y += 6 }
            layout.headers.append((section, y)); y += 24
            for row in section.rows {
                let items = [(row, 0)] + (processes.expanded.contains(row.id) ? row.members.map { ($0, 1) } : [])
                for (item, depth) in items {
                    let height: CGFloat = item.consumer.presentation.subtitle == nil ? 26 : 40
                    layout.rows.append((item, y, height, CGFloat(depth) * 18)); y += height
                }
            }
        }
        layout.bottom = y
        return layout
    }
    var processRowLayout: [(row: ProcessConsumerRate, y: CGFloat, height: CGFloat)] { processRows.map { ($0.row, $0.y, $0.height) } }
    private var processRows: [(row: ProcessConsumerRate, y: CGFloat, height: CGFloat, indent: CGFloat)] { appsLayout.rows }
    var requiredHeight: CGFloat { enabled ? max(appsRect.maxY, chartRects.map(\.maxY).max() ?? 0) + 18 : 155 }
    func visibleIconConsumers(in visible: NSRect) -> Set<String> {
        guard enabled else { return [] }
        var ids: Set<String> = []
        for item in processRows {
            if visible.intersects(NSRect(x: 12, y: item.y, width: appsRect.width, height: item.height)) { ids.insert(item.row.id) }
        }
        // A heavy app's pill in the flow carries its icon.
        if showFlow && visible.intersects(flowRect) {
            for entry in breakdown.entries { if case .app(let id, _, _, _) = entry.kind { ids.insert(id) } }
        }
        return ids
    }
    var isAnimating: Bool { motionTimer != nil }
    init(monitoring: MonitoringStore, processes: MemoryBoardStore, power: PowerStore) {
        self.monitoring = monitoring; self.processes = processes; self.power = power
        super.init(frame: NSRect(x: 0, y: 0, width: Self.preferredWidth, height: 1100))
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Battery and power dashboard")
    }
    required init?(coder: NSCoder) { fatalError() }
    private func text(_ value: String, _ rect: NSRect, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                      color: NSColor? = nil, alignment: NSTextAlignment = .left, digits: Bool = false, wrap: Bool = false) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment
        paragraph.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        (value as NSString).draw(in: rect, withAttributes: [.font: digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color ?? foreground, .paragraphStyle: paragraph])
    }
    private func card(_ rect: NSRect, radius: CGFloat = 18) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        surface.setFill(); path.fill()
        hairline.setStroke(); path.lineWidth = 1; path.stroke()
    }
    /// An SF Symbol fitted (not stretched) into `rect` and tinted.
    private func symbol(_ name: String, in rect: NSRect, color: NSColor? = nil, weight: NSFont.Weight = .semibold) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let image = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: rect.height * 0.85, weight: weight)) ?? base
        let size = image.size; guard size.width > 0, size.height > 0 else { return }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = NSRect(x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2, width: size.width * scale, height: size.height * scale)
        let tint = color ?? muted
        let tinted = NSImage(size: fitted.size, flipped: true) { r in
            image.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            tint.setFill(); r.fill(using: .sourceAtop); return true
        }
        tinted.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    private var controlStatus: String {
        if power.usesSystemLimit { return power.limitStatus }
        if power.snapshot.recoveryPending { return "Battery control needs recovery" }
        if !power.snapshot.helperConnected && power.snapshot.mode != .off { return "Connection lost · recovery pending" }
        switch power.snapshot.mode {
        case .off: return "MenuSprite charge control is off"
        case .maintain: return "Maintaining \(power.snapshot.band.lower)–\(power.snapshot.band.upper)%"
        case .topUp: return "Topping up to 100%"
        case .discharge: return "Discharging to \(power.snapshot.band.upper)%"
        }
    }
    // MARK: Battery bar and its draggable limit handle

    var batteryBar: NSRect { NSRect(x: 14, y: 8, width: bounds.width - 28, height: 30) }
    /// The value under the pointer while the handle is being dragged; applied on release.
    private(set) var draggingLimit: Int?
    private var limitDraggable: Bool { enabled && power.usesSystemLimit && power.canSetLimit }
    /// Where the handle sits: the drag in progress, else the saved limit; with no limit it rests at
    /// 100%, as AlDente's does, ready to be dragged down.
    private var markerValue: Int? {
        if let draggingLimit { return draggingLimit }
        if power.usesSystemLimit { return power.saverEnabled ? power.band.upper : (previewLimit ?? (limitDraggable ? 100 : nil)) }
        return power.snapshot.controlCeiling ?? power.band.upper
    }
    func limit(atX x: CGFloat) -> Int {
        let bar = batteryBar
        let raw = Int(((x - bar.minX) / bar.width * 100).rounded())
        return min(100, max(21, raw))
    }
    /// What the pack is doing, as icons after the percentage: plug (on the cable) with + charging
    /// or − draining, a sailboat while sailing, pause while a discharge is held, ↑ during Top Up.
    private var stateSymbols: [(String, String?)] {
        guard power.snapshot.pluggedIn == true else { return [] }
        let charging = (power.snapshot.chargeCurrent ?? 0) > 0 || (power.batteryAmperage ?? 0) > 50
        let draining = power.usesSystemLimit ? power.isDraining : power.snapshot.mode == .discharge
        var result: [(String, String?)] = [("powerplug.fill", charging ? "plus" : draining ? "minus" : nil)]
        if power.usesSystemLimit && power.isSailing { result.append(("sailboat.fill", nil)) }
        if power.holdLevel != nil { result.append(("pause.fill", nil)) }
        if power.topUpActive { result.append(("arrow.up.to.line", nil)) }
        return result
    }
    private func drawBatteryBar(_ current: EnergyFlow) {
        let bar = batteryBar, radius = bar.height / 2
        let track = NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius)
        surface.setFill(); track.fill()
        var filledTo = bar.minX
        if let charge = current.charge {
            let width = bar.width * CGFloat(charge) / 100
            filledTo = bar.minX + width
            let color: NSColor = charge <= 10 && power.snapshot.pluggedIn != true ? .systemRed : barGreen
            NSGraphicsContext.saveGraphicsState(); track.addClip()
            let body = NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(bar.height, width), height: bar.height), xRadius: radius, yRadius: radius)
            color.setFill(); body.fill()
            NSColor(calibratedWhite: 1, alpha: 0.16).setStroke(); body.lineWidth = 1; body.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        hairline.setStroke(); track.lineWidth = 1; track.stroke()
        let label = current.charge.map { String(format: "%.0f%%", $0) } ?? "—"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        let labelWidth = ceil((label as NSString).size(withAttributes: [.font: font]).width) + 2
        let x = bar.minX + 18
        text(label, NSRect(x: x, y: bar.midY - 10, width: labelWidth, height: 20), size: 15, weight: .semibold,
             color: x + labelWidth <= filledTo ? .white : foreground, digits: true)
        var ix = x + labelWidth + 24
        for (name, overlay) in stateSymbols {
            let tint: NSColor = ix + 16 <= filledTo ? .white : foreground
            symbol(name, in: NSRect(x: ix, y: bar.midY - 8, width: 16, height: 16), color: tint)
            ix += 15
            if let overlay { symbol(overlay, in: NSRect(x: ix, y: bar.midY - 6, width: 10, height: 10), color: tint, weight: .heavy); ix += 10 }
            ix += 14
        }
        drawLimitMarker(in: bar)
    }
    private func drawLimitMarker(in bar: NSRect) {
        guard let value = markerValue else { return }
        let x = min(bar.maxX - 5, max(bar.minX + 5, bar.minX + bar.width * CGFloat(value) / 100))
        // AlDente's handle: a light capsule standing proud of the bar.
        let live = limitDraggable || previewLimit != nil
        let handle = NSRect(x: x - 3, y: bar.minY - 5, width: 6, height: bar.height + 10)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowBlurRadius = 3; shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.45); shadow.set()
        (live ? NSColor(calibratedWhite: dark ? 0.94 : 0.30, alpha: 1) : muted).setFill()
        NSBezierPath(roundedRect: handle, xRadius: 3, yRadius: 3).fill()
        NSGraphicsContext.restoreGraphicsState()
        if let draggingLimit {
            let label = "\(draggingLimit)%", width: CGFloat = 46
            let lx = x - width - 8 >= bar.minX + 4 ? x - width - 8 : x + 8
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: lx, y: bar.minY + 5, width: width, height: 20), xRadius: 10, yRadius: 10).fill()
            text(label, NSRect(x: lx, y: bar.minY + 6, width: width, height: 18), size: 12, weight: .bold, color: .white, alignment: .center, digits: true)
        }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if limitDraggable { addCursorRect(batteryBar.insetBy(dx: 0, dy: -6), cursor: .resizeLeftRight) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard limitDraggable, batteryBar.insetBy(dx: -6, dy: -6).contains(point) else { super.mouseDown(with: event); return }
        draggingLimit = limit(atX: point.x); needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard draggingLimit != nil else { super.mouseDragged(with: event); return }
        draggingLimit = limit(atX: convert(event.locationInWindow, from: nil).x); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let value = draggingLimit else { super.mouseUp(with: event); return }
        draggingLimit = nil; needsDisplay = true
        power.setLimit(value)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: dark ? 0.11 : 0.985, alpha: 1).setFill(); dirtyRect.fill()
        guard enabled else {
            text("This power sprite is paused.", NSRect(x: 24, y: 20, width: bounds.width - 48, height: 30), weight: .semibold)
            text("Use Customize to enable it. Charts and process collection are paused.", NSRect(x: 24, y: 57, width: bounds.width - 48, height: 65), color: muted, wrap: true)
            return
        }
        let current = flow
        if dirtyRect.minY < limitOrigin {
            drawBatteryBar(current)
            if let issue {
                symbol("exclamationmark.triangle.fill", in: NSRect(x: 16, y: 50, width: 13, height: 13), color: .systemOrange)
                text(issue, NSRect(x: 35, y: 47, width: bounds.width - 51, height: 32), size: 10.5, weight: .medium, color: muted, wrap: true)
            }
        }
        if limitExpanded { card(NSRect(x: 12, y: limitOrigin, width: bounds.width - 24, height: 174)) }
        if optionsExpanded { card(NSRect(x: 12, y: optionsOrigin, width: bounds.width - 24, height: 92)) }
        for case let button as NSButton in subviews where button.tag == 900 && !button.isHidden {
            card(button.frame, radius: button.frame.height / 2)
        }
        if showFlow && flowRect.intersects(dirtyRect) { drawCachedFlow(current) }
        drawApps(dirtyRect)
        let values = [current.system, current.temperature, current.charge]
        let titles = ["Power Consumption", "Battery Temperature", "Battery Level"]
        let units = ["W", "°C", "%"]
        for index in 0..<3 where chartVisibility[index] {
            let rect = chartRects[index]
            guard rect.intersects(dirtyRect) else { continue }
            card(rect)
            text(titles[index], NSRect(x: 26, y: rect.minY + 12, width: 224, height: 24), size: 14, weight: .semibold)
            let value = values[index].map { String(format: index == 2 ? "%.0f %@" : "%.1f %@", $0, units[index]) } ?? "—"
            text(value, NSRect(x: bounds.width - 141, y: rect.minY + 8, width: 116, height: 31), size: 22, weight: .bold, alignment: .right, digits: true)
            drawChartPlot(index)
            drawChartReference(index, rect: rect, showLabel: values[index] != nil)
            let points = monitoring.history[chartIDs[index]] ?? []
            let latest = points.last.map { Int(Date().timeIntervalSince($0.time)) } ?? -1
            let time = latest >= 0 ? "\(points.count) samples · latest \(latest)s ago" : "Waiting for samples"
            text(time, NSRect(x: 26, y: rect.maxY - 20, width: 210, height: 14), size: 9, color: muted)
            if values[index] == nil {
                text("Reading unavailable", NSRect(x: bounds.width - 163, y: rect.maxY - 20, width: 136, height: 14), size: 9, color: muted, alignment: .right)
            }
        }
    }
    private let chartIDs = ["sensor.PSTR", "battery.temperature", "battery.charge"]
    private func drawCachedFlow(_ current: EnergyFlow) {
        let parts = breakdown
        let icons = Set(parts.entries.compactMap { entry -> String? in
            if case .app(_, let path?, _, _) = entry.kind, processes.icons[path] != nil { return path }; return nil
        })
        if cachedFlow != current || cachedBreakdown != parts || cachedIcons != icons || cachedFlowSize != flowRect.size || cachedFlowDark != dark || cachedFlowImage == nil {
            let scale = window?.backingScaleFactor ?? 2
            if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(flowRect.width * scale)), pixelsHigh: Int(ceil(flowRect.height * scale)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                rep.size = flowRect.size
                if let context = NSGraphicsContext(bitmapImageRep: rep) {
                    NSGraphicsContext.saveGraphicsState()
                    context.cgContext.clear(NSRect(origin: .zero, size: flowRect.size))
                    context.cgContext.translateBy(x: -flowRect.minX, y: flowRect.height + flowRect.minY)
                    context.cgContext.scaleBy(x: 1, y: -1)
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
                    renderingFlowCache = true; drawFlow(current); renderingFlowCache = false
                    NSGraphicsContext.restoreGraphicsState()
                    let image = NSImage(size: flowRect.size); image.addRepresentation(rep)
                    cachedFlowImage = image; cachedFlow = current; cachedBreakdown = parts; cachedIcons = icons; cachedFlowSize = flowRect.size; cachedFlowDark = dark
                }
            }
        }
        cachedFlowImage?.draw(in: flowRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if motionTimer != nil { drawMotion(flowLayout(current, top: flowRect.minY).ribbons) }
    }
    // MARK: Power flow (a proportional Sankey, laid out like AlDente's)

    private struct FlowNode {
        let rect: NSRect; let symbol: String; let tint: NSColor; let caption: String?
        /// Right-hand pills: a name and its watts beside the icon; an app's own icon when loaded.
        var title: String? = nil
        var detail: String? = nil
        var iconPath: String? = nil
    }
    private struct FlowRibbon {
        let start: NSPoint, end: NSPoint, width: CGFloat, from: NSColor, to: NSColor, value: Double?
        var labelAt: CGFloat = 0.5
        /// Ribbons into a pill carry no label: the pill states its watts.
        var labeled = true
        var live: Bool { (value ?? 0) > 0.05 }
        func point(_ t: CGFloat) -> NSPoint {
            let u = 1 - t, mid = (start.x + end.x) / 2
            return NSPoint(x: u*u*u*start.x + 3*u*u*t*mid + 3*u*t*t*mid + t*t*t*end.x,
                           y: u*u*u*start.y + 3*u*u*t*start.y + 3*u*t*t*end.y + t*t*t*end.y)
        }
    }
    private struct FlowLayout { let nodes: [FlowNode]; let ribbons: [FlowRibbon]; let height: CGFloat }
    /// AlDente's layout. Sources on the left, the Mac in the middle, where power goes on the right;
    /// every node is exactly as tall as the ribbons meeting it, so each wave runs cleanly into its node.
    /// - Charging: adapter → battery (above the Mac) and → Mac.
    /// - Discharging on the cable: adapter and battery stacked on the left, both merging into the Mac.
    /// - One source only: that source → Mac; an idle battery is not drawn.
    /// Out of the Mac: a pill per category of app (and one per app drawing 2 W or more), then
    /// "Display & system" — system power (`sensor.PSTR`) that app CPU energy does not account
    /// for — then Other, the measured residual (adapter − system − battery: accessories,
    /// conversion losses). Before per-app readings arrive, System and Other as before.
    private func flowLayout(_ f: EnergyFlow, top: CGFloat) -> FlowLayout {
        let minX: CGFloat = 14, width = bounds.width - 28, maxX = minX + width
        let outs = breakdown.entries
        let adapter = max(0, f.adapter ?? 0), charging = f.batteryIn ?? 0, discharging = f.batteryOut ?? 0
        // The pack's gauge reads a few tens of mA either way while macOS holds the charge (0.38 W seen at a
        // 70% hold with the adapter carrying everything). Below ~50 mA — the dead band PowerStore uses
        // for "charging" and "draining" — the battery is idle, not a source or a sink.
        let idle = 0.6
        let hasAdapter = adapter > 0.05, isCharging = hasAdapter && charging > idle, isDischarging = discharging > idle
        let toMac = hasAdapter ? max(0, adapter - (isCharging ? charging : 0)) : 0
        let macIn = toMac + (isDischarging ? discharging : 0)
        let outTotal = outs.reduce(0) { $0 + $1.watts }
        // ~1.4 pt per watt like AlDente, raised so the Mac is never a sliver, never taller than 124 pt.
        let largest = max(1, adapter, macIn, outTotal, isCharging ? charging : 0)
        let k = CGFloat(min(124 / largest, max(1.4, 44 / max(1, macIn))))
        func thick(_ v: Double) -> CGFloat { v > 0.05 ? max(1.5, CGFloat(v) * k) : 0 }
        let nodeWidth: CGFloat = 44, gap: CGFloat = 6, stack: CGFloat = 18, pad: CGFloat = 10
        let pillWidth = min(180, max(140, (width * 0.3).rounded())), pillGap: CGFloat = 5
        let hubX = (minX + width * 0.36).rounded(), outX = maxX - pillWidth
        let showAdapter = hasAdapter || (!isDischarging && f.adapter != nil && power.snapshot.pluggedIn != false)
        let showSourceBattery = isDischarging || !showAdapter
        let adapterHeight = max(30, thick(adapter))
        let sourceBatteryHeight = max(30, thick(discharging))
        let sinkBatteryHeight = max(30, thick(charging))
        let outThick = outs.map { thick($0.watts) }
        let macHeight = max(30, thick(macIn), outThick.reduce(0, +))
        let pillHeights = outThick.map { max(30, $0) }
        let left = (showAdapter ? adapterHeight : 0) + (showSourceBattery ? sourceBatteryHeight : 0) + (showAdapter && showSourceBattery ? stack : 0)
        let middle = macHeight + (isCharging ? sinkBatteryHeight + stack : 0)
        let right = pillHeights.reduce(0, +) + pillGap * CGFloat(max(0, outs.count - 1))
        let content = max(left, middle, right, 56)
        let height = ((content + pad * 2) / 10).rounded(.up) * 10
        let cy = top + height / 2
        var nodes: [FlowNode] = [], ribbons: [FlowRibbon] = []
        // Left column.
        var y = cy - left / 2
        var adapterRect: NSRect?, batterySource: NSRect?
        if showAdapter {
            let r = NSRect(x: minX, y: y, width: nodeWidth, height: adapterHeight); adapterRect = r; y += adapterHeight + stack
            nodes.append(FlowNode(rect: r, symbol: "powerplug.fill", tint: foreground,
                                  caption: adapterHeight >= 44 ? (f.adapter.map { $0 >= 10 ? String(format: "%.0f W", $0) : String(format: "%.1f W", $0) } ?? "—") : nil))
        }
        if showSourceBattery {
            let r = NSRect(x: minX, y: y, width: nodeWidth, height: sourceBatteryHeight); batterySource = r
            nodes.append(FlowNode(rect: r, symbol: batterySymbol(f.charge), tint: amber, caption: nil))
        }
        // Middle column: the battery above the Mac while it charges.
        y = cy - middle / 2
        var batterySink: NSRect?
        if isCharging {
            let r = NSRect(x: hubX, y: y, width: nodeWidth, height: sinkBatteryHeight); batterySink = r; y += sinkBatteryHeight + stack
            nodes.append(FlowNode(rect: r, symbol: batterySymbol(f.charge), tint: green, caption: nil))
        }
        let mac = NSRect(x: hubX, y: y, width: nodeWidth, height: macHeight)
        nodes.append(FlowNode(rect: mac, symbol: "laptopcomputer", tint: blue,
                              caption: macHeight >= 44 ? f.system.map { $0 >= 10 ? String(format: "%.1f W", $0) : String(format: "%.2f W", $0) } : nil))
        // Right column, centred on the Mac and kept inside the diagram.
        let outTop = max(top + pad, min(mac.midY - right / 2, top + height - pad - right))
        var pills: [NSRect] = [], py = outTop
        for (entry, h) in zip(outs, pillHeights) {
            let r = NSRect(x: outX, y: py, width: pillWidth, height: h); pills.append(r); py += h + pillGap
            let look = style(entry)
            nodes.append(FlowNode(rect: r, symbol: look.symbol, tint: look.tint, caption: nil,
                                  title: entry.title, detail: Self.flowWatts(entry.watts), iconPath: look.iconPath))
        }
        // Ribbons: each leaves its node stacked edge to edge and arrives the same way.
        var macInY = mac.midY - thick(macIn) / 2
        if let a = adapterRect {
            var outY = a.midY - thick(adapter) / 2
            if isCharging, let b = batterySink {
                let t = thick(charging)
                ribbons.append(FlowRibbon(start: NSPoint(x: a.maxX + gap, y: outY + t / 2), end: NSPoint(x: b.minX - gap, y: b.midY),
                                          width: t, from: green, to: amber, value: charging))
                outY += t
            }
            let t = thick(toMac)
            ribbons.append(FlowRibbon(start: NSPoint(x: a.maxX + gap, y: outY + t / 2), end: NSPoint(x: mac.minX - gap, y: macInY + t / 2),
                                      width: max(t, 1), from: green, to: blue, value: hasAdapter ? toMac : nil))
            macInY += t
        }
        if let b = batterySource {
            let t = thick(discharging)
            ribbons.append(FlowRibbon(start: NSPoint(x: b.maxX + gap, y: b.midY), end: NSPoint(x: mac.minX - gap, y: macInY + t / 2),
                                      width: max(t, 1), from: amber, to: blue, value: f.batteryOut))
        }
        var outY = mac.midY - outThick.reduce(0, +) / 2
        for ((entry, t), pill) in zip(zip(outs, outThick), pills) {
            ribbons.append(FlowRibbon(start: NSPoint(x: mac.maxX + gap, y: outY + t / 2), end: NSPoint(x: pill.minX - gap, y: pill.midY),
                                      width: max(t, 1), from: blue, to: style(entry).tint, value: entry.watts, labeled: false))
            outY += t
        }
        return FlowLayout(nodes: nodes, ribbons: ribbons, height: height)
    }
    func tint(_ category: PowerCategory) -> NSColor {
        switch category {
        case .development: violet
        case .browsing: NSColor(red: 0.33, green: 0.68, blue: 0.98, alpha: 1)
        case .work: amber
        case .media: NSColor(red: 0.93, green: 0.45, blue: 0.62, alpha: 1)
        case .background: NSColor(red: 0.58, green: 0.61, blue: 0.68, alpha: 1)
        case .apps: NSColor(red: 0.36, green: 0.80, blue: 0.86, alpha: 1)
        }
    }
    private func style(_ entry: PowerBreakdown.Entry) -> (symbol: String, tint: NSColor, iconPath: String?) {
        switch entry.kind {
        case .app(_, let path, let symbol, let category): (symbol, tint(category), path)
        case .category(let category): (category.symbol, tint(category), nil)
        case .restOfMac: ("display", NSColor(red: 0.52, green: 0.58, blue: 0.78, alpha: 1), nil)
        case .outside: ("ellipsis", teal, nil)
        case .system: ("cpu", violet, nil)
        }
    }
    private func batterySymbol(_ charge: Double?) -> String {
        let c = charge ?? 100
        return "battery.\(c >= 88 ? 100 : c >= 63 ? 75 : c >= 38 ? 50 : c >= 13 ? 25 : 0)percent"
    }
    private static func flowWatts(_ value: Double) -> String {
        value >= 10 ? String(format: "%.1f W", value) : String(format: "%.2f W", value)
    }
    private func drawFlow(_ current: EnergyFlow) {
        let layout = flowLayout(current, top: flowRect.minY)
        drawRibbons(layout.ribbons)
        for node in layout.nodes {
            let r = node.rect, radius = min(10, r.height / 2)
            let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
            NSColor(calibratedWhite: dark ? 0.16 : 0.97, alpha: 0.92).setFill(); path.fill()
            hairline.setStroke(); path.lineWidth = 1; path.stroke()
            if let title = node.title {
                let icon = NSRect(x: r.minX + 9, y: r.midY - 8, width: 16, height: 16)
                if let iconPath = node.iconPath, let image = processes.icons[iconPath] {
                    image.draw(in: icon, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                } else { symbol(node.symbol, in: icon.insetBy(dx: 1, dy: 1), color: node.tint) }
                text(title, NSRect(x: r.minX + 31, y: r.midY - 14.5, width: r.width - 36, height: 15), size: 11, weight: .semibold)
                text(node.detail ?? "", NSRect(x: r.minX + 31, y: r.midY + 0.5, width: r.width - 36, height: 14), size: 10.5, weight: .medium, color: muted, digits: true)
                continue
            }
            let small = r.height < 30 || node.symbol == "cpu" || node.symbol == "ellipsis"
            let icon: CGFloat = small ? 14 : 17
            let iconY = node.caption == nil ? r.midY - icon / 2 : r.midY - icon / 2 - 8
            symbol(node.symbol, in: NSRect(x: r.midX - icon / 2 - 4, y: iconY, width: icon + 8, height: icon), color: node.tint)
            if let caption = node.caption {
                text(caption, NSRect(x: r.minX, y: iconY + icon + 3, width: r.width, height: 15), size: 10.5, weight: .medium, color: muted, alignment: .center, digits: true)
            }
        }
        // Labels sit on their ribbons; one that would overlap an earlier label moves clear of it.
        var placed: [NSRect] = []
        for ribbon in layout.ribbons where ribbon.live && ribbon.labeled {
            let p = ribbon.point(ribbon.labelAt)
            // A thin ribbon carries its label just under the line rather than across a neighbour.
            var rect = NSRect(x: p.x - 36, y: ribbon.width < 12 ? p.y + ribbon.width / 2 + 1 : p.y - 8.5, width: 72, height: 17)
            for other in placed where other.intersects(rect) { rect.origin.y = other.maxY + 1 }
            placed.append(rect)
            text(Self.flowWatts(ribbon.value ?? 0), rect, size: 12.5, weight: .bold, color: dark ? .white : foreground, alignment: .center, digits: true)
        }
    }
    private func ribbonPath(_ r: FlowRibbon) -> CGPath {
        let path = CGMutablePath(), mid = (r.start.x + r.end.x) / 2, half = r.width / 2
        path.move(to: NSPoint(x: r.start.x, y: r.start.y - half))
        path.addCurve(to: NSPoint(x: r.end.x, y: r.end.y - half), control1: NSPoint(x: mid, y: r.start.y - half), control2: NSPoint(x: mid, y: r.end.y - half))
        path.addLine(to: NSPoint(x: r.end.x, y: r.end.y + half))
        path.addCurve(to: NSPoint(x: r.start.x, y: r.start.y + half), control1: NSPoint(x: mid, y: r.end.y + half), control2: NSPoint(x: mid, y: r.start.y + half))
        path.closeSubpath(); return path
    }
    private func drawRibbons(_ ribbons: [FlowRibbon]) {
        guard let context = NSGraphicsContext.current?.cgContext, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        for r in ribbons {
            let path = ribbonPath(r)
            let alpha: CGFloat = r.value == nil ? 0.10 : (dark ? 0.46 : 0.34)
            context.saveGState(); context.addPath(path); context.clip()
            let colors = [r.from.withAlphaComponent(alpha).cgColor, r.to.withAlphaComponent(alpha).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: r.start, end: r.end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            context.restoreGState()
            context.addPath(path)
            context.setStrokeColor(r.to.withAlphaComponent(r.value == nil ? 0.12 : 0.40).cgColor)
            context.setLineWidth(0.6); context.strokePath()
        }
    }
    private func drawMotion(_ ribbons: [FlowRibbon]) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let time = ProcessInfo.processInfo.systemUptime / 1.8
        for (index, r) in ribbons.enumerated() where r.live {
            for offset in [0.0, 0.5] {
                let p = r.point(CGFloat((time + Double(index) * 0.13 + offset).truncatingRemainder(dividingBy: 1)))
                context.setFillColor(r.to.withAlphaComponent(0.9).cgColor)
                context.fillEllipse(in: NSRect(x: p.x - 1.8, y: p.y - 1.8, width: 3.6, height: 3.6))
            }
        }
    }
    // MARK: Apps

    private var appsEmptyText: String {
        if let notice = processes.notice { return notice }
        if processes.ranked.isEmpty { return processes.loading ? "Measuring App Energy…" : processes.emptyMessage }
        return "No Apps Using Significant Energy"
    }
    private func drawApps(_ dirtyRect: NSRect) {
        let r = appsRect; guard r.intersects(dirtyRect) else { return }
        let rows = processRows
        guard !rows.isEmpty else {
            card(r, radius: r.height / 2)
            text(appsEmptyText, NSRect(x: r.minX + 18, y: r.midY - 10, width: r.width - 36, height: 20), size: 13, weight: .semibold, alignment: .center)
            return
        }
        card(r, radius: 20)
        text("Apps Using Significant Energy", NSRect(x: r.minX + 16, y: r.minY + 13, width: r.width - 120, height: 19), size: 13, weight: .semibold)
        text("CPU energy", NSRect(x: r.maxX - 110, y: r.minY + 15, width: 94, height: 15), size: 10, color: muted, alignment: .right)
        for header in appsLayout.headers where NSRect(x: 12, y: header.y, width: r.width, height: 24).intersects(dirtyRect) {
            let category = header.section.category
            symbol(category.symbol, in: NSRect(x: 29, y: header.y + 4, width: 14, height: 13), color: tint(category))
            text(category.title, NSRect(x: 54, y: header.y + 2, width: bounds.width - 196, height: 17), size: 11, weight: .semibold, color: tint(category))
            text(ProcessPanelKind.power.formatted(header.section.total), NSRect(x: bounds.width - 143, y: header.y + 2, width: 93, height: 17),
                 size: 11, weight: .semibold, color: tint(category), alignment: .right, digits: true)
        }
        for item in rows {
            let row = item.row, y = item.y, presentation = item.row.consumer.presentation, indent = item.indent
            guard NSRect(x: 12, y: y, width: r.width, height: item.height).intersects(dirtyRect) else { continue }
            if indent > 0 { NSColor.separatorColor.setFill(); NSRect(x: 35, y: y, width: 1, height: item.height).fill() }
            if let path = presentation.iconBundlePath, let icon = processes.icons[path] { icon.draw(in: NSRect(x: 28 + indent, y: y, width: 18, height: 18), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
            text(presentation.title, NSRect(x: 54 + indent, y: y, width: bounds.width - 196 - indent, height: 19), size: 12, weight: .medium)
            if let subtitle = presentation.subtitle { text(subtitle, NSRect(x: 54 + indent, y: y + 18, width: bounds.width - 102 - indent, height: 16), size: 9, color: muted) }
            if ProcessQuitArming.shared.isArmed(row.id) {
                text("quitting…", NSRect(x: bounds.width - 143, y: y + 1, width: 93, height: 17), size: 10, weight: .medium, color: .systemOrange, alignment: .right)
            } else {
                // An app at the heavy threshold has its own pill in the flow; its figure stands out here too.
                let heavy = item.indent == 0 && row.value >= PowerBreakdown.heavyWatts
                text((row.missingCount > 0 ? "≥ " : "") + ProcessPanelKind.power.formatted(row.value), NSRect(x: bounds.width - 143, y: y, width: 93, height: 19),
                     size: 11, weight: heavy ? .bold : .regular, color: heavy ? foreground : muted, alignment: .right, digits: true)
            }
        }
        if let notice = processes.notice {
            text(notice, NSRect(x: 28, y: r.maxY - 39, width: r.width - 32, height: 16), size: 10, weight: .semibold, color: blue)
        }
        text("CPU energy estimate; excludes GPU and display · updates every 5 s", NSRect(x: 28, y: r.maxY - 21, width: r.width - 32, height: 15), size: 9, color: muted)
    }
    private func graphRect(_ index: Int) -> NSRect { let r = chartRects[index]; return NSRect(x: 24, y: r.minY + 46, width: bounds.width - 48, height: 78) }
    private func reference(_ index: Int) -> Double? {
        if index == 2 { return Double(power.activeCeiling ?? power.band.upper) }
        if index == 0 { let values = (monitoring.history[chartIDs[index]] ?? []).map(\.value); return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        return nil
    }
    private func drawChartReference(_ index: Int, rect: NSRect, showLabel: Bool) {
        guard let value = reference(index) else { return }
        let graph = graphRect(index), points = monitoring.history[chartIDs[index]] ?? []
        let scale = EnergyChart.scale(points.map(\.value), percent: index == 2, reference: value)
        let y = graph.maxY - graph.height * (value - scale.lowerBound) / (scale.upperBound - scale.lowerBound)
        let line = NSBezierPath(); line.move(to: NSPoint(x: graph.minX, y: y)); line.line(to: NSPoint(x: graph.maxX, y: y))
        line.setLineDash([4, 4], count: 2, phase: 0); line.lineWidth = 1
        NSColor.systemOrange.withAlphaComponent(0.75).setStroke(); line.stroke()
        let label = index == 0 ? String(format: "Avg %.1f W", value) : "\(power.snapshot.mode == .off ? "Target (off)" : power.snapshot.mode == .topUp ? "Top up" : "Limit") \(Int(value))%"
        if showLabel { text(label, NSRect(x: bounds.width - 160, y: rect.maxY - 20, width: 134, height: 14), size: 9, color: .systemOrange, alignment: .right) }
    }
    private func drawChartPlot(_ index: Int) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = graphRect(index), points = monitoring.history[chartIDs[index]] ?? []
        let scale = EnergyChart.scale(points.map(\.value), percent: index == 2, reference: reference(index))
        let line = CGMutablePath(), fill = CGMutablePath()
        let range = max(1, points.last?.time.timeIntervalSince(points.first?.time ?? Date()) ?? 0)
        for segment in EnergyChart.segments(points, maximumGap: maximumAge, breaks: monitoring.energyHistoryBreaks[chartIDs[index]] ?? []) {
            let positions = segment.map { p in NSPoint(x: rect.width * p.time.timeIntervalSince(points.first!.time) / range, y: rect.height * (1 - (p.value - scale.lowerBound) / (scale.upperBound - scale.lowerBound))) }
            guard let first = positions.first, let last = positions.last else { continue }
            line.move(to: first); fill.move(to: NSPoint(x: first.x, y: rect.height)); fill.addLine(to: first)
            if positions.count == 1 { line.addLine(to: NSPoint(x: first.x + 1, y: first.y)) }
            for p in positions.dropFirst() { line.addLine(to: p); fill.addLine(to: p) }
            fill.addLine(to: NSPoint(x: last.x, y: rect.height)); fill.closeSubpath()
        }
        let color = [violet, blue, green][index]
        context.saveGState(); context.translateBy(x: rect.minX, y: rect.minY)
        context.addPath(fill); context.setFillColor(color.withAlphaComponent(0.13).cgColor); context.fillPath()
        context.addPath(line); context.setStrokeColor(color.cgColor); context.setLineWidth(1.8); context.setLineJoin(.round); context.strokePath()
        context.restoreGState()
    }
    func updateLayers() { setMotionActive(motionActive); updateAccessibility(); needsDisplay = true }
    func setMotionActive(_ active: Bool) {
        motionActive = active
        let running = active && enabled && showFlow && !reducedMotion && flow.hasLiveFlow
        if running && motionTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 24, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { guard let self else { return }; self.setNeedsDisplay(self.flowRect) }
            }
            timer.tolerance = 1.0 / 240; motionTimer = timer; RunLoop.main.add(timer, forMode: .common)
        } else if !running { motionTimer?.invalidate(); motionTimer = nil }
    }
    func removeAnimations() { motionTimer?.invalidate(); motionTimer = nil }
    private lazy var quitButtons = ProcessQuitButtons(processes: processes, tint: muted)
    private func layoutQuitButtons() {
        quitButtons.layout(in: self, rows: (enabled ? processRows : []).map { item in
            (item.row, NSRect(x: bounds.width - 44, y: item.y - 1, width: 18, height: 18))
        })
    }
    private func updateAccessibility() {
        layoutQuitButtons()
        let f = flow
        var rows: [(String, NSRect)] = [("Battery \(f.charge.map { String(format: "%.0f percent", $0) } ?? "unavailable"). \(controlStatus). \(issue ?? "")", batteryBar.insetBy(dx: 0, dy: -6))]
        if showFlow {
            let parts = breakdown.entries.map { "\($0.title) \(EnergyFlow.watts($0.watts))" }.joined(separator: ", ")
            rows.append(("Power flow. Adapter \(EnergyFlow.watts(f.adapter)): \(EnergyFlow.watts(f.batteryIn)) into the battery. Battery out \(EnergyFlow.watts(f.batteryOut)). Mac system \(EnergyFlow.watts(f.system)). Where it goes: \(parts).", flowRect))
        }
        for index in 0..<3 where chartVisibility[index] {
            let id = chartIDs[index], value = monitoring.display(id)
            rows.append(("\(monitoring.metric(id).name): \(value). \((monitoring.history[id] ?? []).count) real samples. Missing periods are gaps.", chartRects[index]))
        }
        for item in processRows {
            let row = item.row, presentation = item.row.consumer.presentation
            rows.append(("\(presentation.title), \(presentation.subtitle ?? "application"): \(row.missingCount > 0 ? "at least " : "")\(ProcessPanelKind.power.formatted(row.value)) CPU energy estimate, \(row.consumer.processCount) processes. \(presentation.explanation)", NSRect(x: 24, y: item.y, width: bounds.width - 48, height: item.height)))
        }
        accessibilityRows = rows.map { label, rect in
            let element = EnergyAccessibleText(); element.owner = self
            element.setAccessibilityRole(.staticText); element.setAccessibilityLabel(label)
            element.setAccessibilityFrameInParentSpace(rect)
            return element
        }
        setAccessibilityChildren((accessibilityRows as [Any]) + NSAccessibility.unignoredChildren(from: subviews.filter { !$0.isHidden }))
        toolTip = controlStatus + "\n\nPower values are separate sensor observations, not wall-meter or per-component totals. Difference = adapter − system − signed battery flow. Process power includes CPU energy only, so the categories and apps are app CPU energy; “Display & system” is the rest of the system figure (display, GPU, memory, and macOS processes MenuSprite cannot read). The saved MenuSprite charge target is not an active system limit while control is off."
    }
}

private final class EnergyAccessibleText: NSAccessibilityElement {
    weak var owner: NSView?
    override func accessibilityParent() -> Any? { owner }
}
