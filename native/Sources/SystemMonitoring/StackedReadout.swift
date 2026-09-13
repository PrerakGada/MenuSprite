import AppKit
import CoreText

public struct ReadoutColumn: Equatable, Sendable {
    public let label: String
    public let value: String
    /// Per-reading rule result. Nil preserves the sprite's fixed/automatic color.
    public let colorHex: String?
    public init(label: String, value: String, colorHex: String? = nil) {
        self.label = label; self.value = value; self.colorHex = colorHex
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
    }

    public static func layout(columns: [ReadoutColumn], config: SpriteConfiguration, height: CGFloat) -> Layout {
        let height = max(18, height)
        if config.layout == .inline { return inlineLayout(columns: columns, config: config, height: height) }
        if config.layout == .twoRows { return twoRowLayout(columns: columns, config: config, height: height) }
        let labelFont = NSFont.systemFont(ofSize: min(6.5, height * 0.27), weight: config.bold ? .bold : .medium)
        let labelHeight = config.showLabels ? ceil(columns.map { inkBounds($0.label, font: labelFont).height }.max() ?? 0) : 0
        let gap: CGFloat = config.showLabels ? 1.5 : 0
        var pointSize = min(16, max(8, config.fontSize))
        var valueFont = NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: config.bold ? .heavy : .regular)
        func lineHeight(_ font: NSFont) -> CGFloat { ceil(columns.map { inkBounds($0.value, font: font).height }.max() ?? 0) }
        while lineHeight(valueFont) + labelHeight + gap > height - 2 && pointSize > 8 {
            pointSize -= 0.5
            valueFont = NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: config.bold ? .heavy : .regular)
        }
        let valueHeight = lineHeight(valueFont)
        let bottom = floor((height - valueHeight - labelHeight - gap) / 2)
        let iconRect = config.showIcon ? CGRect(x: horizontalPadding, y: floor((height - 14) / 2), width: 14, height: 14) : .zero
        var x: CGFloat = config.showIcon ? iconRect.maxX + 5 : horizontalPadding
        var placements: [Placement] = []
        for column in columns {
            let valueWidth = ceil((column.value as NSString).size(withAttributes: [.font: valueFont]).width)
            let labelWidth = config.showLabels ? ceil((column.label as NSString).size(withAttributes: [.font: labelFont]).width) : 0
            let width = max(1, max(valueWidth, labelWidth))
            placements.append(Placement(
                label: config.showLabels ? CGRect(x: x, y: bottom + valueHeight + gap, width: width, height: labelHeight) : nil,
                value: CGRect(x: x, y: bottom, width: width, height: valueHeight)))
            x += width + 6
        }
        return Layout(size: CGSize(width: max(iconRect.maxX, x - 6) + horizontalPadding, height: height), columns: placements,
                      labelFont: labelFont, valueFont: valueFont, iconRect: iconRect)
    }

    private static func twoRowLayout(columns: [ReadoutColumn], config: SpriteConfiguration, height: CGFloat) -> Layout {
        let rowGap: CGFloat = 2
        let bandHeight = (height - 2 - rowGap) / 2
        let labelFont = NSFont.systemFont(ofSize: min(8, bandHeight), weight: config.bold ? .bold : .semibold)
        var pointSize = min(13, max(8, config.fontSize))
        var valueFont = NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: config.bold ? .heavy : .regular)
        while (columns.map { inkBounds($0.value, font: valueFont).height }.max() ?? 0) > bandHeight && pointSize > 8 {
            pointSize -= 0.5
            valueFont = NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: config.bold ? .heavy : .regular)
        }
        let iconRect = config.showIcon ? CGRect(x: horizontalPadding, y: floor((height - 14) / 2), width: 14, height: 14) : .zero
        var x: CGFloat = config.showIcon ? iconRect.maxX + 5 : horizontalPadding
        var placements: [Placement] = []
        // Consecutive pairs share one column, with the first reading on top.
        for first in stride(from: 0, to: columns.count, by: 2) {
            let pair = Array(columns[first..<min(first + 2, columns.count)])
            let labels = pair.map { config.showLabels ? ceil(inkBounds($0.label, font: labelFont).width) : 0 }
            let values = pair.map { ceil(inkBounds($0.value, font: valueFont).width) }
            let labelWidth = labels.max() ?? 0, valueWidth = values.max() ?? 0
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
                      labelFont: labelFont, valueFont: valueFont, iconRect: iconRect)
    }

    private static func inlineLayout(columns: [ReadoutColumn], config: SpriteConfiguration, height: CGFloat) -> Layout {
        let font = NSFont.monospacedDigitSystemFont(ofSize: config.fontSize, weight: config.bold ? .heavy : .regular)
        let iconRect = config.showIcon ? CGRect(x: horizontalPadding, y: floor((height - 14) / 2), width: 14, height: 14) : .zero
        var x = config.showIcon ? iconRect.maxX + 5 : horizontalPadding
        var placements: [Placement] = []
        for column in columns {
            let labelWidth = config.showLabels ? ceil((column.label as NSString).size(withAttributes: [.font: font]).width) : 0
            let valueBounds = inkBounds(column.value, font: font)
            let labelBounds = inkBounds(column.label, font: font)
            let valueWidth = ceil((column.value as NSString).size(withAttributes: [.font: font]).width)
            let label = config.showLabels ? CGRect(x: x, y: (height - labelBounds.height) / 2, width: labelWidth, height: labelBounds.height) : nil
            if config.showLabels { x += labelWidth + 4 }
            placements.append(.init(label: label, value: CGRect(x: x, y: (height - valueBounds.height) / 2, width: valueWidth, height: valueBounds.height)))
            x += valueWidth + 8
        }
        return Layout(size: CGSize(width: max(horizontalPadding, x - 8) + horizontalPadding, height: height),
                      columns: placements, labelFont: font, valueFont: font, iconRect: iconRect)
    }

    private static func inkBounds(_ text: String, font: NSFont) -> CGRect {
        CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])), [.useGlyphPathBounds])
    }
    private static func draw(_ text: NSAttributedString, in rect: CGRect) {
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: rect.midX - bounds.width / 2 - bounds.minX, y: rect.minY - bounds.minY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
    public static func image(columns: [ReadoutColumn], config: SpriteConfiguration, height: CGFloat) -> NSImage {
        let placement = layout(columns: columns, config: config, height: height)
        let iconHex = config.iconColorHex == "text" ? config.colorHex : config.iconColorHex
        let isTemplate = config.colorHex == "auto" && columns.allSatisfy { $0.colorHex == nil } && (!config.showIcon || iconHex == "auto")
        let ink = color(config.colorHex, fallback: isTemplate ? .black : .labelColor)
        let symbol = (NSImage(systemSymbolName: config.symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: nil))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color(iconHex, fallback: ink)]))
        let image = NSImage(size: placement.size, flipped: false) { _ in
            if config.showIcon, let symbol {
                let scale = min(placement.iconRect.width / max(1, symbol.size.width), placement.iconRect.height / max(1, symbol.size.height))
                let size = CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
                symbol.draw(in: CGRect(x: placement.iconRect.midX - size.width / 2,
                                       y: placement.iconRect.midY - size.height / 2, width: size.width, height: size.height))
            }
            for (column, frames) in zip(columns, placement.columns) {
                let columnInk = color(column.colorHex, fallback: ink)
                let percentOnly = config.colorRule == .usagePacePercent && column.colorHex != nil
                let textInk = percentOnly ? ink : columnInk
                if let rect = frames.label {
                    draw(NSAttributedString(string: column.label, attributes: [.font: placement.labelFont,
                        .foregroundColor: textInk.withAlphaComponent(percentOnly ? 1 : 0.9)]), in: rect)
                }
                draw(valueText(column.value, font: placement.valueFont, ink: textInk,
                               percentInk: percentOnly ? columnInk : nil), in: frames.value)
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
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            let hex = percentOnly ? config.colorHex : (column.colorHex ?? config.colorHex)
            if hex != "auto" { attributes[.foregroundColor] = color(hex, fallback: .labelColor) }
            result.append(NSAttributedString(string: prefix, attributes: attributes))
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
