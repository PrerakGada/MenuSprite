import AudioToolbox
import CoreAudio
import Foundation
import IslandKit
import os

/// Thin CoreAudio helpers usable from any thread. Every call may block while a Bluetooth or USB
/// device reconnects, so callers run them on the audio module's serial queue, never on the main thread.
enum AudioHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let output = kAudioObjectPropertyScopeOutput
    static let input = kAudioObjectPropertyScopeInput
    static let main = kAudioObjectPropertyElementMain
    /// Mute and channel volumes are tried on the main element and the first two channels.
    static let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]

    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(object, &address),
              AudioObjectIsPropertySettable(object, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    static func read<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        return status == noErr ? value : nil
    }

    @discardableResult
    static func write<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var address = address
        var value = value
        let size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { AudioObjectSetPropertyData(object, &address, 0, nil, size, $0) }
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    static func devices() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func defaultDevice(input: Bool) -> AudioObjectID? {
        let selector = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        guard let id = read(system, address(selector), AudioObjectID(0)), id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func setDefaultDevice(_ device: AudioObjectID, input: Bool) -> OSStatus {
        write(system, address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice), device)
    }

    static func hasStreams(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    static func flag(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool? {
        read(device, address(selector, scope), UInt32(0)).map { $0 != 0 }
    }

    static func transport(_ device: AudioObjectID) -> UInt32 {
        read(device, address(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0
    }

    // MARK: Volume and mute

    /// The settable volume property for a scope: the virtual main volume, else the main scalar.
    static func volumeAddress(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress? {
        let virtual = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope)
        if isSettable(device, virtual) { return virtual }
        let scalar = address(kAudioDevicePropertyVolumeScalar, scope)
        return isSettable(device, scalar) ? scalar : nil
    }

    static func volume(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Double? {
        guard let address = volumeAddress(device, scope), let value = read(device, address, Float32(0)), value.isFinite else { return nil }
        return Double(min(1, max(0, value)))
    }

    static func setVolume(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope, _ level: Double) -> Bool {
        guard level.isFinite, let address = volumeAddress(device, scope) else { return false }
        return write(device, address, Float32(min(1, max(0, level)))) == noErr
    }

    /// The first mute element that answers, or nil when the device has no mute switch.
    static func mute(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool? {
        for element in elements {
            if let value = read(device, address(kAudioDevicePropertyMute, scope, element), UInt32(0)) { return value != 0 }
        }
        return nil
    }

    static func hasSettableMute(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
        elements.contains { isSettable(device, address(kAudioDevicePropertyMute, scope, $0)) }
    }

    /// Writes every settable mute element; true when at least one took the value.
    static func setMute(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope, _ muted: Bool) -> Bool {
        var wrote = false
        for element in elements {
            let address = address(kAudioDevicePropertyMute, scope, element)
            if isSettable(device, address), write(device, address, UInt32(muted ? 1 : 0)) == noErr { wrote = true }
        }
        return wrote
    }

    /// Readable per-element volume scalars (main, 1, 2).
    static func scalars(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [UInt32: Float] {
        var levels: [UInt32: Float] = [:]
        for element in elements {
            if let value = read(device, address(kAudioDevicePropertyVolumeScalar, scope, element), Float32(0)), value.isFinite {
                levels[element] = value
            }
        }
        return levels
    }

    static func setScalar(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope, element: UInt32, _ value: Float) -> Bool {
        let address = address(kAudioDevicePropertyVolumeScalar, scope, element)
        return isSettable(device, address) && write(device, address, min(1, max(0, value))) == noErr
    }

    // MARK: Devices as the island shows them

    static func describe(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> IslandAudioDevice? {
        guard hasStreams(device, scope), flag(device, kAudioDevicePropertyDeviceIsAlive) != false,
              flag(device, kAudioDevicePropertyIsHidden) != true,
              let uid = string(device, kAudioDevicePropertyDeviceUID),
              let name = string(device, kAudioObjectPropertyName) else { return nil }
        let isInput = scope == input
        // Only outputs the system can make its default belong in the output menu.
        if !isInput, flag(device, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope) == false { return nil }
        return IslandAudioDevice(id: device, uid: uid, name: name,
                                 symbol: symbol(device, uid: uid, name: name, scope: scope))
    }

    private static func symbol(_ device: AudioObjectID, uid: String, name: String, scope: AudioObjectPropertyScope) -> String {
        if IslandAudioNaming.isHeadphones(name: name, uid: uid, dataSource: dataSourceName(device, scope)) { return "headphones" }
        switch transport(device) {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return "iphone"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB:
            return scope == input ? "mic" : "hifispeaker"
        default: return scope == input ? "mic" : "speaker.wave.2"
        }
    }

    private static func dataSourceName(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> String? {
        guard var source = read(device, address(kAudioDevicePropertyDataSource, scope), UInt32(0)) else { return nil }
        var name: Unmanaged<CFString>?
        var address = address(kAudioDevicePropertyDataSourceNameForIDCFString, scope)
        var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
        let status = withUnsafeMutablePointer(to: &source) { sourcePointer in
            withUnsafeMutablePointer(to: &name) { namePointer in
                var translation = AudioValueTranslation(mInputData: sourcePointer, mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                                                        mOutputData: namePointer, mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
                return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &translation)
            }
        }
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    /// Outputs and inputs, default first, then by name, then UID.
    static func deviceLists(defaultOutput: AudioObjectID?, defaultInput: AudioObjectID?, includeInputs: Bool)
        -> (outputs: [IslandAudioDevice], inputs: [IslandAudioDevice]) {
        var outputs: [IslandAudioDevice] = []
        var inputs: [IslandAudioDevice] = []
        for device in devices() {
            if let described = describe(device, scope: output) { outputs.append(described) }
            if includeInputs, let described = describe(device, scope: input) { inputs.append(described) }
        }
        func ordered(_ list: [IslandAudioDevice], _ current: AudioObjectID?) -> [IslandAudioDevice] {
            list.sorted { IslandAudioNaming.precedes(($0.id == current, $0.name, $0.uid), ($1.id == current, $1.name, $1.uid)) }
        }
        return (ordered(outputs, defaultOutput), ordered(inputs, defaultInput))
    }
}

/// HAL property listeners registered with the plain C callback and an integer token as client data,
/// never an object's address and never the block form (removing a block listener reports success but
/// leaves it registered). A callback racing a removal looks its token up and finds nothing. Attach and
/// remove may run on different queues (a stuck queue is replaced), so each token remembers how far it
/// got and a removal that overtakes its attach still leaves nothing registered.
enum AudioListeners {
    struct Token: Hashable, Sendable {
        let id: Int
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress

        static func == (a: Token, b: Token) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private struct Entry {
        let handler: @Sendable () -> Void
        var attaching = false
        var attached = false
        var removed = false
    }

    private struct Table {
        var next = 1
        var entries: [Int: Entry] = [:]
    }

    private static let table = OSAllocatedUnfairLock(initialState: Table())

    private static let callback: AudioObjectPropertyListenerProc = { _, _, _, clientData in
        let id = Int(bitPattern: clientData)
        let handler = AudioListeners.table.withLock { table in table.entries[id].flatMap { $0.removed ? nil : $0.handler } }
        handler?()
        return noErr
    }

    /// Reserves a token and its handler at once, from any thread; `attach` registers it with the HAL.
    /// The handler runs on a HAL thread.
    static func reserve(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, handler: @escaping @Sendable () -> Void) -> Token {
        let id = table.withLock { table in
            let id = table.next
            table.next += 1
            table.entries[id] = Entry(handler: handler)
            return id
        }
        return Token(id: id, object: object, address: address)
    }

    /// Registers with the HAL, unless the token was already removed. Call off the main thread.
    static func attach(_ token: Token) {
        let proceed = table.withLock { table -> Bool in
            guard let entry = table.entries[token.id], !entry.removed, !entry.attached, !entry.attaching else { return false }
            table.entries[token.id]?.attaching = true
            return true
        }
        guard proceed else { return }
        var address = token.address
        let added = AudioObjectAddPropertyListener(token.object, &address, callback, UnsafeMutableRawPointer(bitPattern: token.id)) == noErr
        let undo = table.withLock { table -> Bool in
            guard let entry = table.entries[token.id] else { return false }
            if entry.removed || !added {
                table.entries[token.id] = nil
                return added
            }
            table.entries[token.id]?.attaching = false
            table.entries[token.id]?.attached = true
            return false
        }
        if undo { unregister(token) }
    }

    /// Forgets the handler at once, then unregisters if it was registered. Call off the main thread.
    static func remove(_ token: Token) {
        let registered = table.withLock { table -> Bool in
            guard let entry = table.entries[token.id] else { return false }
            // An attach in progress sees the removal when it finishes and undoes itself.
            if entry.attaching {
                table.entries[token.id]?.removed = true
                return false
            }
            table.entries[token.id] = nil
            return entry.attached
        }
        if registered { unregister(token) }
    }

    private static func unregister(_ token: Token) {
        var address = token.address
        AudioObjectRemovePropertyListener(token.object, &address, callback, UnsafeMutableRawPointer(bitPattern: token.id))
    }
}
