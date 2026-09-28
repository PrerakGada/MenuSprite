import AppKit
import CoreText

public struct ReadoutColumn: Equatable, Sendable {
    public let label: String
    public let value: String
    /// Per-reading rule result. Nil preserves the sprite's fixed/automatic color.
    public let colorHex: String?
    /// The widest strings this reading can produce. The column reserves room for them so the
    /// menu-bar item keeps one width while the value changes (9% → 100%, KiB/s → MiB/s).
    public let widthTemplates: [String]
    /// The reading as a 0...1 fill for the level bar; nil for readings that are not percentages
    /// or not yet read, which the bar layout shows as text instead of guessing a level.
    public let level: Double?
    public init(label: String, value: String, colorHex: String? = nil, widthTemplates: [String] = [], level: Double? = nil) {
        self.label = label; self.value = value; self.colorHex = colorHex; self.widthTemplates = widthTemplates
        self.level = level.map { min(1, max(0, $0)) }
    }
}

/// One small native drawing shared by the menu-bar button and the editor preview.
/// It is produced only on an existing presentation update; there is no new timer or view host.
@MainActor
public enum StackedReadout {
    public static let horizontalPadding: CGFloat = 3
    public struct Placement {
        public let label: CGRect?
        public let value: CGRect
    }
    public struct Layout {
        public let size: CGSize
        public let columns: [Placement]
        public let labelFont: NSFont
        public let valueFont: NSFont
        public let iconRect: CGRect
        /// The width reserved for each value; pass back as `reserved` to keep it on the next draw.
        public let valueWidths: [CGFloat]
    }

    /// Advance width, so tabular digits hold fixed slots; the value is never narrower than its
    /// templates or than what an earlier draw already reserved for it.
    private static func valueWidth(_ column: ReadoutColumn, font: NSFont, reserved: CGFloat) -> (text: CGFloat, slot: CGFloat) {
        func advance(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        let text = advance(column.value)
        return (text, max(text, reserved, column.widthTemplates.map(advance).max() ?? 0))
    }

    public static func layout(columns: [ReadoutColumn], config: SpriteConfiguration, height: CGFloat,
                              icon: ReadoutIcon? = nil, reserved: [CGFloat] = []) -> Layout {
        let base = leadingIconLayout(columns: columns, config: config, height: height, icon: icon, reserved: reserved)
        // A battery showing its charge inside has nothing else to lay out: the item is the glyph.
        if columns.isEmpty && config.showIcon {
            return Layout(size: CGSize(width: base.iconRect.maxX + horizontalPadding, height: base.size.height), columns: [],
                          labelFont: base.labelFont, valueFont: base.valueFont, iconRect: base.iconRect, valueWidths: [])
        }
        guard config.iconTrailing else { return base }
        // Move the icon to the far end: the readings shift left by the room the icon and its gap took.
        let offset = base.iconRect.maxX + iconGap(config) - horizontalPadding
        var iconRect = base.iconRect
        iconRect.origin.x = base.size.width - horizontalPadding - iconRect.width
        return Layout(size: base.size, columns: base.columns.map {
            Placement(label: $0.label?.offsetBy(dx: -offset, dy: 0), value: $0.value.offsetBy(dx: -offset, dy: 0))
        }, labelFont: base.labelFont, valueFont: base.valueFont, iconRect: iconRect, valueWidths: base.valueWidths)
    }

    private static func iconGap(_ config: SpriteConfiguration) -> CGFloat { config.layout == .bar ? 4 : 5 }
    private static func iconSlot(config: SpriteConfiguration, icon: ReadoutIcon, height: CGFloat) -> CGRect {
        guard config.showIcon else { return .zero }
        let side = icon.slotHeight
        return CGRect(x: horizontalPadding, y: floor((height - side) / 2), width: icon.width(forHeight: side), height: side)
    }

    private static func leadingIconLayout(columns: [ReadoutColumn], config: SpriteConfiguration, height: CGFloat,
                                          icon: ReadoutIcon?, reserved: [CGFloat]) -> Layout {
        let height = max(18, height)
        let icon = icon ?? .symbol(config.symbol)
        let reserved = reserved.count == columns.count ? reserved : Array(repeating: 0, count: columns.count)
        if config.layout == .inline { return inlineLayout(columns: columns, config: config, height: height, icon: icon, reserved: reserved) }
        if config.layout == .twoRows { return twoRowLayout(columns: columns, config: config, height: height, icon: icon, reserved: reserved) }
        if config.layout == .bar { return barLayout(columns: columns, config: config, height: height, icon: icon, reserved: reserved) }
        let gap: CGFloat = config.showLabels ? 1.5 : 0
        // The label carries part of the reading, so it is given real size and the value gives up a
        // point and a half in return — which also narrows the item.
        var pointSize = min(16, max(8, config.fontSize - (config.showLabels ? 1.5 : 0)))
        var valueFont = NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: config.bold ? .heavy : .regular)
        func lineHeight(_ font: NSFont) -> CGFloat { ceil(columns.map { inkBounds($0.value, font: font).height }.max() ?? 0) }
        func font(_ size: CGFloat) -> NSFont { NSFont.systemFont(ofSize: size, weight: config.bold ? .bold : .medium) }
        // Each value's own width, so a label is never allowed to widen the item past it.
        let valueSlots = zip(columns, reserved).map { valueWidth($0, font: valueFont, reserved: $1).slot }
        // The largest label that fits both the bar's height and the width the numbers already need.
        // A short label ("CPU") takes the whole increase; a long one ("Claude") takes what is free.
        let labelFont = config.showLabels ? (stride(from: 8.5, through: 6.5, by: -0.5).first { size in
            let candidate = font(size)
            guard lineHeight(valueFont) + ceil(inkBounds("Xg", font: candidate).height) + gap <= height - 2 else { return false }
            return zip(columns, valueSlots).allSatisfy { column, slot in
                ceil((column.label as NSString).size(withAttributes: [.font: candidate]).width) <= slot
            }
        }.map(font) ?? font(6.5)) : font(6.5)
        let labelHeight = config.showLabels ? ceil(columns.map { inkBounds($0.label, font: labelFont).height }.max() ?? 0) : 0
        while lineHeight(valueFont) + labelHeight + gap > height - 2 && pointSize > 8 {
            pointSize -= 0.5
            valueFont = NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: config.bold ? .heavy : .regular)
        }
        let valueHeight = lineHeight(valueFont)
        let bottom = floor((height - valueHeight - labelHeight - gap) / 2)
        let iconRect = iconSlot(config: config, icon: icon, height: height)
        var x: CGFloat = config.showIcon ? iconRect.maxX + iconGap(config) : horizontalPadding
        var placements: [Placement] = [], slots: [CGFloat] = []
        for (column, reserve) in zip(columns, reserved) {
            let value = valueWidth(column, font: valueFont, reserved: reserve)
            let labelWidth = config.showLabels ? ceil((column.label as NSString).size(withAttributes: [.font: labelFont]).width) : 0
            let width = max(1, max(value.slot, labelWidth))
            // Labels stay centred; values are right-aligned so digits keep their places.
            placements.append(Placement(
                label: config.showLabels ? CGRect(x: x, y: bottom + valueHeight + gap, width: width, height: labelHeight) : nil,
                value: CGRect(x: x + width - value.text, y: bottom, width: value.text, height: valueHeight)))
            slots.append(value.slot)
            x += width + 6
        }
        return Layout(size: CGSize(width: max(iconRect.maxX, x - 6) + horizontalPadding, height: height), columns: placements,
                      labelFont: labelFont, valueFont: valueFont, iconRect: iconRect, valueWidths: slots)
    }

    private static func twoRowLayout(columns: [ReadoutColumn], config: SpriteConfiguration, height: CGFloat, icon: ReadoutIcon,
                                     reserved: [CGFloat]) -> Layout {
        let rowGap: CGFloat = 2
        let bandHeight = (height - 2 - rowGap) / 2
        let labelFont = NSFont.systemFont(ofSize: min(8, bandHeight), weight: config.bold ? .bold : .semibold)
        var pointSize = min(13, max(8, config.fontSize))
        var valueFont = NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: config.bold ? .heavy : .regular)
        while (columns.map { inkBounds($0.value, font: valueFont).height }.max() ?? 0) > bandHeight && pointSize > 8 {
            pointSize -= 0.5
            valueFont = NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: config.bold ? .heavy : .regular)
        }
        let iconRect = iconSlot(config: config, icon: icon, height: height)
        var x: CGFloat = config.showIcon ? iconRect.maxX + iconGap(config) : horizontalPadding
        var placements: [Placement] = [], slots: [CGFloat] = []
        // Consecutive pairs share one column, with the first reading on top.
        for first in stride(from: 0, to: columns.count, by: 2) {
            let range = first..<min(first + 2, columns.count)
            let pair = Array(columns[range])
            let labels = pair.map { config.showLabels ? ceil(inkBounds($0.label, font: labelFont).width) : 0 }
            let measured = zip(pair, reserved[range]).map { valueWidth($0, font: valueFont, reserved: $1) }
            let values = measured.map(\.text)
            slots += measured.map(\.slot)
            let labelWidth = labels.max() ?? 0, valueWidth = measured.map(\.slot).max() ?? 0
            let labelGap: CGFloat = config.showLabels ? 4 : 0
            let width = max(1, labelWidth + labelGap + valueWidth)
            for (row, column) in pair.enumerated() {
                let bandY: CGFloat = row == 0 ? 1 + bandHeight + rowGap : 1
                let valueHeight = ceil(inkBounds(column.value, font: valueFont).height)
                let labelHeight = ceil(inkBounds(column.label, font: labelFont).height)
                placements.append(.init(
                    label: config.showLabels ? CGRect(x: x, y: bandY + (bandHeight - labelHeight) / 2, width: labels[row], height: labelHeight) : nil,
                    value: CGRect(x: x + width - values[row], y: bandY + (bandHeight - valueHeight) / 2, width: values[row], height: valueHeight)))
            }
            x += width + 7
        }
        return Layout(size: CGSize(width: max(horizontalPadding, x - 7) + horizontalPadding, height: height), columns: placements,
                      labelFont: labelFont, valueFont: valueFont, iconRect: iconRect, valueWidths: slots)
    }

    private static func inlineLayout(columns: [ReadoutColumn], config: SpriteConfiguration, height: CGFloat, icon: ReadoutIcon,
                                     reserved: [CGFloat]) -> Layout {
        let font = NSFont.monospacedDigitSystemFont(ofSize: config.fontSize, weight: config.bold ? .heavy : .regular)
        let iconRect = iconSlot(config: config, icon: icon, height: height)
        var x = config.showIcon ? iconRect.maxX + iconGap(config) : horizontalPadding
        var placements: [Placement] = [], slots: [CGFloat] = []
        for (column, reserve) in zip(columns, reserved) {
            let labelWidth = config.showLabels ? ceil((column.label as NSString).size(withAttributes: [.font: font]).width) : 0
            let valueBounds = inkBounds(column.value, font: font)
            let labelBounds = inkBounds(column.label, font: font)
            let value = valueWidth(column, font: font, reserved: reserve)
            let label = config.showLabels ? CGRect(x: x, y: (height - labelBounds.height) / 2, width: labelWidth, height: labelBounds.height) : nil
            if config.showLabels { x += labelWidth + 4 }
            placements.append(.init(label: label, value: CGRect(x: x + value.slot - value.text, y: (height - valueBounds.height) / 2,
                                                                width: value.text, height: valueBounds.height)))
            slots.append(value.slot)
            x += value.slot + 8
        }
        return Layout(size: CGSize(width: max(horizontalPadding, x - 8) + horizontalPadding, height: height),
                      columns: placements, labelFont: font, valueFont: font, iconRect: iconRect, valueWidths: slots)
    }

    /// Level-bar geometry: a thin upright capsule per percentage reading, the height of a menu-bar glyph.
    public static let barWidth: CGFloat = 9
    /// The bar takes the menu bar's whole height apart from a point at each edge, so the stroke is not clipped.
    public static func barHeight(forHeight height: CGFloat) -> CGFloat { height - 2 }

    /// Each percentage reading becomes a standing bar; any other reading keeps its value as text,
    /// so a mixed sprite never shows a bar for a number that has no full scale.
    private static func barLayout(columns: [ReadoutColumn], config: SpriteConfiguration, height: CGFloat, icon: ReadoutIcon,
                                  reserved: [CGFloat]) -> Layout {
        let font = NSFont.monospacedDigitSystemFont(ofSize: config.fontSize, weight: config.bold ? .heavy : .regular)
        let iconRect = iconSlot(config: config, icon: icon, height: height)
        var x = config.showIcon ? iconRect.maxX + iconGap(config) : horizontalPadding
        var placements: [Placement] = [], slots: [CGFloat] = []
        for (column, reserve) in zip(columns, reserved) {
            if column.level != nil {
                placements.append(.init(label: nil, value: CGRect(x: x, y: 1, width: barWidth, height: barHeight(forHeight: height))))
                slots.append(barWidth)
                x += barWidth + 3
            } else {
                let bounds = inkBounds(column.value, font: font)
                let value = valueWidth(column, font: font, reserved: reserve)
                placements.append(.init(label: nil, value: CGRect(x: x + value.slot - value.text, y: (height - bounds.height) / 2,
                                                                  width: value.text, height: bounds.height)))
                slots.append(value.slot)
                x += value.slot + 6
            }
        }
        let gap: CGFloat = columns.last?.level != nil ? 3 : 6
        return Layout(size: CGSize(width: max(horizontalPadding, x - gap) + horizontalPadding, height: height),
                      columns: placements, labelFont: font, valueFont: font, iconRect: iconRect, valueWidths: slots)
    }

    /// A standing battery: a faint outline and a fill rising from the bottom.
    private static func drawBar(level: Double, in rect: CGRect, outline: NSColor, fill: NSColor) {
        // A near-square shell and a square fill, so the fill line reads as an exact level.
        let shell = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 1, yRadius: 1)
        outline.withAlphaComponent(0.45).setStroke()
        shell.lineWidth = 1
        shell.stroke()
        let inner = rect.insetBy(dx: 1.5, dy: 1.5)
        guard level > 0 else { return }
        // A live reading always shows at least a sliver, so 1% is distinguishable from "no bar".
        fill.setFill()
        CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: max(1.5, inner.height * level)).fill()
    }

    private static func inkBounds(_ text: String, font: NSFont) -> CGRect {
        CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])), [.useGlyphPathBounds])
    }
    /// Labels are centred on their ink. Values sit at their typographic origin (their rect is
    /// exactly their advance width), so a narrow "1" never nudges its neighbours sideways.
    private static func draw(_ text: NSAttributedString, in rect: CGRect, byAdvance: Bool = false) {
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.textMatrix = .identity
        let x = byAdvance ? rect.maxX - CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) : rect.midX - bounds.width / 2 - bounds.minX
        context.textPosition = CGPoint(x: x, y: rect.minY - bounds.minY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
    public static func image(columns: [ReadoutColumn], config: SpriteConfiguration, height: CGFloat,
                             icon: ReadoutIcon? = nil, reserved: [CGFloat] = []) -> NSImage {
        let icon = icon ?? .symbol(config.symbol)
        let placement = layout(columns: columns, config: config, height: height, icon: icon, reserved: reserved)
        let iconHex = config.iconColorHex == "text" ? config.colorHex : config.iconColorHex
        let isTemplate = config.colorHex == "auto" && columns.allSatisfy { $0.colorHex == nil }
            && (!config.showIcon || (iconHex == "auto" && !icon.forcesColor))
        let ink = color(config.colorHex, fallback: isTemplate ? .black : .labelColor)
        let iconInk = color(iconHex, fallback: ink)
        var symbol: NSImage?
        if case .symbol(let name) = icon {
            symbol = (NSImage(systemSymbolName: name, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: nil))?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [iconInk]))
        }
        let image = NSImage(size: placement.size, flipped: false) { _ in
            if config.showIcon, case .battery(let glyph) = icon {
                glyph.draw(in: placement.iconRect, ink: iconInk)
            }
            if config.showIcon, let symbol {
                let scale = min(placement.iconRect.width / max(1, symbol.size.width), placement.iconRect.height / max(1, symbol.size.height))
                let size = CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
                symbol.draw(in: CGRect(x: placement.iconRect.midX - size.width / 2,
                                       y: placement.iconRect.midY - size.height / 2, width: size.width, height: size.height))
            }
            for (column, frames) in zip(columns, placement.columns) {
                let columnInk = color(column.colorHex, fallback: ink)
                if config.layout == .bar, let level = column.level {
                    drawBar(level: level, in: frames.value, outline: ink, fill: columnInk)
                    continue
                }
                let percentOnly = config.colorRule == .usagePacePercent && column.colorHex != nil
                let labelOnly = (config.colorRule == .memoryPressure || config.colorRule == .powerDraw) && column.colorHex != nil
                let textInk = percentOnly || labelOnly ? ink : columnInk
                if let rect = frames.label {
                    draw(NSAttributedString(string: column.label, attributes: [.font: placement.labelFont,
                        .foregroundColor: labelOnly ? columnInk : textInk.withAlphaComponent(percentOnly ? 1 : 0.9)]), in: rect)
                }
                draw(valueText(column.value, font: placement.valueFont, ink: textInk,
                               percentInk: percentOnly ? columnInk : nil), in: frames.value, byAdvance: true)
            }
            return true
        }
        image.isTemplate = isTemplate
        return image
    }

    /// Shared by inline status items and their live editor preview.
    public static func attributedText(columns: [ReadoutColumn], config: SpriteConfiguration) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let font = NSFont.monospacedDigitSystemFont(ofSize: config.fontSize, weight: config.bold ? .heavy : .regular)
        let visible = config.enabled ? columns : [ReadoutColumn(label: "", value: "Paused")]
        for (index, column) in visible.enumerated() {
            let prefix = (index == 0 ? "" : "  ") + (config.enabled && config.showLabels ? column.label + " " : "")
            let percentOnly = config.colorRule == .usagePacePercent && column.colorHex != nil
            let labelOnly = (config.colorRule == .memoryPressure || config.colorRule == .powerDraw) && column.colorHex != nil
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            let hex = percentOnly || labelOnly ? config.colorHex : (column.colorHex ?? config.colorHex)
            if hex != "auto" { attributes[.foregroundColor] = color(hex, fallback: .labelColor) }
            var prefixAttributes = attributes
            if labelOnly { prefixAttributes[.foregroundColor] = color(column.colorHex, fallback: .labelColor) }
            result.append(NSAttributedString(string: prefix, attributes: prefixAttributes))
            result.append(valueText(column.value, font: font, ink: attributes[.foregroundColor] as? NSColor,
                                    percentInk: percentOnly ? color(column.colorHex, fallback: .labelColor) : nil))
        }
        return result
    }

    /// Color only the percentage suffix; digits and any labels keep the base text color.
    private static func valueText(_ value: String, font: NSFont, ink: NSColor?, percentInk: NSColor?) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let ink { attributes[.foregroundColor] = ink }
        let result = NSMutableAttributedString(string: value, attributes: attributes)
        if let percentInk, value.hasSuffix("%") {
            result.addAttribute(.foregroundColor, value: percentInk, range: NSRange(location: result.length - 1, length: 1))
        }
        return result
    }

    private static func color(_ hex: String?, fallback: NSColor) -> NSColor {
        guard let hex, let rgb = UInt32(hex, radix: 16) else { return fallback }
        return NSColor(red: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}
