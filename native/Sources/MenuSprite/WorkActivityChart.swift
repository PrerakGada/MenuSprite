import AppKit
import SwiftUI
import WorkTracking

/// A small static histogram needs no chart engine, animation or display timer.
struct WorkActivityChart: NSViewRepresentable {
    let days: [(date: Date, seconds: Double)]
    let range: DateInterval
    func makeNSView(context: Context) -> WorkActivityPlot { WorkActivityPlot() }
    func updateNSView(_ view: WorkActivityPlot, context: Context) {
        view.days = days; view.range = range; view.needsDisplay = true
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("Recorded activity by day, India Standard Time")
        view.setAccessibilityValue(days.map { "\(WorkStore.day($0.date)): \(WorkReport.hours($0.seconds))" }.joined(separator: "; "))
    }
}

final class WorkActivityPlot: NSView {
    var days: [(date: Date, seconds: Double)] = []
    var range = DateInterval(start: Date(), duration: 86400)
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let plot = NSRect(x: 27, y: 5, width: max(1, bounds.width - 36), height: max(1, bounds.height - 28))
        let maximum = max(1, ceil((days.map { $0.seconds / 3600 }.max() ?? 0) / 2) * 2)
        let end = max(range.start.addingTimeInterval(86400), min(range.end, WorkReport.calendar.date(byAdding: .day, value: 1, to: WorkReport.calendar.startOfDay(for: Date()))!))
        let duration = end.timeIntervalSince(range.start)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        for fraction in [0.0, 0.5, 1.0] {
            let y = plot.maxY - plot.height * fraction
            NSColor.separatorColor.withAlphaComponent(0.25).setStroke()
            let line = NSBezierPath(); line.move(to: NSPoint(x: plot.minX, y: y)); line.line(to: NSPoint(x: plot.maxX, y: y)); line.lineWidth = 0.5; line.stroke()
            let value = maximum * fraction
            let label = String(format: value.rounded() == value ? "%.0fh" : "%.1fh", value)
            (label as NSString).draw(at: NSPoint(x: 0, y: y - 6), withAttributes: attributes)
        }
        NSColor(calibratedRed: 0.53, green: 0.43, blue: 0.82, alpha: 0.8).setFill()
        let dayWidth = plot.width * 86400 / duration
        let barWidth = max(1, min(20, dayWidth * 0.7))
        for day in days {
            let x = plot.minX + plot.width * (day.date.addingTimeInterval(43200).timeIntervalSince(range.start) / duration)
            let height = plot.height * day.seconds / 3600 / maximum
            guard x >= plot.minX, x <= plot.maxX else { continue }
            NSBezierPath(roundedRect: NSRect(x: x - barWidth / 2, y: plot.maxY - height, width: barWidth, height: height), xRadius: 2, yRadius: 2).fill()
        }
        let formatter = DateFormatter(); formatter.timeZone = WorkReport.calendar.timeZone; formatter.dateFormat = "d MMM"
        let count = min(6, max(1, Int(duration / 86400)))
        for i in 0..<count {
            let fraction = count == 1 ? 0.5 : Double(i) / Double(count - 1)
            let date = range.start.addingTimeInterval((duration - 86400) * fraction)
            let label = formatter.string(from: date) as NSString
            let size = label.size(withAttributes: attributes)
            let x = max(plot.minX, min(plot.maxX - size.width, plot.minX + plot.width * fraction - size.width / 2))
            label.draw(at: NSPoint(x: x, y: plot.maxY + 6), withAttributes: attributes)
        }
    }
}
