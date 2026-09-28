import CoreGraphics
import Foundation

// Private frameworks the display module reaches at run time. Every lookup fails softly: a missing
// framework, symbol or class leaves that route unavailable instead of crashing. Callers use these on
// the display module's queue, never on the main thread.

/// The built-in panel's (and Apple displays') brightness through DisplayServices.
enum DisplayServicesBrightness {
    private typealias Getter = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private struct Symbols: @unchecked Sendable {
        let get: Getter
        let set: Setter
    }

    private static let symbols: Symbols? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return Symbols(get: unsafeBitCast(get, to: Getter.self), set: unsafeBitCast(set, to: Setter.self))
    }()

    static var isAvailable: Bool { symbols != nil }

    static func level(of display: CGDirectDisplayID) -> Double? {
        guard let symbols else { return nil }
        var value: Float = 0
        guard symbols.get(display, &value) == 0, value.isFinite else { return nil }
        return Double(min(1, max(0, value)))
    }

    static func setLevel(_ level: Double, of display: CGDirectDisplayID) -> Bool {
        guard let symbols, level.isFinite else { return false }
        return symbols.set(display, Float(min(1, max(0, level)))) == 0
    }
}

/// CoreDisplay: a display's IORegistry location, and the AV service calls that carry DDC/CI.
enum CoreDisplayBridge {
    typealias InfoFunction = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    typealias CreateService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    struct Symbols: @unchecked Sendable {
        let info: InfoFunction?
        let createService: CreateService
        let readI2C: Transfer
        let writeI2C: Transfer
    }

    static let symbols: Symbols? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
              let create = dlsym(handle, "IOAVServiceCreateWithService"),
              let read = dlsym(handle, "IOAVServiceReadI2C"),
              let write = dlsym(handle, "IOAVServiceWriteI2C") else { return nil }
        return Symbols(info: dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary").map { unsafeBitCast($0, to: InfoFunction.self) },
                       createService: unsafeBitCast(create, to: CreateService.self),
                       readI2C: unsafeBitCast(read, to: Transfer.self),
                       writeI2C: unsafeBitCast(write, to: Transfer.self))
    }()

    /// The framebuffer's IORegistry path for a display, when CoreDisplay reports one.
    static func location(of display: CGDirectDisplayID) -> String? {
        guard let info = symbols?.info?(display)?.takeRetainedValue() as? [String: Any] else { return nil }
        return info["IODisplayLocation"] as? String
    }
}

/// The built-in keyboard's backlight through CoreBrightness's keyboard client, found once. Confined
/// to the display queue.
final class KeyboardBacklight: @unchecked Sendable {
    private typealias LevelFunction = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias BuiltInFunction = @convention(c) (AnyObject, Selector, UInt64) -> Bool

    /// nil when this Mac has no controllable built-in keyboard backlight.
    static let builtIn: KeyboardBacklight? = find()

    private let client: NSObject
    private let keyboard: UInt64
    private let levelSelector: Selector
    private let levelFunction: LevelFunction

    private init(client: NSObject, keyboard: UInt64, levelSelector: Selector, levelFunction: @escaping LevelFunction) {
        self.client = client
        self.keyboard = keyboard
        self.levelSelector = levelSelector
        self.levelFunction = levelFunction
    }

    func level() -> Double? {
        let value = levelFunction(client, levelSelector, keyboard)
        return value.isFinite ? Double(min(1, max(0, value))) : nil
    }

    private static func find() -> KeyboardBacklight? {
        guard Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework")?.load() == true,
              let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        let client = type.init()
        let copyIDs = NSSelectorFromString("copyKeyboardBacklightIDs")
        let isBuiltIn = NSSelectorFromString("isKeyboardBuiltIn:")
        let level = NSSelectorFromString("brightnessForKeyboard:")
        guard client.responds(to: copyIDs), client.responds(to: isBuiltIn), client.responds(to: level),
              let ids = client.perform(copyIDs)?.takeRetainedValue() as? [NSNumber] else { return nil }
        let builtIn = unsafeBitCast(client.method(for: isBuiltIn), to: BuiltInFunction.self)
        guard let keyboard = ids.first(where: { builtIn(client, isBuiltIn, $0.uint64Value) }) else { return nil }
        return KeyboardBacklight(client: client, keyboard: keyboard.uint64Value, levelSelector: level,
                                 levelFunction: unsafeBitCast(client.method(for: level), to: LevelFunction.self))
    }
}
