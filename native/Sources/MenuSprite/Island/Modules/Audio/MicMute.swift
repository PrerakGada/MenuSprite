import AppKit
import CoreAudio
import IslandKit
import os

/// Mutes every microphone the Mac has, not just the default one (a call app may use its own headset),
/// and puts each back exactly as it was. What it changed is recorded per device and persisted, so an
/// unmute touches only those devices, and a crash is undone the next time the island starts. The
/// record changes one device at a time behind a lock, so a sweep that was stuck in the driver and
/// returns late cannot overwrite newer claims; before each device a sweep checks it is still the
/// newest and stops otherwise.
final class MicMuteEngine: Sendable {
    static let recordKey = "MenuSprite.Island.Audio.microphoneClaims"
    private static let log = Logger(subsystem: "in.prerakgada.MenuSprite", category: "IslandMicrophone")

    /// What a finished sweep found on the devices themselves.
    struct Report: Sendable {
        var verdict: IslandMicMuteVerdict
        var claims: Int
    }

    private struct State {
        var loaded = false
        /// nil when a stored record exists but cannot be read: an unmute then touches nothing.
        var record: IslandMicMuteRecord?
        var generation = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var claimCount: Int { withState { $0.record?.claims.count ?? 0 } }

    /// The newest sweep; older ones stop before their next device.
    func supersede(with generation: Int) {
        withState { $0.generation = max($0.generation, generation) }
    }

    /// Mutes or unmutes every microphone. nil when a newer sweep took over.
    func apply(muted: Bool, generation: Int) -> Report? {
        muted ? mute(generation) : unmute(generation)
    }

    private func mute(_ generation: Int) -> Report? {
        for id in AudioHAL.devices() {
            guard isLatest(generation) else { return nil }
            guard let device = Self.device(id), !IslandMicMuteRules.isOwnAggregate(device) else { continue }
            let existing = claim(for: device.uid)
            switch IslandMicMuteRules.mutePlan(for: device, alreadyClaimed: existing != nil) {
            case .leave:
                continue
            case .setSwitch:
                _ = AudioHAL.setMute(id, AudioHAL.input, true)
                if let after = Self.device(id), IslandMicMuteRules.isSilent(after) { commit(device.uid, .muteSwitch) }
            case .zeroLevels(let saved):
                for element in AudioHAL.elements { _ = AudioHAL.setScalar(id, AudioHAL.input, element: element, 0) }
                // Claim only what really went silent, keeping levels saved by an earlier sweep.
                if let after = Self.device(id), IslandMicMuteRules.isSilent(after) {
                    if saved.isEmpty, case .levels(let earlier)? = existing {
                        commit(device.uid, .levels(earlier))
                    } else {
                        commit(device.uid, .levels(saved))
                    }
                }
            }
        }
        return report(requested: true, generation)
    }

    private func unmute(_ generation: Int) -> Report? {
        var present: [String: AudioObjectID] = [:]
        for id in AudioHAL.devices() {
            if let device = Self.device(id), !IslandMicMuteRules.isOwnAggregate(device) { present[device.uid] = id }
        }
        let targets = withState { IslandMicMuteRules.unmuteTargets(record: $0.record) }
        for uid in targets {
            guard isLatest(generation) else { return nil }
            // Another sweep may have settled it meanwhile.
            guard let claim = claim(for: uid) else { continue }
            let id = present[uid]
            switch IslandMicMuteRules.unmutePlan(claim: claim, device: id.flatMap(Self.device)) {
            case .keepClaim:
                continue
            case .clearSwitch:
                if let id, AudioHAL.setMute(id, AudioHAL.input, false) { commit(uid, nil) }
            case .restore(let levels):
                guard let id else { continue }
                let restored = levels.map { AudioHAL.setScalar(id, AudioHAL.input, element: $0.key, $0.value) }
                if restored.contains(true) { commit(uid, nil) }
            case .dropClaim:
                commit(uid, nil)
            }
        }
        return report(requested: false, generation)
    }

    /// The verdict is read back from every present device, never assumed from the request.
    private func report(requested: Bool, _ generation: Int) -> Report? {
        let present = AudioHAL.devices().compactMap(Self.device).filter { !IslandMicMuteRules.isOwnAggregate($0) }
        guard isLatest(generation) else { return nil }
        let claimed = withState { Set($0.record.map { Array($0.claims.keys) } ?? []) }
        return Report(verdict: IslandMicMuteRules.verdict(requested: requested, present: present, claimed: claimed),
                      claims: claimed.count)
    }

    // MARK: Record

    private func isLatest(_ generation: Int) -> Bool { withState { $0.generation == generation } }

    private func claim(for uid: String) -> IslandMicClaim? { withState { $0.record?.claims[uid] } }

    /// One device's change, saved at once. An unreadable record is replaced by the first new claim.
    private func commit(_ uid: String, _ claim: IslandMicClaim?) {
        withState { state in
            var record = state.record ?? IslandMicMuteRecord()
            record.claims[uid] = claim
            state.record = record
            let defaults = UserDefaults.standard
            if record.claims.isEmpty {
                defaults.removeObject(forKey: Self.recordKey)
            } else if let data = try? JSONEncoder().encode(record) {
                defaults.set(data, forKey: Self.recordKey)
            }
        }
    }

    private func withState<Value: Sendable>(_ body: @Sendable (inout State) -> Value) -> Value {
        state.withLock { state in
            if !state.loaded {
                state.loaded = true
                state.record = Self.load()
            }
            return body(&state)
        }
    }

    private static func load() -> IslandMicMuteRecord? {
        guard let stored = UserDefaults.standard.object(forKey: recordKey) else { return IslandMicMuteRecord() }
        if let data = stored as? Data, let record = try? JSONDecoder().decode(IslandMicMuteRecord.self, from: data) { return record }
        log.error("The saved microphone claims could not be read; unmuting will not touch any microphone.")
        return nil
    }

    /// An input device with a UID that is alive, as the rules see it.
    private static func device(_ id: AudioObjectID) -> IslandMicDevice? {
        guard AudioHAL.hasStreams(id, AudioHAL.input), AudioHAL.flag(id, kAudioDevicePropertyDeviceIsAlive) != false,
              let uid = AudioHAL.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return IslandMicDevice(uid: uid,
                               name: AudioHAL.string(id, kAudioObjectPropertyName) ?? uid,
                               isAggregate: AudioHAL.transport(id) == kAudioDeviceTransportTypeAggregate,
                               muteSwitch: AudioHAL.hasSettableMute(id, AudioHAL.input) ? AudioHAL.mute(id, AudioHAL.input) : nil,
                               levels: AudioHAL.scalars(id, AudioHAL.input))
    }
}

/// The Mute microphone tile. It shows what the microphones really are after each sweep (never the
/// request), keeps retrying on device changes until a request fully applies, and never leaves a
/// microphone muted: the island stopping unmutes, and quitting unmutes before the app exits.
@MainActor
final class MicMuteController {
    let control: IslandControlModel
    private let work = IslandHALQueue(label: "in.prerakgada.MenuSprite.island.microphone", limit: 2)
    private let engine = MicMuteEngine()
    private var intent = IslandMicMuteIntent()
    private var verdict = IslandMicMuteVerdict.live
    private var responding = true
    private var claims = 0
    private var active = false
    private var tokens: [AudioListeners.Token] = []
    private var termination: NSObjectProtocol?

    init() {
        control = IslandControlModel(.microphone) {}
        control.perform = { [weak self] in self?.click() }
        work.onStall = { [weak self] in self?.stalled() }
        work.onRecover = { [weak self] in self?.reconcile() }
        publish()
    }

    private var isApplied: Bool { responding && verdict.isApplied }

    /// The island started: undo anything a previous run left muted.
    func start() {
        active = true
        let engine = engine
        work.run({ engine.claimCount }) { [weak self] claims in
            guard let self, claims > 0, !self.intent.requested else { return }
            self.request(false)
        }
    }

    /// The island stopped: open every microphone it closed, then release the listeners.
    func stop() {
        active = false
        if intent.requested || claims > 0 || !isApplied { request(false) } else { syncObservers() }
    }

    /// Open → mute; muted → unmute. Anything not fully applied opens every microphone the island
    /// closed: never stranding a muted microphone comes first, and muting can be tried again from there.
    private func click() { request(verdict == .live && responding) }

    private func request(_ muted: Bool) { sweep(muted: muted, generation: intent.request(muted)) }

    /// A device came or went, or a stuck call returned: apply what was last asked for again.
    private func reconcile() {
        let change = intent.deviceChanged()
        sweep(muted: change.muted, generation: change.generation)
    }

    private func sweep(muted: Bool, generation: Int) {
        engine.supersede(with: generation)
        let engine = engine
        work.run({ engine.apply(muted: muted, generation: generation) }) { [weak self] report in
            self?.finished(report, generation: generation)
        }
        syncObservers()
    }

    private func finished(_ report: MicMuteEngine.Report?, generation: Int) {
        guard let report, intent.isCurrent(generation) else { return }
        claims = report.claims
        verdict = report.verdict
        responding = true
        publish()
        syncObservers()
    }

    private func stalled() {
        responding = false
        publish()
        syncObservers()
    }

    private func publish() {
        let state: (title: String, symbol: String, on: Bool) = if !responding {
            ("Microphone not responding", "exclamationmark.triangle.fill", false)
        } else {
            switch verdict {
            case .live: ("Mute microphone", "mic.fill", false)
            case .muted: ("Unmute microphone", "mic.slash.fill", true)
            case .partlyMuted: ("Microphone partly muted", "exclamationmark.triangle.fill", false)
            case .stillMuted: ("Microphone still muted", "exclamationmark.triangle.fill", false)
            }
        }
        control.isOn = state.on
        control.title = state.title
        control.symbol = state.symbol
    }

    /// Device listeners while muted, while claims are outstanding or while a request has not fully
    /// applied, and only while the island runs.
    private func syncObservers() {
        let needed = IslandMicMuteIntent.needsListeners(requested: intent.requested, claims: claims, applied: isApplied)
        if needed && active && tokens.isEmpty {
            let handler: @Sendable () -> Void = { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.devicesChanged() } }
            }
            let reserved = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice].map {
                AudioListeners.reserve(AudioHAL.system, AudioHAL.address($0), handler: handler)
            }
            tokens = reserved
            work.enqueue { reserved.forEach(AudioListeners.attach) }
        } else if !(needed && active) && !tokens.isEmpty {
            let released = tokens
            tokens = []
            work.enqueue { released.forEach(AudioListeners.remove) }
        }
        if needed && termination == nil {
            termination = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.unmuteBeforeQuitting() }
            }
        } else if !needed, let observer = termination {
            NotificationCenter.default.removeObserver(observer)
            termination = nil
        }
    }

    private func devicesChanged() {
        guard !tokens.isEmpty else { return }
        reconcile()
    }

    /// Quitting waits for the unmute, but on a fresh thread and never longer than two seconds: the
    /// island's own queue may be stuck on a reconnecting device.
    private func unmuteBeforeQuitting() {
        let generation = intent.request(false)
        engine.supersede(with: generation)
        let engine = engine
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = engine.apply(muted: false, generation: generation)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }
}
