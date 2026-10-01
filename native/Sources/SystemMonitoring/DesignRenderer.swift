import AppKit
import CoreText

/// Draws a `SpriteDesign` at menu-bar height: the status item, the studio canvas and the sprite list
/// all use this one drawing. Rows place children side by side, columns stack them (packed and
/// centred, or in equal bands); text shrinks to fit the bar rather than overflowing it.
@MainActor
public enum DesignRenderer {
    /// One node as drawn: its frame in the image (y up) and what it resolved to.
    public struct Placed: Equatable, Sendable {
        public let id: String
        public let kind: DesignNodeKind
        public let frame: CGRect
        public let text: String
        public let color: String
        public let fontSize: Double
    }
    public struct Output {
        public let image: NSImage
        public let size: CGSize
        /// Every visible node, parents before children.
        public let placed: [Placed]
        /// The slot width each text used; pass back as `reserved` to hold it on the next draw.
        public let slotWidths: [String: CGFloat]
        /// Changes only when something drawn changes, so a caller can skip an identical redraw.
        public let signature: String
        public let accessibilityText: String
        public let isTemplate: Bool
    }

    /// The resolved state of one node before layout.
    private struct Resolved {
        var node: DesignNode
        var children: [Resolved]
        var text: String
        var segmentWidths: (NSFont) -> CGFloat
        var color: String
        var opacity: Double
        var symbol: String
        var level: Double?
        var size: Double
    }

    public static func render(_ design: SpriteDesign, values: DesignValues, height: CGFloat,
                              reserved: [String: CGFloat] = [:], battery: BatteryGlyph? = nil,
                              overrides precomputed: [String: NodeOverride]? = nil) -> Output {
        let overrides = precomputed ?? SpriteRules.evaluate(design, values: values)
        let height = max(18, height)
        guard var root = resolve(design.root, design: design, values: values, overrides: overrides, inherited: "auto", fade: 1) else {
            let empty = NSImage(size: NSSize(width: 6, height: height))
            return Output(image: empty, size: empty.size, placed: [], slotWidths: [:], signature: "", accessibilityText: "", isTemplate: true)
        }
        let band = height - 2
        fit(&root, band: band, reserved: reserved)
        let measured = measure(root, band: band, reserved: reserved)
        let size = CGSize(width: max(6, ceil(measured.width)), height: height)
        var placed: [Placed] = []
        var slots: [String: CGFloat] = [:]
        var draws: [(Resolved, CGRect, NSColor?)] = []
        place(root, in: CGRect(x: 0, y: 1, width: size.width, height: band), band: band, reserved: reserved,
              parentInk: nil, placed: &placed, slots: &slots, draws: &draws)

        let forcesColor = battery?.forcesColor == true && design.root.flattened.contains { $0.kind == .battery && !$0.style.hidden }
        let isTemplate = !forcesColor && draws.allSatisfy { $0.0.color == "auto" }
        let image = NSImage(size: size, flipped: false) { _ in
            for (item, rect, parentInk) in draws {
                draw(item, in: rect, template: isTemplate, parentInk: parentInk, battery: battery)
            }
            return true
        }
        image.isTemplate = isTemplate
        let glyph = battery.map { "\($0)" } ?? ""
        let signature = placed.map { "\($0.id):\($0.text):\($0.color):\($0.fontSize):\(Int($0.frame.width))" }.joined(separator: "|")
            + draws.map { item in "\(item.0.level ?? -1)|\(item.0.symbol)|\(item.0.opacity)" }.joined() + glyph
        let accessible = placed.filter { $0.kind == .text }.map(\.text).joined(separator: " ")
        return Output(image: image, size: size, placed: placed, slotWidths: slots, signature: signature,
                      accessibilityText: accessible, isTemplate: isTemplate)
    }

    // MARK: Resolve

    /// `fade` is the product of the enclosing rows' and columns' opacity: a container draws nothing itself,
    /// so its opacity reaches the bar through its pieces (a rule dimming the whole sprite dims all of it).
    private static func resolve(_ node: DesignNode, design: SpriteDesign, values: DesignValues,
                                overrides: [String: NodeOverride], inherited: String, fade: Double) -> Resolved? {
        let override = overrides[node.id]
        if override?.hidden ?? node.style.hidden { return nil }
        let own = override?.color ?? node.style.color
        let color = own == "inherit" ? inherited : own
        let opacity = min(1, max(0.05, override?.opacity ?? node.style.opacity)) * fade
        let children = node.kind.isContainer
            ? node.children.compactMap { resolve($0, design: design, values: values, overrides: overrides, inherited: color, fade: opacity) } : []
        if node.kind.isContainer && children.isEmpty { return nil }
        let segments = override?.text ?? node.segments
        let text = segments.map { segment -> String in
            switch segment {
            case .literal(let text): text
            case .value(let id): design.variable(id).map(values.formatted) ?? "?"
            }
        }.joined()
        // The widest this text normally gets: each value at its widest template, literals as they are.
        let pieces: [(String, [String])] = segments.map { segment in
            guard case .value(let id) = segment else { return (TextTemplate.string([segment]), []) }
            let variable = design.variable(id)
            return (variable.map(values.formatted) ?? "?", variable.map(values.widthTemplates) ?? [])
        }
        let templateWidth: (NSFont) -> CGFloat = { font in
            pieces.reduce(0) { sum, piece in sum + ([piece.0] + piece.1).map { advance($0, font) }.max()! }
        }
        var level: Double?
        if node.kind == .bar, let variable = node.variable.flatMap(design.variable), let number = values.number(variable) {
            level = min(1, max(0, number / max(0.0001, node.style.maximum)))
        }
        let defaultSize: Double = switch node.kind { case .icon: 14; case .bar: 9; default: 12 }
        return Resolved(node: node, children: children, text: node.kind == .text ? text : "", segmentWidths: templateWidth,
                        color: color, opacity: opacity,
                        symbol: override?.symbol ?? node.symbol, level: level,
                        size: min(40, max(4, node.style.size ?? defaultSize)))
    }

    // MARK: Fonts and fitting

    private static func font(_ item: Resolved) -> NSFont {
        let weight: NSFont.Weight = switch item.node.style.weight {
        case .regular: .regular; case .medium: .medium; case .semibold: .semibold; case .bold: .bold; case .heavy: .heavy
        }
        return item.node.style.tabular ? .monospacedDigitSystemFont(ofSize: item.size, weight: weight)
            : .systemFont(ofSize: item.size, weight: weight)
    }
    private static func advance(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
    private static func inkBounds(_ text: String, _ font: NSFont) -> CGRect {
        CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])),
                                   [.useGlyphPathBounds])
    }
    private static func inkHeight(_ item: Resolved) -> CGFloat {
        ceil(inkBounds(item.text.isEmpty ? "0" : item.text, font(item)).height)
    }

    /// Shrinks text until each container fits its band: labels marked shrink-to-fit give way first
    /// (and never widen their column), then the largest text, half a point at a time.
    private static func fit(_ item: inout Resolved, band: CGFloat, reserved: [String: CGFloat]) {
        switch item.node.kind {
        case .text:
            while inkHeight(item) > band && item.size > 6 { item.size -= 0.5 }
        case .row:
            for index in item.children.indices { fit(&item.children[index], band: band, reserved: reserved) }
        case .column:
            let n = CGFloat(item.children.count)
            let gap = CGFloat(item.node.style.gap)
            if item.node.style.justify == .even {
                let child = (band - gap * (n - 1)) / n
                let before = textSizes(item)
                for index in item.children.indices { fit(&item.children[index], band: child, reserved: reserved) }
                // Text that starts at one size across the bands ends at one size, as the two-row
                // readout drew it: "3757 rpm" has a descender and "67°C" does not, so fitting each
                // alone left the temperature larger than the fan speed.
                let after = textSizes(item)
                var smallest: [Double: Double] = [:]
                for (path, size) in before { smallest[size] = min(smallest[size] ?? .infinity, after[path] ?? size) }
                for (path, size) in before { setSize(&item, path[...], smallest[size] ?? size) }
                return
            }
            for index in item.children.indices { fit(&item.children[index], band: band, reserved: reserved) }
            // A shrink-to-fit label is no wider than the widest other child.
            let others = item.children.filter { !($0.node.kind == .text && $0.node.style.shrinkToFit) }
            let widest = others.map { measure($0, band: band, reserved: reserved).width }.max() ?? .infinity
            for index in item.children.indices where item.children[index].node.kind == .text && item.children[index].node.style.shrinkToFit {
                while item.children[index].size > 6.5,
                      measure(item.children[index], band: band, reserved: reserved).width > widest { item.children[index].size -= 0.5 }
            }
            var guardCount = 0
            while measure(item, band: band, reserved: reserved).height > band && guardCount < 200 {
                guardCount += 1
                if let index = item.children.indices.first(where: {
                    item.children[$0].node.kind == .text && item.children[$0].node.style.shrinkToFit && item.children[$0].size > 6.5 }) {
                    item.children[index].size -= 0.5
                } else if !shrinkLargest(&item, floor: 6) { break }
            }
        default: break
        }
    }
    /// The size of every text beneath `item`, by its path of child indices.
    private static func textSizes(_ item: Resolved) -> [[Int]: Double] {
        var sizes: [[Int]: Double] = [:]
        func visit(_ node: Resolved, _ path: [Int]) {
            if node.node.kind == .text { sizes[path] = node.size }
            for (index, child) in node.children.enumerated() { visit(child, path + [index]) }
        }
        visit(item, [])
        return sizes
    }
    private static func setSize(_ node: inout Resolved, _ path: ArraySlice<Int>, _ size: Double) {
        guard let first = path.first else { node.size = size; return }
        setSize(&node.children[first], path.dropFirst(), size)
    }
    /// Reduces the largest text beneath `item` by half a point; false when nothing can shrink.
    private static func shrinkLargest(_ item: inout Resolved, floor: Double) -> Bool {
        var best: (path: [Int], size: Double)?
        func visit(_ node: Resolved, _ path: [Int]) {
            if node.node.kind == .text, node.size > floor, node.size > (best?.size ?? 0) { best = (path, node.size) }
            for (index, child) in node.children.enumerated() { visit(child, path + [index]) }
        }
        visit(item, [])
        guard let path = best?.path else { return false }
        func apply(_ node: inout Resolved, _ rest: ArraySlice<Int>) {
            guard let first = rest.first else { node.size -= 0.5; return }
            apply(&node.children[first], rest.dropFirst())
        }
        apply(&item, path[...])
        return true
    }

    // MARK: Measure

    /// Tabular text holds its widest template (digits keep their places); other text is as wide as its ink.
    private static func slot(_ item: Resolved, reserved: [String: CGFloat]) -> CGFloat {
        let font = font(item)
        guard item.node.style.tabular else { return max(1, ceil(inkBounds(item.text, font).width)) }
        return max(1, advance(item.text, font), item.segmentWidths(font), reserved[item.node.id] ?? 0)
    }

    private static func measure(_ item: Resolved, band: CGFloat, reserved: [String: CGFloat]) -> CGSize {
        let style = item.node.style
        switch item.node.kind {
        case .text:
            return CGSize(width: slot(item, reserved: reserved), height: inkHeight(item))
        case .icon:
            let side = min(band, CGFloat(item.size))
            return CGSize(width: side, height: side)
        case .battery:
            // The glyph grows a point when it carries the charge, as the status item always drew it.
            let side = min(band, style.chargeInside ? 15 : 14)
            return CGSize(width: BatteryGlyph.width(forHeight: side), height: side)
        case .bar:
            return CGSize(width: CGFloat(item.size), height: band)
        case .row:
            let sizes = item.children.map { measure($0, band: band, reserved: reserved) }
            return CGSize(width: sizes.map(\.width).reduce(0, +) + CGFloat(style.gap) * CGFloat(max(0, sizes.count - 1)) + 2 * CGFloat(style.padding),
                          height: sizes.map(\.height).max() ?? 0)
        case .column:
            let n = item.children.count
            let gap = CGFloat(style.gap)
            if style.justify == .even {
                let child = (band - gap * CGFloat(n - 1)) / CGFloat(n)
                let sizes = item.children.map { measure($0, band: child, reserved: reserved) }
                return CGSize(width: (sizes.map(\.width).max() ?? 0) + 2 * CGFloat(style.padding), height: band)
            }
            let sizes = item.children.map { measure($0, band: band, reserved: reserved) }
            return CGSize(width: (sizes.map(\.width).max() ?? 0) + 2 * CGFloat(style.padding),
                          height: sizes.map(\.height).reduce(0, +) + gap * CGFloat(max(0, n - 1)))
        }
    }

    // MARK: Place

    private static func place(_ item: Resolved, in rect: CGRect, band: CGFloat, reserved: [String: CGFloat], parentInk: String?,
                              placed: inout [Placed], slots: inout [String: CGFloat], draws: inout [(Resolved, CGRect, NSColor?)]) {
        let style = item.node.style
        let size = measure(item, band: band, reserved: reserved)
        var frame: CGRect
        switch item.node.kind {
        case .row, .column:
            frame = rect
        default:
            // Leaves sit in the middle of what they were given, horizontally by their alignment.
            let x: CGFloat = switch style.align {
            case .leading: rect.minX
            case .center: rect.midX - size.width / 2
            case .trailing: rect.maxX - size.width
            }
            let y = item.node.kind == .text ? rect.midY - size.height / 2 : floor(rect.midY - size.height / 2)
            frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        }
        placed.append(Placed(id: item.node.id, kind: item.node.kind, frame: frame, text: item.text, color: item.color, fontSize: item.size))

        switch item.node.kind {
        case .text:
            slots[item.node.id] = size.width
            draws.append((item, frame, nil))
        case .icon, .battery, .bar:
            draws.append((item, frame, parentInk.map { ink(for: $0, template: false) }))
        case .row:
            let widths = item.children.map { measure($0, band: band, reserved: reserved).width }
            let inner = rect.insetBy(dx: CGFloat(style.padding), dy: 0)
            let content = widths.reduce(0, +) + CGFloat(style.gap) * CGFloat(max(0, widths.count - 1))
            let extra = max(0, inner.width - content)
            var gap = CGFloat(style.gap)
            var x: CGFloat
            switch style.justify {
            case .start: x = inner.minX
            case .end: x = inner.maxX - content
            case .spaceBetween where widths.count > 1:
                x = inner.minX; gap += extra / CGFloat(widths.count - 1)
            case .even where widths.count > 1:
                gap += extra / CGFloat(widths.count + 1); x = inner.minX + extra / CGFloat(widths.count + 1)
            default: x = inner.minX + extra / 2
            }
            for (child, width) in zip(item.children, widths) {
                place(child, in: CGRect(x: x, y: rect.minY, width: width, height: rect.height), band: rect.height, reserved: reserved,
                      parentInk: item.color, placed: &placed, slots: &slots, draws: &draws)
                x += width + gap
            }
        case .column:
            let inner = rect.insetBy(dx: CGFloat(style.padding), dy: 0)
            let gap = CGFloat(style.gap)
            let n = CGFloat(item.children.count)
            if style.justify == .even {
                let child = (rect.height - gap * (n - 1)) / n
                var top = rect.maxY
                for child_ in item.children {
                    let frame = columnChildFrame(child_, inner: inner, y: top - child, height: child, band: child, reserved: reserved)
                    place(child_, in: frame, band: child, reserved: reserved, parentInk: item.color,
                          placed: &placed, slots: &slots, draws: &draws)
                    top -= child + gap
                }
            } else {
                let heights = item.children.map { measure($0, band: band, reserved: reserved).height }
                let total = heights.reduce(0, +) + gap * (n - 1)
                var top: CGFloat = switch style.justify {
                case .start: rect.maxY
                case .end: rect.minY + total
                default: floor(rect.midY - total / 2) + total
                }
                if style.justify == .spaceBetween, n > 1 { top = rect.maxY }
                let spread = style.justify == .spaceBetween && n > 1 ? (rect.height - total) / (n - 1) : 0
                for (child, height) in zip(item.children, heights) {
                    let frame = columnChildFrame(child, inner: inner, y: top - height, height: height, band: band, reserved: reserved)
                    place(child, in: frame, band: band, reserved: reserved, parentInk: item.color,
                          placed: &placed, slots: &slots, draws: &draws)
                    top -= height + gap + spread
                }
            }
        }
    }
    /// A row inside a column stretches across it; anything else keeps its width at its alignment.
    private static func columnChildFrame(_ child: Resolved, inner: CGRect, y: CGFloat, height: CGFloat, band: CGFloat,
                                         reserved: [String: CGFloat]) -> CGRect {
        if child.node.kind == .row || child.node.kind == .column { return CGRect(x: inner.minX, y: y, width: inner.width, height: height) }
        let width = measure(child, band: band, reserved: reserved).width
        let x: CGFloat = switch child.node.style.align {
        case .leading: inner.minX
        case .center: inner.midX - width / 2
        case .trailing: inner.maxX - width
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: Draw

    public static func ink(for hex: String, template: Bool) -> NSColor {
        guard hex != "auto", hex != "inherit", let color = SpriteColors.color(hex) else { return template ? .black : .labelColor }
        return color
    }

    private static func draw(_ item: Resolved, in rect: CGRect, template: Bool, parentInk: NSColor?, battery: BatteryGlyph?) {
        let color = ink(for: item.color, template: template).withAlphaComponent(item.opacity)
        switch item.node.kind {
        case .text:
            let font = font(item)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: item.text, attributes: [.font: font, .foregroundColor: color]))
            let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            let typographic = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            // Values stand on their advance at the slot's trailing edge so digits keep their places;
            // other text is centred on its ink.
            let tabular = item.node.style.tabular
            let x: CGFloat = switch item.node.style.align {
            case .trailing: tabular ? rect.maxX - typographic : rect.maxX - bounds.maxX
            case .leading: tabular ? rect.minX : rect.minX - bounds.minX
            case .center: rect.midX - bounds.width / 2 - bounds.minX
            }
            context.saveGState()
            context.textMatrix = .identity
            // The frame is the ink's height rounded up; the ink stands on its bottom edge.
            context.textPosition = CGPoint(x: x, y: rect.minY - bounds.minY)
            CTLineDraw(line, context)
            context.restoreGState()
        case .icon:
            // Drawn in monochrome and then filled with the colour where it has ink: a one-colour palette
            // would paint every layer alike, so a ".fill" symbol's inner mark (the tick in
            // checkmark.circle.fill) would vanish into a solid disc instead of staying cut out.
            guard let symbol = (NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: nil))?
                .withSymbolConfiguration(.preferringMonochrome()),
                  let context = NSGraphicsContext.current?.cgContext else { return }
            let scale = min(rect.width / max(1, symbol.size.width), rect.height / max(1, symbol.size.height))
            let size = CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            let target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
            context.saveGState()
            context.beginTransparencyLayer(in: target, auxiliaryInfo: nil)
            symbol.draw(in: target)
            context.setBlendMode(.sourceIn)
            context.setFillColor(color.cgColor)
            context.fill(target)
            context.endTransparencyLayer()
            context.restoreGState()
        case .battery:
            guard var glyph = battery, let context = NSGraphicsContext.current?.cgContext else { return }
            glyph.percentInside = glyph.percentInside && item.node.style.chargeInside
            // The glyph sets its own outline alpha, so the opacity fades the whole drawing instead.
            context.saveGState()
            context.setAlpha(item.opacity)
            glyph.draw(in: rect, ink: color.withAlphaComponent(1))
            context.restoreGState()
        case .bar:
            let outline = (parentInk ?? color).withAlphaComponent(0.45 * item.opacity)
            let shell = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 1, yRadius: 1)
            outline.setStroke(); shell.lineWidth = 1; shell.stroke()
            let inner = rect.insetBy(dx: 1.5, dy: 1.5)
            guard let level = item.level, level > 0 else { return }
            color.setFill()
            CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: max(1.5, inner.height * level)).fill()
        case .row, .column: break
        }
    }
}
