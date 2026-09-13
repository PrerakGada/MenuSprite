import AppKit

// Finder owns the two draggable icons. This artwork explains the gesture without
// adding fake controls or changing the signed app. Render in points at 1x / 2x.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 760, height: 480)
func color(_ rgb: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: 1)
}
func roundedFont(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    return font.fontDescriptor.withDesign(.rounded)
        .flatMap { NSFont(descriptor: $0, size: size) } ?? font
}
let image = NSImage(size: size)
for scale in [1, 2] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 760 * scale,
        pixelsHigh: 480 * scale, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    // The representation's point size already supplies Retina scaling.
    context.cgContext.translateBy(x: 0, y: size.height)
    context.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    color(0xFCFAFF).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

    func text(_ value: String, in rect: NSRect, font: NSFont, tint: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        (value as NSString).draw(in: rect, withAttributes: [
            .font: font, .foregroundColor: tint, .paragraphStyle: paragraph
        ])
    }
    // A tiny arranged menu rail echoes the sprite's job, not a fake live readout.
    color(0x3E275D).setFill()
    NSBezierPath(roundedRect: NSRect(x: 324, y: 24, width: 112, height: 25),
                 xRadius: 8, yRadius: 8).fill()
    color(0xB9A0E9).setFill()
    NSBezierPath(roundedRect: NSRect(x: 334, y: 32, width: 17, height: 9),
                 xRadius: 3, yRadius: 3).fill()
    NSBezierPath(roundedRect: NSRect(x: 391, y: 32, width: 13, height: 9),
                 xRadius: 3, yRadius: 3).fill()
    NSBezierPath(roundedRect: NSRect(x: 411, y: 32, width: 15, height: 9),
                 xRadius: 3, yRadius: 3).fill()
    color(0x78DFBD).setFill()
    NSBezierPath(roundedRect: NSRect(x: 358, y: 29, width: 25, height: 15),
                 xRadius: 4, yRadius: 4).fill()

    text("Control your menu.", in: NSRect(x: 40, y: 64, width: 680, height: 52),
         font: roundedFont(40, weight: .bold), tint: color(0x4D2D82))
    text("Your tools. Your style. Your rules.",
         in: NSRect(x: 40, y: 117, width: 680, height: 30),
         font: .systemFont(ofSize: 15, weight: .medium), tint: color(0x78668C))

    // Soft color around the actual Finder icons keeps the two ends of the
    // gesture distinct, while their real filenames remain clear underneath.
    color(0xEEE5FB).setFill()
    NSBezierPath(ovalIn: NSRect(x: 80, y: 200, width: 208, height: 157)).fill()
    color(0xE2F6EE).setFill()
    NSBezierPath(ovalIn: NSRect(x: 472, y: 200, width: 208, height: 157)).fill()

    // A single sweeping gesture leads from the app's edge to the folder's upper
    // corner. An open arrowhead follows the curve's tangent, like a drawn gesture.
    let gesture = NSBezierPath()
    gesture.move(to: NSPoint(x: 262, y: 270))
    gesture.curve(to: NSPoint(x: 541, y: 216),
                  controlPoint1: NSPoint(x: 291, y: 151),
                  controlPoint2: NSPoint(x: 457, y: 144))
    gesture.lineWidth = 10
    gesture.lineCapStyle = .round
    gesture.lineJoinStyle = .round
    color(0xEAE0F9).setStroke()
    gesture.stroke()
    gesture.lineWidth = 3.3
    color(0x7950CB).setStroke()
    gesture.stroke()

    let end = NSPoint(x: 541, y: 216)
    let tangent = CGVector(dx: 84, dy: 72)
    let length = hypot(tangent.dx, tangent.dy)
    let ux = tangent.dx / length, uy = tangent.dy / length
    let arrowhead = NSBezierPath()
    arrowhead.move(to: NSPoint(x: end.x - 18 * ux - 7 * uy,
                               y: end.y - 18 * uy + 7 * ux))
    arrowhead.line(to: end)
    arrowhead.line(to: NSPoint(x: end.x - 18 * ux + 7 * uy,
                               y: end.y - 18 * uy - 7 * ux))
    arrowhead.lineWidth = 3.3
    arrowhead.lineCapStyle = .round
    arrowhead.lineJoinStyle = .round
    arrowhead.stroke()

    // Quiet, literal hints sit below Finder's filenames, not over the drop targets.
    text("Drag this app", in: NSRect(x: 94, y: 379, width: 180, height: 24),
         font: .systemFont(ofSize: 12, weight: .semibold), tint: color(0x7950AB))
    text("Drop it here", in: NSRect(x: 486, y: 379, width: 180, height: 24),
         font: .systemFont(ofSize: 12, weight: .semibold), tint: color(0x367963))

    color(0x3E275D).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 420, width: 760, height: 60)).fill()
    text("A little sprite. A lot of control.",
         in: NSRect(x: 44, y: 429, width: 672, height: 24),
         font: roundedFont(14, weight: .semibold), tint: color(0xFFFFFF))
    text("Once copied, open MenuSprite from Applications. Then eject this disk.",
         in: NSRect(x: 44, y: 453, width: 672, height: 24),
         font: .systemFont(ofSize: 11, weight: .regular), tint: color(0xDDD1ED))
    NSGraphicsContext.restoreGraphicsState()
    image.addRepresentation(rep)
}
try image.tiffRepresentation!.write(to: output)
