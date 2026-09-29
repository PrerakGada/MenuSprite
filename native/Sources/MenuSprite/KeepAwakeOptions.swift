import AppKit
import CoreGraphics

/// What the brand item shows while Keep Awake holds the Mac: MenuSprite's own silhouette or a glyph.
enum AwakeIcon: String, CaseIterable, Identifiable {
    case menuSprite, cup, eye, moon, bulb
    var id: String { rawValue }
    var title: String {
        switch self {
        case .menuSprite: "MenuSprite"; case .cup: "Coffee"; case .eye: "Eye"; case .moon: "Moon"; case .bulb: "Bulb"
        }
    }
    var symbol: String {
        switch self {
        case .menuSprite: "sparkles"; case .cup: "cup.and.saucer.fill"; case .eye: "eye.fill"
        case .moon: "moon.fill"; case .bulb: "lightbulb.fill"
        }
    }
}

/// The active icon's colour. `none` keeps the menu bar's own ink.
enum AwakeTint: String, CaseIterable, Identifiable {
    case orange, green, blue, purple, pink, none
    var id: String { rawValue }
    var title: String { rawValue == "none" ? "Menu-bar colour" : rawValue.capitalized }
    var color: NSColor? {
        switch self {
        case .orange: .systemOrange; case .green: .systemGreen; case .blue: .systemBlue
        case .purple: .systemPurple; case .pink: .systemPink; case .none: nil
        }
    }
}

/// What a right click (or ⌃-click) on the brand item does.
enum AwakeRightClick: String, CaseIterable, Identifiable {
    case toggle, durations, hub, nothing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .toggle: "Toggle Keep Awake"
        case .durations: "Choose how long"
        case .hub: "Open MenuSprite"
        case .nothing: "Nothing"
        }
    }
}

enum AwakeDurations {
    /// Seconds; 0 means until turned off.
    static let all: [Double] = [900, 1800, 3600, 7200, 14400, 28800, 0]
    static func title(_ seconds: Double) -> String {
        switch seconds {
        case 0: "Until turned off"
        case ..<3600: "\(Int(seconds / 60)) minutes"
        case 3600: "1 hour"
        default: "\(Int(seconds / 3600)) hours"
        }
    }
    static func short(_ seconds: Double) -> String {
        seconds == 0 ? "∞" : (seconds < 3600 ? "\(Int(seconds / 60))m" : "\(Int(seconds / 3600))h")
    }
}

/// Moves the pointer one point and straight back so apps that watch for input (chat presence,
/// remote sessions) keep seeing activity. Posting events needs macOS's event-posting consent.
enum PointerNudge {
    static var allowed: Bool { CGPreflightPostEventAccess() }
    @discardableResult static func requestAccess() -> Bool { CGRequestPostEventAccess() }

    /// Skips the nudge while the person is using the Mac: real input already counts.
    static func nudge(ifIdleFor seconds: TimeInterval) {
        guard allowed else { return }
        let anyInput = CGEventType(rawValue: ~0)!
        guard CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) >= seconds,
              let location = CGEvent(source: nil)?.location else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for point in [CGPoint(x: location.x + 1, y: location.y), location] {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }
}

enum AwakeIconArt {
    /// The active icon at the brand item's size: a glyph centred in the item's usual width so the
    /// menu bar does not shift when Keep Awake turns on, tinted or left as a template.
    static func image(icon: AwakeIcon, tint: AwakeTint, size: NSSize) -> NSImage? {
        let glyph: NSImage?
        if icon == .menuSprite {
            let choice = MenuBarIconChoice.saved.hasMonochrome ? MenuBarIconChoice.saved : .arrangerFlat
            glyph = choice.image(monochrome: true)
            if let glyph { glyph.size = NSSize(width: size.height * glyph.size.width / max(1, glyph.size.height), height: size.height) }
        } else {
            glyph = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: icon.title)?
                .withSymbolConfiguration(.init(pointSize: floor(size.height * 0.68), weight: .semibold))
        }
        guard let glyph else { return nil }
        let canvas = NSSize(width: max(size.width, glyph.size.width), height: size.height)
        let rect = NSRect(x: (canvas.width - glyph.size.width) / 2, y: (canvas.height - glyph.size.height) / 2,
                          width: glyph.size.width, height: glyph.size.height)
        let image = NSImage(size: canvas, flipped: false) { _ in
            glyph.draw(in: rect)
            if let color = tint.color { color.set(); rect.fill(using: .sourceAtop) }
            return true
        }
        image.isTemplate = tint.color == nil
        image.accessibilityDescription = "MenuSprite · keeping this Mac awake"
        return image
    }
}
