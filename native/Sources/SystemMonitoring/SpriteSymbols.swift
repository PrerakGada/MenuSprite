import AppKit

/// Icons a sprite can name beside SF Symbols. SF Symbols has no Bluetooth mark, so MenuSprite draws its
/// own; names start with "menusprite." so they never collide with Apple's. Everything that resolves an
/// icon by name (the renderer, the studio's picker, the agent spec's check) goes through here.
public enum SpriteSymbols {
    public static let bluetooth = "menusprite.bluetooth"
    /// MenuSprite's own symbols, for the studio's picker.
    public static let custom = [bluetooth]

    /// Width over height of the slot an icon takes. SF Symbols keep the square slot they always had, so
    /// existing sprites keep their widths; MenuSprite's own marks take only the width they draw.
    public static func aspect(_ name: String) -> CGFloat { name == bluetooth ? 10.0 / 16.0 : 1 }

    public static func exists(_ name: String) -> Bool {
        custom.contains(name) || NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// The icon `name` names, as a template image. `level` (0–1) is an SF Symbol's variable value, so a
    /// Wi-Fi icon fills only as many bars as the signal earns; MenuSprite's own symbols ignore it.
    @MainActor
    public static func image(_ name: String, level: Double? = nil) -> NSImage? {
        if name == bluetooth { return bluetoothRune }
        if let level { return NSImage(systemSymbolName: name, variableValue: level, accessibilityDescription: nil) }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// The Bluetooth rune, drawn as a stroke the way macOS's own menu-bar mark is: a spine with the two
    /// arrowheads on its right and the two tails crossing to the left. Proportions follow Apple's glyph
    /// (about 0.6 wide for its height), so it stands the same height as an SF Symbol in the same slot.
    @MainActor
    private static let bluetoothRune: NSImage = {
        let size = NSSize(width: 10, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 1.6, y: 4.4))
            path.line(to: NSPoint(x: 8.3, y: 11.2))
            path.line(to: NSPoint(x: 5, y: 14.6))
            path.line(to: NSPoint(x: 5, y: 1.4))
            path.line(to: NSPoint(x: 8.3, y: 4.8))
            path.line(to: NSPoint(x: 1.6, y: 11.6))
            path.lineWidth = 1.5
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Bluetooth"
        return image
    }()
}
