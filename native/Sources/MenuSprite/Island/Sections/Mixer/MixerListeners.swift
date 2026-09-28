import CoreAudio
import Foundation
import Synchronization

/// Core Audio property listeners registered with the plain C callback and an integer token as the
/// client data. The block-based listener API reports success on removal but can leave the block
/// registered, and a callback can arrive on a HAL thread after its owner is gone; with tokens looked
/// up in a locked table, a late callback finds nothing and does nothing.
final class MixerListenerRegistry: Sendable {
    static let shared = MixerListenerRegistry()

    private let handlers = Mutex<[UInt: @Sendable () -> Void]>([:])
    private let counter = Atomic<UInt>(0)

    func add(_ handler: @escaping @Sendable () -> Void) -> UInt {
        let token = counter.wrappingAdd(1, ordering: .relaxed).newValue
        handlers.withLock { $0[token] = handler }
        return token
    }

    func remove(_ token: UInt) { _ = handlers.withLock { $0.removeValue(forKey: token) } }

    func fire(_ token: UInt) {
        guard let handler = handlers.withLock({ $0[token] }) else { return }
        handler()
    }
}

/// One registered listener, kept so it can be removed exactly.
struct MixerListener: Sendable, Hashable {
    /// One function for every registration, so removal names the same callback it added.
    private static let callback: AudioObjectPropertyListenerProc = { _, _, _, client in
        MixerListenerRegistry.shared.fire(UInt(bitPattern: client))
        return noErr
    }

    let object: AudioObjectID
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope
    let token: UInt

    /// Registers `handler` for a property. The handler runs on a HAL thread: it must only hop to a queue.
    static func add(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    handler: @escaping @Sendable () -> Void) -> MixerListener? {
        let token = MixerListenerRegistry.shared.add(handler)
        var address = MixerHAL.address(selector, scope)
        let status = AudioObjectAddPropertyListener(object, &address, Self.callback, UnsafeMutableRawPointer(bitPattern: token))
        guard status == noErr else {
            MixerListenerRegistry.shared.remove(token)
            return nil
        }
        return MixerListener(object: object, selector: selector, scope: scope, token: token)
    }

    /// Unregisters from Core Audio and drops the handler, even if Core Audio refuses (a vanished object).
    func remove() {
        var address = MixerHAL.address(selector, scope)
        _ = AudioObjectRemovePropertyListener(object, &address, Self.callback, UnsafeMutableRawPointer(bitPattern: token))
        MixerListenerRegistry.shared.remove(token)
    }
}
