import AppKit

/// What the pack is doing right now, told apart the same way the MagSafe LED is: the cable, then
/// the measured current (a limit held by macOS reports "not charging" with the cable in).
public enum BatteryActivity: String, Sendable, CaseIterable {
    case charging, holding, draining, onBattery

    /// `state` is the `battery.state` text, `amps` the measured `battery.current` (negative leaves the pack).
    public init?(state: String?, amps: Double?) {
        guard let state else { return nil }
        if state == "On battery" { self = .onBattery; return }
        if let amps, amps < -0.05 { self = .draining; return }
        if state == "Charging" || (amps ?? 0) > 0.05 { self = .charging; return }
        self = .holding
    }
    /// The battery cap's color: amber charging and green holding, as the MagSafe LED shows them,
    /// blue while the pack drains with the cable in. Running on the battery keeps the plain cap.
    public var capHex: String? {
        switch self {
        case .charging: "FF9F0A"
        case .holding: "30D158"
        case .draining: "409CFF"
        case .onBattery: nil
        }
    }
    public var title: String {
        switch self {
        case .charging: "charging"
        case .holding: "holding, cable connected"
        case .draining: "draining with the cable connected"
        case .onBattery: "running on battery"
        }
    }
}

/// A menu-bar battery drawn from the live reading rather than a fixed SF Symbol.
/// The fill tracks the charge, a bolt marks charging, and a tick marks an active
/// charge ceiling so the limit is readable without opening anything.
///
/// Knockouts are composited with `.clear` / `.destinationOut` into the transparent
/// status-item bitmap, so the bolt and the ceiling tick stay visible whether they
/// fall inside the filled region or outside it, and template images keep working.
public struct BatteryGlyph: Equatable, Sendable {
    public var percent: Double?
    public var charging: Bool
    /// The ceiling of an active charge control, 1...100. Nil draws no tick.
    public var ceiling: Int?
    /// Set only when the reading itself demands a color, such as a nearly empty
    /// battery running on its own power. Nil keeps the sprite's own icon color.
    public var alertHex: String?
    /// Draw the charge as a number inside the shell, whole and solid over a dimmed fill.
    public var percentInside: Bool
    /// What the pack is doing; colors the cap. Nil (not read yet) keeps the plain cap.
    public var activity: BatteryActivity?
    /// macOS Low Power Mode is on: a yellow outline and a yellow-tinted fill.
    public var lowPower: Bool
    public static let lowPowerHex = "FFD60A"
    public init(percent: Double? = nil, charging: Bool = false, ceiling: Int? = nil, alertHex: String? = nil,
                percentInside: Bool = false, activity: BatteryActivity? = nil, lowPower: Bool = false) {
        self.percent = percent; self.charging = charging; self.ceiling = ceiling; self.alertHex = alertHex
        self.percentInside = percentInside; self.activity = activity; self.lowPower = lowPower
    }
    /// A colored cap or fill, like a reading-driven alert, means the image cannot be a template.
    public var forcesColor: Bool { alertHex != nil || activity?.capHex != nil || lowPower }

    /// Proportions of the drawn battery, in the same units as `height`.
    public static let aspect: CGFloat = 25.0 / 12.0
    public static func width(forHeight height: CGFloat) -> CGFloat { (height * aspect).rounded() }
    /// A number inside needs a point more of height to stay legible in the menu bar.
    public var slotHeight: CGFloat { percentInside ? 15 : 14 }

    /// A description for accessibility and tooltips; never claims an unread value.
    public var summary: String {
        let level = percent.map { String(format: "%.0f%%", $0) } ?? "level unavailable"
        let state = activity?.title ?? (charging ? "charging" : "not charging")
        let mode = lowPower ? ", Low Power Mode" : ""
        guard let ceiling else { return "Battery \(level), \(state)\(mode)" }
        return "Battery \(level), \(state), limited to \(ceiling)%\(mode)"
    }

    public func draw(in rect: CGRect, ink: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = min(rect.width / 25, rect.height / 12)
        guard scale > 0 else { return }
        let ink = alertHex.flatMap(BatteryGlyph.color) ?? ink
        let width = 25 * scale, height = 12 * scale
        let originX = rect.midX - width / 2, originY = rect.midY - height / 2
        let body = CGRect(x: originX + 0.5 * scale, y: originY + 0.5 * scale, width: 21 * scale, height: 11 * scale)
        let line = max(1, (scale * 1.1).rounded())

        context.saveGState()
        // Low Power Mode outlines the whole battery in yellow and tints the fill; a low-battery
        // alert keeps its own color.
        let yellow = lowPower && alertHex == nil ? BatteryGlyph.color(BatteryGlyph.lowPowerHex) : nil
        // Shell and terminal.
        let shell = CGPath(roundedRect: body.insetBy(dx: line / 2, dy: line / 2),
                           cornerWidth: 3 * scale, cornerHeight: 3 * scale, transform: nil)
        context.setStrokeColor(yellow?.cgColor ?? ink.withAlphaComponent(0.55).cgColor)
        context.setLineWidth(line)
        context.addPath(shell); context.strokePath()
        // The cap carries the pack's activity color, else the outline's; a low-battery alert keeps it in the alert color.
        let cap = alertHex == nil ? activity?.capHex.flatMap(BatteryGlyph.color) : nil
        context.setFillColor(cap?.cgColor ?? yellow?.cgColor ?? ink.withAlphaComponent(0.55).cgColor)
        context.addPath(CGPath(roundedRect: CGRect(x: body.maxX + 1.1 * scale, y: rect.midY - 2.6 * scale,
                                                   width: 2 * scale, height: 5.2 * scale),
                               cornerWidth: 0.8 * scale, cornerHeight: 0.8 * scale, transform: nil))
        context.fillPath()

        // Charge level. An unavailable reading draws an empty shell, never a guess.
        // A number inside gets a larger fill, so the digits cut out of it have room.
        let gap = (percentInside ? 0.9 : 1.4) * scale
        let inner = body.insetBy(dx: line + gap, dy: line + gap)
        if let percent, percent.isFinite {
            let fraction = min(1, max(0, percent / 100))
            let filled = CGRect(x: inner.minX, y: inner.minY, width: max(fraction > 0 ? line : 0, inner.width * fraction), height: inner.height)
            // With the number inside, the yellow is only a tint so the digits keep their contrast.
            context.setFillColor((yellow ?? ink).withAlphaComponent(percentInside ? (yellow == nil ? 0.4 : 0.3) : 1).cgColor)
            context.addPath(CGPath(roundedRect: filled, cornerWidth: 1.2 * scale, cornerHeight: 1.2 * scale, transform: nil))
            context.fillPath()
        }

        // Ceiling tick: clear a gap first so it reads against the fill as well as the empty shell.
        // With the number inside there is no tick at all: nothing may cross the digits. The limit
        // stays in the tooltip, the secondary-click menu and the dashboard.
        if !percentInside, let ceiling, (1...100).contains(ceiling) {
            let x = inner.minX + inner.width * CGFloat(ceiling) / 100
            let tick = max(1, (scale * 1.2).rounded())
            context.setBlendMode(.clear)
            context.fill(CGRect(x: x - tick, y: body.minY - line, width: tick * 3, height: body.height + line * 2))
            context.setBlendMode(.normal)
            context.setFillColor(ink.cgColor)
            context.fill(CGRect(x: x, y: inner.minY - line / 2, width: tick, height: inner.height + line))
        }
        context.restoreGState()

        if percentInside, let percent, percent.isFinite {
            // Full strength: the menu bar's label color is slightly translucent, too faint for 7 pt digits.
            drawNumber(percent, in: body.insetBy(dx: line, dy: line), scale: scale, ink: ink.withAlphaComponent(1), context: context)
            return
        }
        if charging, let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [ink])) {
            let boltHeight = body.height * 0.92
            let boltWidth = bolt.size.width / max(1, bolt.size.height) * boltHeight
            let frame = CGRect(x: body.midX - boltWidth / 2, y: body.midY - boltHeight / 2, width: boltWidth, height: boltHeight)
            bolt.draw(in: frame.insetBy(dx: -line, dy: -line), from: .zero, operation: .destinationOut, fraction: 1)
            bolt.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    /// The number, and a bolt while charging, centred in the shell and always whole: drawn in full ink
    /// over a dimmed fill, with a thin gap cleared around it. Splitting the digits at the fill's edge
    /// (knocked out on one side, solid on the other) made a digit read as a stray line.
    private func drawNumber(_ percent: Double, in interior: CGRect, scale: CGFloat, ink: NSColor, context: CGContext) {
        let text = String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), min(100, max(0, percent)))
        let bolt = charging ? NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) : nil
        let room = CGSize(width: interior.width - 3 * scale, height: interior.height - 3.4 * scale)
        func line(_ size: CGFloat) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold), .foregroundColor: ink]))
        }
        func extent(_ line: CTLine) -> (text: CGRect, bolt: CGSize, width: CGFloat) {
            let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            guard let bolt else { return (ink, .zero, ink.width) }
            let height = ink.height * 0.95
            let size = CGSize(width: bolt.size.width / max(1, bolt.size.height) * height, height: height)
            return (ink, size, ink.width + 0.8 * scale + size.width)
        }
        // Start from the height the shell allows and step down until the width fits too ("100" plus a bolt).
        var size = room.height / 0.72, fitted = line(size), measure = extent(fitted)
        while (measure.width > room.width || measure.text.height > room.height) && size > 5 {
            size -= 0.25; fitted = line(size); measure = extent(fitted)
        }
        let originX = (interior.midX - measure.width / 2).rounded()
        let textOrigin = CGPoint(x: originX - measure.text.minX, y: (interior.midY - measure.text.height / 2 - measure.text.minY).rounded())
        let boltFrame = CGRect(x: originX + measure.text.width + 0.8 * scale, y: interior.midY - measure.bolt.height / 2,
                               width: measure.bolt.width, height: measure.bolt.height)
        func mark(at offset: CGPoint, operation: NSCompositingOperation) {
            context.textPosition = CGPoint(x: textOrigin.x + offset.x, y: textOrigin.y + offset.y)
            CTLineDraw(fitted, context)
            if let bolt = bolt?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [ink])) {
                bolt.draw(in: boltFrame.offsetBy(dx: offset.x, dy: offset.y), from: .zero, operation: operation, fraction: 1)
            }
        }
        context.saveGState()
        context.clip(to: interior)
        context.textMatrix = .identity
        context.setBlendMode(.destinationOut)
        let halo = 0.8 * scale
        for dx in [-halo, 0, halo] { for dy in [-halo, 0, halo] { mark(at: CGPoint(x: dx, y: dy), operation: .destinationOut) } }
        context.setBlendMode(.normal)
        mark(at: .zero, operation: .sourceOver)
        context.restoreGState()
    }

    static func color(_ hex: String) -> NSColor? {
        guard let rgb = UInt32(hex, radix: 16) else { return nil }
        return NSColor(red: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

/// What a sprite draws in its icon slot. Existing sprites keep their SF Symbol.
public enum ReadoutIcon: Equatable, Sendable {
    case symbol(String)
    case battery(BatteryGlyph)

    public func width(forHeight height: CGFloat) -> CGFloat {
        switch self {
        case .symbol: height
        case .battery: BatteryGlyph.width(forHeight: height)
        }
    }
    /// The height the icon slot is laid out at; the width follows from it.
    public var slotHeight: CGFloat {
        switch self {
        case .symbol: 14
        case .battery(let glyph): glyph.slotHeight
        }
    }
    /// A reading-driven color (a low-battery alert, a colored cap) forces a non-template image;
    /// otherwise the sprite decides.
    public var forcesColor: Bool {
        if case .battery(let glyph) = self { glyph.forcesColor } else { false }
    }
}
