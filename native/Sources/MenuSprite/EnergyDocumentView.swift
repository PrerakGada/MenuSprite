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
    private var motionActive = false
    private var motionTimer: Timer?
    private var cachedFlow: EnergyFlow?
    private var cachedFlowImage: NSImage?
    private var cachedFlowSize = NSSize.zero
    private var cachedFlowDark = false
    private var renderingFlowCache = false
    private var accessibilityRows: [NSAccessibilityElement] = []
    private let violet = NSColor(red: 0.66, green: 0.40, blue: 0.96, alpha: 1)
    private let blue = NSColor(red: 0.39, green: 0.62, blue: 0.97, alpha: 1)
    private let green = NSColor(red: 0.48, green: 0.76, blue: 0.57, alpha: 1)
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    private var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    private var muted: NSColor { NSColor(calibratedWhite: dark ? 0.69 : 0.39, alpha: 1) }
    private var foreground: NSColor { NSColor(calibratedWhite: dark ? 0.93 : 0.12, alpha: 1) }
    var flow: EnergyFlow { EnergyFlow(readings: monitoring.readings, maximumAge: maximumAge) }
    var limitOrigin: CGFloat { 100 }
    var optionsOrigin: CGFloat { limitOrigin + (limitExpanded ? 158 : 0) }
    var flowRect: NSRect { NSRect(x: 12, y: optionsOrigin + (optionsExpanded ? 104 : 0), width: bounds.width - 24, height: showFlow ? 236 : 0) }
    private var energyRow: NSRect { NSRect(x: 12, y: flowRect.maxY + (showFlow ? 12 : 0), width: bounds.width - 24, height: 55) }
    private var chartRects: [NSRect] {
        var y = energyRow.maxY + 12
        return chartVisibility.map { visible in
            let rect = NSRect(x: 12, y: y, width: bounds.width - 24, height: visible ? 148 : 0)
            if visible { y += 160 }; return rect
        }
    }
    private var listRect: NSRect {
        let y = max(energyRow.maxY + 12, chartRects.map(\.maxY).max() ?? 0)
        return NSRect(x: 12, y: y, width: bounds.width - 24, height: 83 + max(36, processes.ranked.prefix(30).reduce(CGFloat(0)) { $0 + ($1.consumer.presentation.subtitle == nil ? 26 : 40) }))
    }
    private var processRows: [(row: ProcessConsumerRate, y: CGFloat, height: CGFloat)] {
        var y = listRect.minY + 62
        return processes.ranked.prefix(30).map { row in
            let height: CGFloat = row.consumer.presentation.subtitle == nil ? 26 : 40
            defer { y += height }
            return (row, y, height)
        }
    }
    var requiredHeight: CGFloat { enabled ? listRect.maxY + 18 : 155 }
    func visibleIconConsumers(in visible: NSRect) -> Set<String> {
        guard enabled else { return [] }
        var ids: Set<String> = []
        if visible.intersects(energyRow), let top = processes.ranked.first { ids.insert(top.id) }
        for item in processRows {
            if visible.intersects(NSRect(x: 12, y: item.y, width: listRect.width, height: item.height)) { ids.insert(item.row.id) }
        }
        return ids
    }
    var isAnimating: Bool { motionTimer != nil }
    init(monitoring: MonitoringStore, processes: MemoryBoardStore, power: PowerStore) {
        self.monitoring = monitoring; self.processes = processes; self.power = power
        super.init(frame: NSRect(x: 0, y: 0, width: 430, height: 1100))
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Battery and power dashboard")
    }
    required init?(coder: NSCoder) { fatalError() }
    private func text(_ value: String, _ rect: NSRect, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                      color: NSColor? = nil, alignment: NSTextAlignment = .left, digits: Bool = false, wrap: Bool = false) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment
        paragraph.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        (value as NSString).draw(in: rect, withAttributes: [.font: digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color ?? foreground, .paragraphStyle: paragraph])
    }
    private func card(_ rect: NSRect, radius: CGFloat = 15) {
        NSColor(calibratedWhite: dark ? 0.18 : 0.95, alpha: 1).setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius); path.fill()
        NSColor(calibratedWhite: dark ? 0.29 : 0.86, alpha: 1).setStroke(); path.lineWidth = 0.6; path.stroke()
    }
    private func symbol(_ name: String, in rect: NSRect, color: NSColor? = nil) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let tinted = NSImage(size: rect.size, flipped: true) { r in
            image.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            (color ?? self.muted).setFill(); r.fill(using: .sourceAtop); return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    private var controlStatus: String {
        if power.snapshot.recoveryPending { return "Battery control needs recovery" }
        if !power.snapshot.helperConnected && power.snapshot.mode != .off { return "Connection lost · recovery pending" }
        switch power.snapshot.mode {
        case .off: return "MenuSprite charge control is off"
        case .maintain: return "Maintaining \(power.snapshot.band.lower)–\(power.snapshot.band.upper)%"
        case .topUp: return "Topping up to 100%"
        case .discharge: return "Discharging to \(power.snapshot.band.upper)%"
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: dark ? 0.11 : 0.985, alpha: 1).setFill(); bounds.fill()
        guard enabled else {
            text("This power sprite is paused.", NSRect(x: 24, y: 20, width: bounds.width - 48, height: 30), weight: .semibold)
            text("Use Customize to enable it. Charts and process collection are paused.", NSRect(x: 24, y: 57, width: bounds.width - 48, height: 65), color: muted, wrap: true)
            return
        }
        let current = flow
        let bar = NSRect(x: 14, y: 2, width: bounds.width - 28, height: 29)
        card(bar, radius: 14)
        if let charge = current.charge {
            blue.withAlphaComponent(dark ? 0.48 : 0.23).setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(0.01, bar.width * charge / 100), height: bar.height), xRadius: 14, yRadius: 14).fill()
        }
        let marker = bar.minX + bar.width * Double(power.snapshot.controlCeiling ?? power.band.upper) / 100
        let mark = NSBezierPath(); mark.move(to: .init(x: marker, y: bar.minY - 2)); mark.line(to: .init(x: marker, y: bar.maxY + 2))
        mark.lineWidth = 2; mark.setLineDash([3, 3], count: 2, phase: 0); muted.setStroke(); mark.stroke()
        text(current.charge.map { String(format: "%.0f%%", $0) } ?? "—", NSRect(x: 25, y: 5, width: 70, height: 22), size: 17, weight: .semibold, digits: true)
        text(current.sourceState ?? "Power source unavailable", NSRect(x: 97, y: 8, width: bar.width - 100, height: 17), size: 11, weight: .medium)
        text(controlStatus, NSRect(x: 16, y: 42, width: bounds.width - 32, height: 19), size: 11, weight: .semibold, color: power.snapshot.mode == .off ? muted : green)
        let detail = power.notice ?? power.batteryControlReason ?? "Limits stop on sleep, unplug or app exit."
        text(detail, NSRect(x: 16, y: 63, width: bounds.width - 32, height: 32), size: 10, color: muted, wrap: true)
        if limitExpanded { card(NSRect(x: 12, y: limitOrigin, width: bounds.width - 24, height: 146)) }
        if optionsExpanded { card(NSRect(x: 12, y: optionsOrigin, width: bounds.width - 24, height: 92)) }
        for case let button as NSButton in subviews where button.tag == 900 && !button.isHidden {
            NSColor(calibratedWhite: dark ? 0.25 : 0.88, alpha: 1).setFill()
            NSBezierPath(roundedRect: button.frame, xRadius: 9, yRadius: 9).fill()
        }
        if showFlow && flowRect.intersects(dirtyRect) { drawCachedFlow(current) }
        if energyRow.intersects(dirtyRect) {
        card(energyRow)
        text("Highest app CPU energy", NSRect(x: 25, y: energyRow.minY + 10, width: 192, height: 17), size: 11, weight: .semibold)
        text("Measured across accessible app processes", NSRect(x: 25, y: energyRow.minY + 30, width: 220, height: 15), size: 9, color: muted)
        if let top = processes.ranked.first, top.value > 0 {
            let title = top.consumer.presentation.title
            let x = bounds.width - 171
            if let path = top.consumer.presentation.iconBundlePath, let icon = processes.icons[path] { icon.draw(in: NSRect(x: x, y: energyRow.minY + 13, width: 23, height: 23), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
            text(title, NSRect(x: x + 30, y: energyRow.minY + 10, width: 113, height: 18), size: 11, weight: .semibold, alignment: .right)
            text((top.missingCount > 0 ? "≥ " : "") + ProcessPanelKind.power.formatted(top.value), NSRect(x: x + 30, y: energyRow.minY + 30, width: 113, height: 17), size: 10, color: muted, alignment: .right, digits: true)
        } else { text(processes.loading || !processes.hasInterval ? "Sampling…" : "No comparable activity", NSRect(x: bounds.width - 150, y: energyRow.minY + 18, width: 120, height: 20), size: 10, color: muted, alignment: .right) }
        }
        let values = [current.system, current.temperature, current.charge]
        let titles = ["Power Consumption", "Battery Temperature", "Battery Level"]
        let units = ["W", "°C", "%"]
        for index in 0..<3 where chartVisibility[index] {
            let rect = chartRects[index]
            guard rect.intersects(dirtyRect) else { continue }
            card(rect)
            text(titles[index], NSRect(x: 25, y: rect.minY + 12, width: 224, height: 24), size: 14, weight: .semibold)
            let value = values[index].map { String(format: index == 2 ? "%.0f %@" : "%.1f %@", $0, units[index]) } ?? "—"
            text(value, NSRect(x: bounds.width - 141, y: rect.minY + 8, width: 116, height: 31), size: 22, weight: .bold, alignment: .right, digits: true)
            drawChartPlot(index)
            drawChartReference(index, rect: rect, showLabel: values[index] != nil)
            let points = monitoring.history[chartIDs[index]] ?? []
            let latest = points.last.map { Int(Date().timeIntervalSince($0.time)) } ?? -1
            let time = latest >= 0 ? "\(points.count) samples · latest \(latest)s ago" : "Waiting for samples"
            text(time, NSRect(x: 25, y: rect.maxY - 20, width: 210, height: 14), size: 9, color: muted)
            if values[index] == nil {
                text("Reading unavailable", NSRect(x: bounds.width - 163, y: rect.maxY - 20, width: 136, height: 14), size: 9, color: muted, alignment: .right)
            }
        }
        drawProcesses(dirtyRect)
    }
    private let chartIDs = ["sensor.PSTR", "battery.temperature", "battery.charge"]
    private func drawCachedFlow(_ current: EnergyFlow) {
        if cachedFlow != current || cachedFlowSize != flowRect.size || cachedFlowDark != dark || cachedFlowImage == nil {
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
                    cachedFlowImage = image; cachedFlow = current; cachedFlowSize = flowRect.size; cachedFlowDark = dark
                }
            }
        }
        cachedFlowImage?.draw(in: flowRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if motionTimer != nil { drawRibbons(current, origin: NSPoint(x: flowRect.minX, y: flowRect.minY + 40), motionOnly: true) }
    }
    private func drawFlow(_ current: EnergyFlow) {
        card(flowRect)
        text("Power flow", NSRect(x: 25, y: flowRect.minY + 12, width: 170, height: 20), size: 13, weight: .semibold)
        text("Live sensor readings", NSRect(x: bounds.width - 164, y: flowRect.minY + 15, width: 137, height: 16), size: 9, color: muted, alignment: .right)
        let origin = NSPoint(x: flowRect.minX, y: flowRect.minY + 40), w = flowRect.width
        drawRibbons(current, origin: origin)
        func node(_ title: String, _ value: Double?, _ rect: NSRect, _ tint: NSColor) {
            let r = rect.offsetBy(dx: origin.x, dy: origin.y)
            tint.withAlphaComponent(dark ? 0.10 : 0.07).setFill(); NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
            text(title, NSRect(x: r.minX + 4, y: r.minY + 4, width: r.width - 8, height: 14), size: 9, color: muted, alignment: .center)
            text(EnergyFlow.watts(value), NSRect(x: r.minX + 2, y: r.minY + 21, width: r.width - 4, height: 21), size: 15, weight: .semibold, alignment: .center, digits: true)
        }
        node("Adapter DC", current.adapter, NSRect(x: 8, y: 15, width: 74, height: 48), blue)
        node("Battery out", current.batteryOut, NSRect(x: 8, y: 105, width: 74, height: 48), green)
        let hub = NSRect(x: origin.x + 144, y: origin.y + 53, width: 58, height: 68)
        NSColor(calibratedWhite: dark ? 0.23 : 0.90, alpha: 1).setFill(); NSBezierPath(roundedRect: hub, xRadius: 10, yRadius: 10).fill()
        symbol("laptopcomputer", in: NSRect(x: hub.minX + 13, y: hub.minY + 10, width: 32, height: 28))
        text("Mac", NSRect(x: hub.minX, y: hub.minY + 45, width: hub.width, height: 16), size: 10, weight: .medium, color: muted, alignment: .center)
        node("System", current.system, NSRect(x: w - 100, y: 6, width: 90, height: 46), violet)
        node("Battery in", current.batteryIn, NSRect(x: w - 100, y: 64, width: 90, height: 46), green)
        node("Difference*", current.difference, NSRect(x: w - 100, y: 122, width: 90, height: 46), muted)
        text(current.imbalance ? "Measurements do not balance; difference unavailable." : "*Input − system − battery. Includes unaccounted loads / losses.", NSRect(x: 25, y: flowRect.maxY - 24, width: bounds.width - 50, height: 19), size: 9, color: muted)
    }
    private func drawProcesses(_ dirtyRect: NSRect) {
        let r = listRect; guard r.intersects(dirtyRect) else { return }
        card(r)
        text("Apps & processes · CPU power", NSRect(x: 25, y: r.minY + 12, width: bounds.width - 50, height: 21), size: 13, weight: .semibold)
        text("CPU energy estimate; excludes GPU, display and other components.", NSRect(x: 25, y: r.minY + 36, width: bounds.width - 50, height: 15), size: 9, color: muted)
        for item in processRows {
            let row = item.row, y = item.y, presentation = item.row.consumer.presentation
            guard NSRect(x: 12, y: y, width: r.width, height: item.height).intersects(dirtyRect) else { continue }
            if let path = presentation.iconBundlePath, let icon = processes.icons[path] { icon.draw(in: NSRect(x: 25, y: y, width: 17, height: 17), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
            text(presentation.title, NSRect(x: 51, y: y, width: bounds.width - 169, height: 19), size: 11)
            if let subtitle = presentation.subtitle { text(subtitle, NSRect(x: 51, y: y + 18, width: bounds.width - 75, height: 16), size: 9, color: muted) }
            text((row.missingCount > 0 ? "≥ " : "") + ProcessPanelKind.power.formatted(row.value), NSRect(x: bounds.width - 119, y: y, width: 93, height: 19), size: 11, color: muted, alignment: .right, digits: true)
        }
        if processes.ranked.isEmpty { text(processes.emptyMessage, NSRect(x: 25, y: r.minY + 62, width: r.width - 26, height: 38), size: 10, color: muted, wrap: true) }
        text("Accessible processes and app helpers · updates every 5 seconds", NSRect(x: 25, y: r.maxY - 20, width: r.width - 26, height: 15), size: 9, color: muted)
    }
    private func graphRect(_ index: Int) -> NSRect { let r = chartRects[index]; return NSRect(x: 24, y: r.minY + 46, width: bounds.width - 48, height: 78) }
    private func reference(_ index: Int) -> Double? {
        if index == 2 { return Double(power.snapshot.controlCeiling ?? power.band.upper) }
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
    private func ribbon(from start: NSPoint, to end: NSPoint, width: CGFloat) -> CGPath {
        let path = CGMutablePath(), mid = (start.x + end.x) / 2
        path.move(to: NSPoint(x: start.x, y: start.y - width / 2))
        path.addCurve(to: NSPoint(x: end.x, y: end.y - width / 2), control1: NSPoint(x: mid, y: start.y - width / 2), control2: NSPoint(x: mid, y: end.y - width / 2))
        path.addLine(to: NSPoint(x: end.x, y: end.y + width / 2))
        path.addCurve(to: NSPoint(x: start.x, y: start.y + width / 2), control1: NSPoint(x: mid, y: end.y + width / 2), control2: NSPoint(x: mid, y: start.y + width / 2))
        path.closeSubpath(); return path
    }
    private func drawRibbons(_ current: EnergyFlow, origin: NSPoint, motionOnly: Bool = false) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let values = [current.adapter, current.batteryOut, current.system, current.batteryIn, current.difference]
        let colors = [blue, green, violet, green, muted]
        let starts = [NSPoint(x: 82, y: 39), NSPoint(x: 82, y: 129), NSPoint(x: 202, y: 87), NSPoint(x: 202, y: 87), NSPoint(x: 202, y: 87)]
        let ends = [NSPoint(x: 144, y: 87), NSPoint(x: 144, y: 87), NSPoint(x: flowRect.width - 100, y: 29), NSPoint(x: flowRect.width - 100, y: 87), NSPoint(x: flowRect.width - 100, y: 145)]
        let maximum = max(1, values.compactMap { $0 }.max() ?? 1)
        context.saveGState(); context.translateBy(x: origin.x, y: origin.y)
        defer { context.restoreGState() }
        let time = ProcessInfo.processInfo.systemUptime / 1.8
        for index in 0..<5 {
            let value = values[index], start = starts[index], end = ends[index]
            let width = value.map { $0 > 0.05 ? max(3, min(28, $0 / maximum * 28)) : 1.2 } ?? 1.2
            if !motionOnly {
                context.addPath(ribbon(from: start, to: end, width: width))
                context.setFillColor(colors[index].withAlphaComponent(value == nil ? 0.02 : 0.18).cgColor)
                context.setStrokeColor(colors[index].withAlphaComponent(value == nil ? 0.18 : 0.38).cgColor)
                context.setLineWidth(0.7); context.drawPath(using: .fillStroke)
            }
            if !renderingFlowCache && motionTimer != nil && (value ?? 0) > 0.05 {
                let mid = (start.x + end.x) / 2
                for offset in [0.0, 0.5] {
                    let t = (time + Double(index) * 0.13 + offset).truncatingRemainder(dividingBy: 1), u = 1 - t
                    let x = u*u*u*start.x + 3*u*u*t*mid + 3*u*t*t*mid + t*t*t*end.x
                    let y = u*u*u*start.y + 3*u*u*t*start.y + 3*u*t*t*end.y + t*t*t*end.y
                    context.setFillColor(colors[index].withAlphaComponent(0.9).cgColor)
                    context.fillEllipse(in: NSRect(x: x - 1.8, y: y - 1.8, width: 3.6, height: 3.6))
                }
            }
        }
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
    private func updateAccessibility() {
        let f = flow
        var rows: [(String, NSRect)] = [("Battery \(f.charge.map { String(format: "%.0f percent", $0) } ?? "unavailable"). \(controlStatus). \(power.batteryControlReason ?? "")", NSRect(x: 14, y: 2, width: bounds.width - 28, height: 95))]
        if showFlow {
            rows.append(("Power flow. Adapter DC \(EnergyFlow.watts(f.adapter)). Mac system \(EnergyFlow.watts(f.system)). Battery out \(EnergyFlow.watts(f.batteryOut)). Battery in \(EnergyFlow.watts(f.batteryIn)). Calculated unaccounted difference \(EnergyFlow.watts(f.difference)).", flowRect))
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
        toolTip = "Power values are separate sensor observations, not wall-meter or per-component totals. Difference = adapter − system − signed battery flow. Process power includes CPU energy only. The saved MenuSprite charge target is not an active system limit while control is off."
    }
}

private final class EnergyAccessibleText: NSAccessibilityElement {
    weak var owner: NSView?
    override func accessibilityParent() -> Any? { owner }
}
