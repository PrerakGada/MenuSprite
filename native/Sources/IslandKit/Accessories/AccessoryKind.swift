import Foundation

/// What an accessory is, which decides its symbol. Symbols are plain device shapes, never battery
/// glyphs, so a notice's icon never suggests a level it does not have. Declared in the order used to
/// break ties when several devices warn together.
public enum AccessoryKind: String, CaseIterable, Codable, Sendable, Comparable {
    case airpodsMax, airpodsPro, airpods, headphones, speaker, microphone, keyboard, mouse, trackpad,
         gameController, remote, phone, tablet, laptop, desktop, watch, glasses, printer, car, tv, other

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    public var symbol: String {
        switch self {
        case .airpodsMax: "airpodsmax"
        case .airpodsPro: "airpodspro"
        case .airpods: "airpods"
        case .headphones: "headphones"
        case .speaker: "hifispeaker"
        case .microphone: "mic"
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .gameController: "gamecontroller"
        case .remote: "av.remote"
        case .phone: "iphone"
        case .tablet: "ipad"
        case .laptop: "laptopcomputer"
        case .desktop: "desktopcomputer"
        case .watch: "applewatch"
        case .glasses: "eyeglasses"
        case .printer: "printer"
        case .car: "car"
        case .tv: "tv"
        case .other: "dot.radiowaves.left.and.right"
        }
    }

    /// The kind a device's name states, if any. A name that says what the device is outranks
    /// anything the device reports about itself: "Alex's Magic Keyboard" is a keyboard even when its
    /// hardware also claims to point.
    public static func named(_ name: String) -> AccessoryKind? {
        let name = name.lowercased()
        if name.contains("airpods max") { return .airpodsMax }
        if name.contains("airpods pro") { return .airpodsPro }
        if name.contains("airpods") { return .airpods }
        if ["headphone", "headset", "buds"].contains(where: name.contains) { return .headphones }
        if name.contains("keyboard") { return .keyboard }
        if name.contains("mouse") { return .mouse }
        if name.contains("trackpad") || name.contains("track pad") { return .trackpad }
        return nil
    }

    /// The kind a HID device's primary usage implies: a generic-desktop mouse or keyboard, the
    /// keyboard page, or a digitizer touch pad.
    public static func hidUsage(page: Int, usage: Int) -> AccessoryKind? {
        switch (page, usage) {
        case (1, 2): .mouse
        case (1, 6), (7, _): .keyboard
        case (13, 5): .trackpad
        default: nil
        }
    }

    /// The kind the Bluetooth report's device type implies ("Headphones", "Headset", "Mouse",
    /// "Speaker"…). That type is the device's Bluetooth class in words; the raw class is only
    /// reachable through IOBluetooth, which asks for Bluetooth access, so a renamed device such as
    /// "Kitchen" gets its symbol from here instead.
    public static func reportedType(_ type: String) -> AccessoryKind? {
        let text = type.lowercased()
        let words = Set(text.split { !$0.isLetter }.map(String.init))
        func has(_ fragments: String...) -> Bool { fragments.contains(where: text.contains) }
        func word(_ candidates: String...) -> Bool { candidates.contains(where: words.contains) }

        if has("headphone", "headset", "hands-free", "handsfree", "earbud") { return .headphones }
        if has("microphone") { return .microphone }
        if word("car") { return .car }
        if has("video", "television") || word("tv") { return .tv }
        if has("speaker", "hifi", "hi-fi") || word("audio") { return .speaker }
        if has("trackpad", "touchpad", "touch pad", "digitizer") { return .trackpad }
        if has("mouse", "pointing") { return .mouse }
        if has("keyboard") { return .keyboard }
        if has("gamepad", "joystick", "game", "toy") { return .gameController }
        if has("remote") { return .remote }
        if has("glasses") { return .glasses }
        if has("watch") || word("wearable") { return .watch }
        if has("printer") { return .printer }
        if has("smartphone", "cellular") || word("phone") { return .phone }
        if has("tablet") { return .tablet }
        if has("laptop") { return .laptop }
        if has("desktop", "computer", "server", "workstation") { return .desktop }
        return nil
    }

    /// Name first, then what the Bluetooth report says the device is, then what its own source
    /// hints (a HID usage), else the generic wireless symbol.
    public static func resolve(name: String, reported: AccessoryKind? = nil, hint: AccessoryKind? = nil) -> AccessoryKind {
        named(name) ?? reported ?? hint ?? .other
    }
}
