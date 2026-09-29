import AppKit

/// The artwork on MenuSprite's own menu-bar item. The default is the 3D Arranger the app has always
/// shipped with; every other choice is one of the early brand explorations in `brand/exploration/`,
/// cut out into `Resources/MenuBarIcons/` by `scripts/cut-menu-bar-icons.swift`. Flat designs also
/// carry a black template form, which macOS tints to match the menu bar. Spec: `docs/menu-bar-icon.md`.
enum MenuBarIconChoice: String, CaseIterable, Identifiable {
    case arranger
    case arrangerFlat = "arranger-flat"
    case slimRail = "slim-rail"
    case ribbonRail = "ribbon-rail"
    case glassStrip = "glass-strip"
    case graphicSprite = "graphic-sprite"
    case warmStudio = "warm-studio"
    case paperSprite = "paper-sprite"
    case peek, bitwing, droplet, mochi, comet, bud, batlet, tilekin, orbit, fold

    enum Family: String, CaseIterable, Identifiable {
        case identity, characters
        var id: String { rawValue }
        var title: String { self == .identity ? "MenuSprite" : "Characters" }
    }

    var id: String { rawValue }

    var family: Family {
        switch self {
        case .arranger, .arrangerFlat, .slimRail, .ribbonRail, .glassStrip, .graphicSprite, .warmStudio, .paperSprite: .identity
        default: .characters
        }
    }

    var title: String {
        switch self {
        case .arranger: "Arranger"
        case .arrangerFlat: "Arranger, flat"
        case .slimRail: "Slim rail"
        case .ribbonRail: "Ribbon rail"
        case .glassStrip: "Glass strip"
        case .graphicSprite: "Graphic sprite"
        case .warmStudio: "Warm studio"
        case .paperSprite: "Paper sprite"
        default: rawValue.capitalized
        }
    }

    /// The 3D renders lose their faces as a silhouette, so only the flat designs have a monochrome form.
    var hasMonochrome: Bool {
        switch self {
        case .arranger, .slimRail, .ribbonRail, .glassStrip, .warmStudio, .paperSprite: false
        default: true
        }
    }

    /// The artwork as bundled; `monochrome` picks the template form where there is one.
    func image(monochrome: Bool) -> NSImage? {
        // A copy: callers resize it, and the named image is shared across the app.
        if self == .arranger { return NSImage(named: "MenuBarIcon")?.copy() as? NSImage }
        let template = monochrome && hasMonochrome
        guard let url = Bundle.main.url(forResource: template ? "\(rawValue)-template" : rawValue,
                                        withExtension: "png", subdirectory: "MenuBarIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = template
        return image
    }

    private static let choiceKey = "MenuSprite.MenuBarIcon"
    private static let monochromeKey = "MenuSprite.MenuBarIconMonochrome"
    static let changed = Notification.Name("MenuSprite.MenuBarIconChanged")

    static var saved: MenuBarIconChoice {
        get { UserDefaults.standard.string(forKey: choiceKey).flatMap(Self.init(rawValue:)) ?? .arranger }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: choiceKey); NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// Kept apart from the choice, so switching between designs keeps the monochrome preference.
    static var monochrome: Bool {
        get { UserDefaults.standard.bool(forKey: monochromeKey) }
        set { UserDefaults.standard.set(newValue, forKey: monochromeKey); NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// What the menu bar shows right now: the saved choice in the saved style.
    static func currentImage() -> NSImage? { saved.image(monochrome: monochrome) }
}
