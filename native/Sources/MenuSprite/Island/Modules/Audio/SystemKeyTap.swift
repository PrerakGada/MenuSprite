import AppKit
import ApplicationServices
import IslandKit

/// A media key as the tap reports it.
struct IslandSystemKey: Sendable {
    let event: IslandMediaKeyEvent
    let modifiers: IslandKeyModifiers
    /// The event's own flags, kept so the key can be handed back to macOS unchanged.
    let flags: CGEventFlags
}

/// A session event tap for system-defined events only: media, brightness and illumination keys (and
/// mouse-button bookkeeping, which it ignores). It never sees ordinary typing. It runs on the main run
/// loop and its owner must answer at once: CoreAudio and display writes happen elsewhere. It is
/// installed only while its owner needs it and Accessibility is already granted; it never asks for it.
@MainActor
final class IslandSystemKeyTap {
    enum Verdict { case pass, consume }

    /// Events carrying this value in their user-data field were posted by MenuSprite and pass untouched.
    static let marker: Int64 = 0x4D53_4B54
    private static let systemDefined: UInt32 = 14
    private static let mediaSubtype: Int16 = 8
    private static var taps: [Int: IslandSystemKeyTap] = [:]
    private static var nextToken = 1

    private let handler: (IslandSystemKey) -> Verdict
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var token = 0
    /// macOS disabled the tap while Accessibility was not granted, so it could not be re-enabled. It
    /// counts as not installed, and the owner's next sync (on the Accessibility notification) installs
    /// a fresh one.
    private var disabled = false

    init(handler: @escaping (IslandSystemKey) -> Verdict) { self.handler = handler }

    var isInstalled: Bool { port != nil && !disabled }

    /// Returns false when Accessibility is not granted (checked, never requested) or the tap failed.
    @discardableResult
    func install() -> Bool {
        if port != nil {
            guard disabled else { return true }
            remove()
        }
        guard AXIsProcessTrusted() else { return false }
        let token = Self.nextToken
        Self.nextToken += 1
        let mask = CGEventMask(1) << CGEventMask(Self.systemDefined)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: islandSystemKeyTapCallback,
                                           userInfo: UnsafeMutableRawPointer(bitPattern: token)) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        Self.taps[token] = self
        self.token = token
        self.port = port
        self.source = source
        return true
    }

    func remove() {
        disabled = false
        guard let port else { return }
        Self.taps[token] = nil
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(port)
        self.port = nil
        source = nil
    }

    /// Returns true to drop the event.
    fileprivate static func handle(token: Int, type: CGEventType, event: CGEvent) -> Bool {
        guard let tap = taps[token] else { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tap.port, AXIsProcessTrusted() {
                CGEvent.tapEnable(tap: port, enable: true)
            } else {
                // It cannot come back without Accessibility: tear it down once this callback returns.
                tap.disabled = true
                DispatchQueue.main.async { MainActor.assumeIsolated { if tap.disabled { tap.remove() } } }
            }
            return false
        }
        guard type.rawValue == systemDefined, event.getIntegerValueField(.eventSourceUserData) != marker,
              let system = NSEvent(cgEvent: event), system.subtype.rawValue == mediaSubtype else { return false }
        let key = IslandSystemKey(event: IslandMediaKeyEvent(data1: system.data1), modifiers: modifiers(event.flags), flags: event.flags)
        return tap.handler(key) == .consume
    }

    private static func modifiers(_ flags: CGEventFlags) -> IslandKeyModifiers {
        var modifiers: IslandKeyModifiers = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        return modifiers
    }

    /// Hands a key back to macOS: a marked key-down and a synthesised key-up, posted where hardware
    /// keys enter, so MenuSprite's own taps let them through and the system handles them natively.
    static func postToSystem(_ key: IslandSystemKey) {
        for state in [IslandMediaKeyEvent.State.down, .up] {
            let event = IslandMediaKeyEvent(code: key.event.code, state: state)
            let stateFlags: UInt = state == .down ? 0xA00 : 0xB00
            let flags = NSEvent.ModifierFlags(rawValue: UInt(key.flags.rawValue) & NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue | stateFlags)
            guard let system = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                                  windowNumber: 0, context: nil, subtype: mediaSubtype, data1: event.data1, data2: -1),
                  let posted = system.cgEvent else { continue }
            posted.setIntegerValueField(.eventSourceUserData, value: marker)
            posted.post(tap: .cghidEventTap)
        }
    }
}

private func islandSystemKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                        refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    // The tap's run-loop source lives on the main run loop, so this runs on the main thread.
    let token = Int(bitPattern: refcon)
    nonisolated(unsafe) let event = event
    let consume = MainActor.assumeIsolated { IslandSystemKeyTap.handle(token: token, type: type, event: event) }
    return consume ? nil : Unmanaged.passUnretained(event)
}

/// Calls back when this app's Accessibility trust may have changed (the system posts a distributed
/// notification; trust settles a moment later), so key taps can be installed or released without polling.
@MainActor
final class IslandAccessibilityObserver {
    /// Written once in init, read only by deinit.
    nonisolated(unsafe) private let observer: NSObjectProtocol

    init(_ changed: @escaping @MainActor () -> Void) {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { changed() } }
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(observer)
    }
}
