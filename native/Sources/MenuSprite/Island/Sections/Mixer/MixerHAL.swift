import AppKit
import CoreAudio
import Darwin
import IslandKit

/// Plain reads of Core Audio properties. Any of them can block while a Bluetooth or USB device
/// reconnects, so the mixer calls them only on its own queues, never on the main thread.
enum MixerHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let output = kAudioObjectPropertyScopeOutput

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func double(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Double? {
        var address = address(selector)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func size(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32 {
        var address = address(selector, scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr ? size : 0
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size = size(object, selector)
        guard size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Output channels of a device (its output stream configuration).
    static func outputChannels(_ device: AudioObjectID) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, output)
        var size = size(device, kAudioDevicePropertyStreamConfiguration, output)
        guard size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func defaultOutputUID() -> String? {
        guard let device = uint32(system, kAudioHardwarePropertyDefaultOutputDevice), device != kAudioObjectUnknown else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }

    /// Live, visible output devices, excluding the mixer's own private aggregates.
    static func outputDevices(defaultUID: String?) -> [MixerDevice] {
        let devices = objects(system, kAudioHardwarePropertyDevices).compactMap { device -> MixerDevice? in
            guard size(device, kAudioDevicePropertyStreams, output) > 0,
                  uint32(device, kAudioDevicePropertyDeviceIsAlive) != 0,
                  uint32(device, kAudioDevicePropertyIsHidden) != 1,
                  let uid = string(device, kAudioDevicePropertyDeviceUID), !uid.hasPrefix(MixerEngine.uidPrefix),
                  let name = string(device, kAudioObjectPropertyName) else { return nil }
            return MixerDevice(uid: uid, name: name, isDefault: uid == defaultUID)
        }
        return MixerDevice.ordered(devices)
    }
}

/// What one pass over the HAL found: the apps with audio connections, the outputs and the default.
struct MixerScan: Sendable {
    var apps: [MixerApp] = []
    var objects: Set<AudioObjectID> = []
    var outputs: [MixerDevice] = []
    var defaultOutput: String?
    var finderPID: Int32?
}

/// Step 1 of the mixer: every Core Audio process object, billed to the regular app responsible for
/// it. Runs on the mixer's HAL queue.
enum MixerProcessScanner {
    private static let responsible: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private struct Owner {
        var regular: Bool
        var bundleID: String?
        var name: String?
    }

    static func scan() -> MixerScan {
        var scan = MixerScan()
        scan.defaultOutput = MixerHAL.defaultOutputUID()
        scan.outputs = MixerHAL.outputDevices(defaultUID: scan.defaultOutput)
        scan.finderPID = NSRunningApplication.runningApplications(withBundleIdentifier: MixerListing.finderBundleID).first?.processIdentifier
        let own = getpid()
        var owners: [pid_t: Owner] = [:]
        func owner(_ pid: pid_t) -> Owner {
            if let known = owners[pid] { return known }
            let app = NSRunningApplication(processIdentifier: pid)
            let found = Owner(regular: app?.activationPolicy == .regular, bundleID: app?.bundleIdentifier, name: app?.localizedName)
            owners[pid] = found
            return found
        }
        var apps: [MixerApp] = []
        for object in MixerHAL.objects(MixerHAL.system, kAudioHardwarePropertyProcessObjectList) {
            guard let raw = MixerHAL.uint32(object, kAudioProcessPropertyPID) else { continue }
            let pid = pid_t(bitPattern: raw)
            guard pid > 0, pid != own,
                  let app = MixerAttribution.owner(of: pid, responsible: responsibleApp, parent: parent,
                                                   isRegularApp: { owner($0).regular }) else { continue }
            scan.objects.insert(object)
            let info = owner(app)
            let bundle = info.bundleID ?? (app == pid ? MixerHAL.string(object, kAudioProcessPropertyBundleID) : nil)
            let name = info.name ?? processName(app)
            let identity = MixerIdentity(bundleID: bundle, name: name, pid: app)
            let playing = (MixerHAL.uint32(object, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
            apps.append(MixerApp(id: identity.rowID, storageKey: identity.storageKey, name: name ?? "Process \(app)",
                                 bundleID: bundle, pid: app, objects: [object], isPlaying: playing,
                                 isBypassed: MixerBypass.isBypassed(bundleID: bundle, name: name)))
        }
        scan.apps = MixerApp.merge(apps)
        return scan
    }

    private static func responsibleApp(_ pid: Int32) -> Int32? {
        guard let responsible else { return pid }
        let owner = responsible(pid)
        return owner > 0 ? owner : nil
    }

    private static func parent(_ pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(bitPattern: info.pbi_ppid)
    }

    /// `proc_name`, else the executable's file name (macOS refuses `proc_name` for other users' processes).
    private static func processName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !name.isEmpty { return name }
        }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let full = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return full.isEmpty ? nil : (full as NSString).lastPathComponent
    }
}
