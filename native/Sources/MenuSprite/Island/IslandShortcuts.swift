import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A global keyboard shortcut: a key code plus Command/Option/Control/Shift.
struct IslandShortcut: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags.RawValue

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection([.command, .option, .control, .shift]) }

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }

    /// "⌃⌥⌘V"-style text.
    var display: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: break
        }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let layout = unsafeBitCast(data, to: CFData.self)
        var dead: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { pointer in
            UCKeyTranslate(pointer, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Registers global shortcuts with the system's hot-key service. No permission is needed; a shortcut
/// another app already owns simply fails to register and `register` returns false.
@MainActor
final class IslandShortcuts {
    static let shared = IslandShortcuts()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [String: (id: UInt32, ref: EventHotKeyRef)] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    /// Registers (or replaces) the shortcut named `name`. Pass nil to remove it.
    @discardableResult
    func register(_ name: String, _ shortcut: IslandShortcut?, action: @escaping () -> Void) -> Bool {
        unregister(name)
        guard let shortcut else { return true }
        installHandler()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D535052), id: id) // "MSPR"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[name] = (id, ref)
        handlers[id] = action
        return true
    }

    func unregister(_ name: String) {
        guard let entry = refs.removeValue(forKey: name) else { return }
        UnregisterEventHotKey(entry.ref)
        handlers[entry.id] = nil
    }

    private func installHandler() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let id = hotKey.id
            let shortcuts = Unmanaged<IslandShortcuts>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { shortcuts.handlers[id]?() } }
            return noErr
        }, 1, &spec, context, &eventHandler)
    }
}

/// A small recorder: click, press a combination with at least one of ⌘⌥⌃, and it is saved; ⌫ clears.
struct IslandShortcutRecorder: View {
    @Binding var shortcut: IslandShortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Type shortcut…" : (shortcut?.display ?? "Record shortcut"))
                .frame(minWidth: 110)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            if event.keyCode == UInt16(kVK_Delete), flags.isEmpty { shortcut = nil; stop(); return nil }
            guard !flags.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return nil }
            shortcut = IslandShortcut(keyCode: UInt32(event.keyCode), modifiers: flags.rawValue)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
