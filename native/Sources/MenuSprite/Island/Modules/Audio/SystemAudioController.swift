import AudioToolbox
import CoreAudio
import Foundation
import IslandKit

/// One read of the system's output and input, taken on the audio queue.
struct AudioSnapshot: Sendable, Equatable {
    var outputs: [IslandAudioDevice] = []
    var output: IslandAudioDevice?
    var volume: Double?
    var muted = false
    var hasMute = false
    var inputs: [IslandAudioDevice] = []
    var input: IslandAudioDevice?
    var inputVolume: Double?

    static func read(includeInputs: Bool) -> AudioSnapshot {
        let outputID = AudioHAL.defaultDevice(input: false)
        let inputID = includeInputs ? AudioHAL.defaultDevice(input: true) : nil
        let lists = AudioHAL.deviceLists(defaultOutput: outputID, defaultInput: inputID, includeInputs: includeInputs)
        var snapshot = AudioSnapshot(outputs: lists.outputs, inputs: lists.inputs)
        if let outputID {
            snapshot.output = lists.outputs.first { $0.id == outputID } ?? AudioHAL.describe(outputID, scope: AudioHAL.output)
            snapshot.volume = AudioHAL.volume(outputID, AudioHAL.output)
            snapshot.muted = AudioHAL.mute(outputID, AudioHAL.output) ?? false
            snapshot.hasMute = AudioHAL.hasSettableMute(outputID, AudioHAL.output)
        }
        if let inputID {
            snapshot.input = lists.inputs.first { $0.id == inputID }
            snapshot.inputVolume = AudioHAL.volume(inputID, AudioHAL.input) ?? channelMean(inputID)
        }
        return snapshot
    }

    private static func channelMean(_ device: AudioObjectID) -> Double? {
        let channels = AudioHAL.scalars(device, AudioHAL.input).filter { $0.key != AudioHAL.main }
        guard !channels.isEmpty else { return nil }
        return Double(channels.values.reduce(0, +)) / Double(channels.count)
    }
}

/// How an output write ended. Only `failed` hands a key back to macOS: a discarded write belonged to
/// an output that is no longer the default, and replaying it would land on the new one.
enum OutputWriteResult: Sendable {
    case written, failed, discarded
}

/// Owns the system output and input behind `IslandSystemAudio`: CoreAudio listeners, reads, writes and
/// which observed changes raise the volume notice. It observes only while someone holds interest in
/// the shared state or the volume indicator is wanted, and stops completely otherwise. A driver call
/// stuck on a reconnecting device marks the output unavailable instead of wedging every later call.
@MainActor
final class SystemAudioController: ObservableObject {
    static let notResponding = "Not responding"

    /// True once the first reading since observation started has landed.
    @Published private(set) var hasReading = false
    let audio: IslandSystemAudio
    /// Every HAL read and write runs here, never on the main thread.
    private let work = IslandHALQueue(label: "in.prerakgada.MenuSprite.island.audio", limit: 2)
    /// An observed change the notice should report (not the island's own echo).
    var onChange: (() -> Void)?
    var isOpen: () -> Bool = { false }

    var indicatorWanted = false { didSet { if indicatorWanted != oldValue { sync() } } }

    private var observing = false
    private var observingInput = false
    private var systemTokens: [AudioListeners.Token] = []
    private var outputTokens: [AudioListeners.Token] = []
    private var inputTokens: [AudioListeners.Token] = []
    private var listenedOutput: AudioObjectID?
    private var listenedInput: AudioObjectID?
    private var lifetime = 0
    private var feedback = IslandVolumeFeedback()
    private var writes = IslandOutputWriteQueue()
    private var waiters: [Int: (OutputWriteResult) -> Void] = [:]
    private var nextWaiter = 1
    private var readTask: Task<Void, Never>?
    private var pendingInputVolume: Double?
    private var writingInput = false
    /// The driver stopped answering: only device-list changes, a switch, or the stuck call returning
    /// trigger another read, so a device that stays stuck cannot pile up blocked threads.
    private var isStalled = false

    init(audio: IslandSystemAudio) {
        self.audio = audio
        work.onStall = { [weak self] in self?.stalled() }
        work.onRecover = { [weak self] in self?.recovered() }
        audio.demandChanged = { [weak self] _ in self?.sync() }
        audio.setVolume = { [weak self] level in self?.setVolume(level, own: true) }
        audio.setMuted = { [weak self] muted in self?.request(volume: nil, muted: muted, own: true) }
        audio.selectOutput = { [weak self] device in self?.select(device, input: false) }
        audio.selectInput = { [weak self] device in self?.select(device, input: true) }
        audio.setInputVolume = { [weak self] level in self?.setInputVolume(level) }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Observation

    private func sync() {
        let wantOutput = audio.interest > 0 || indicatorWanted
        let wantInput = audio.interest > 0
        if wantOutput && !observing { start(input: wantInput) }
        else if !wantOutput && observing { stop() }
        else if observing && wantInput != observingInput {
            observingInput = wantInput
            if !wantInput { moveInputListeners(to: nil) }
            scheduleRead(after: 0)
        }
    }

    private func start(input: Bool) {
        observing = true
        observingInput = input
        lifetime += 1
        feedback.start(lifetime: lifetime)
        let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioHardwarePropertyDefaultInputDevice]
        systemTokens = register(AudioHAL.system, selectors.map { AudioHAL.address($0) })
        scheduleRead(after: 0)
    }

    private func stop() {
        observing = false
        observingInput = false
        readTask?.cancel()
        readTask = nil
        unregister(systemTokens + outputTokens + inputTokens)
        systemTokens = []
        outputTokens = []
        inputTokens = []
        listenedOutput = nil
        listenedInput = nil
        feedback.stop()
        settle(writes.abandon(), .discarded)
        writingInput = false
        pendingInputVolume = nil
        clearStall()
        hasReading = false
    }

    /// Tokens are known at once; the HAL registration follows on the audio queue.
    private func register(_ object: AudioObjectID, _ addresses: [AudioObjectPropertyAddress]) -> [AudioListeners.Token] {
        let system = object == AudioHAL.system
        let handler: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.listenerFired(system: system) } }
        }
        let tokens = addresses.map { AudioListeners.reserve(object, $0, handler: handler) }
        work.enqueue { tokens.forEach(AudioListeners.attach) }
        return tokens
    }

    private func unregister(_ tokens: [AudioListeners.Token]) {
        guard !tokens.isEmpty else { return }
        work.enqueue { tokens.forEach(AudioListeners.remove) }
    }

    /// While stalled, only the system object (devices, defaults) may trigger a read.
    private func listenerFired(system: Bool) {
        guard observing, system || !isStalled else { return }
        scheduleRead(after: IslandVolumeFeedback.readDelay)
    }

    /// Bursts of callbacks fold into one read after the last of them.
    private func scheduleRead(after delay: TimeInterval) {
        readTask?.cancel()
        let includeInput = observingInput
        readTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, self.observing else { return }
            self.work.run({ AudioSnapshot.read(includeInputs: includeInput) }) { [weak self] snapshot in self?.apply(snapshot) }
        }
    }

    private func apply(_ snapshot: AudioSnapshot) {
        guard observing else { return }
        clearStall()
        assign(\.outputs, snapshot.outputs)
        if snapshot.output?.id != listenedOutput { moveOutputListeners(to: snapshot.output?.id) }
        if !writes.isBusy(lifetime: lifetime) {
            assign(\.output, snapshot.output)
            assign(\.volume, snapshot.volume)
            assign(\.isMuted, snapshot.muted)
            assign(\.hasMute, snapshot.hasMute)
            let reading = IslandVolumeFeedback.Reading(lifetime: lifetime, level: snapshot.volume, muted: snapshot.muted)
            if feedback.receive(reading, isOpen: isOpen(), now: now) { onChange?() }
        }
        if observingInput {
            assign(\.inputs, snapshot.inputs)
            assign(\.input, snapshot.input)
            if snapshot.input?.id != listenedInput { moveInputListeners(to: snapshot.input?.id) }
            if !writingInput && pendingInputVolume == nil { assign(\.inputVolume, snapshot.inputVolume) }
        }
        hasReading = true
    }

    /// Published properties change only when the value did, so a chatty HAL cannot redraw the island.
    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<IslandSystemAudio, Value>, _ value: Value) {
        if audio[keyPath: keyPath] != value { audio[keyPath: keyPath] = value }
    }

    private func moveOutputListeners(to device: AudioObjectID?) {
        unregister(outputTokens)
        outputTokens = []
        listenedOutput = device
        if audio.error != nil { audio.error = nil }
        // A new lifetime: queued writes for the old output are dropped, and its first reading is silent.
        lifetime += 1
        feedback.outputChanged(lifetime: lifetime)
        settle(writes.invalidate(currentLifetime: lifetime), .discarded)
        guard let device else { return }
        let selectors = [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute]
        outputTokens = register(device, selectors.map { AudioHAL.address($0, AudioHAL.output) })
    }

    private func moveInputListeners(to device: AudioObjectID?) {
        unregister(inputTokens)
        inputTokens = []
        listenedInput = device
        guard let device else { return }
        let selectors = [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute]
        inputTokens = register(device, selectors.map { AudioHAL.address($0, AudioHAL.input) })
    }

    // MARK: A stuck driver

    /// The queue was abandoned mid-call: nothing in flight will land, and the output is unknown until
    /// the driver answers again. Keys go back to macOS while the output has no known volume.
    private func stalled() {
        guard observing else { return }
        isStalled = true
        readTask?.cancel()
        readTask = nil
        settle(writes.abandon(), .discarded)
        writingInput = false
        pendingInputVolume = nil
        lifetime += 1
        feedback.outputChanged(lifetime: lifetime)
        assign(\.volume, nil)
        assign(\.hasMute, false)
        assign(\.inputVolume, nil)
        audio.error = Self.notResponding
    }

    private func recovered() {
        if observing { scheduleRead(after: 0) }
    }

    private func clearStall() {
        isStalled = false
        if audio.error == Self.notResponding { audio.error = nil }
    }

    // MARK: Output writes

    /// Sets the level; raising it above 0 also unmutes, as the hardware keys do.
    func setVolume(_ level: Double, own: Bool, completion: ((OutputWriteResult) -> Void)? = nil) {
        let unmute = audio.isMuted && level > 0
        request(volume: level, muted: unmute ? false : nil, own: own, completion: completion)
    }

    /// Updates the published state at once and queues the write. `own` marks the open island's own
    /// controls; a key passes false and shows its notice itself.
    func request(volume: Double?, muted: Bool?, own: Bool, completion: ((OutputWriteResult) -> Void)? = nil) {
        guard observing, !isStalled, let device = listenedOutput else { completion?(.failed); return }
        if let volume, volume.isFinite { audio.volume = min(1, max(0, volume)) }
        if let muted { audio.isMuted = muted }
        feedback.expect(level: audio.volume, muted: audio.isMuted, own: own, now: now)
        let waiter = nextWaiter
        nextWaiter += 1
        if let completion { waiters[waiter] = completion }
        let submission = writes.submit(.init(device: device, lifetime: lifetime, volume: volume, muted: muted, waiters: [waiter]))
        settle(submission.discarded, .discarded)
        if let start = submission.start { perform(start) }
    }

    /// A handled key always raises the notice, even when the level did not change.
    func keyFeedback() -> Bool { feedback.keyPressed(level: audio.volume, muted: audio.isMuted) }

    private func perform(_ write: IslandOutputWriteQueue.Request) {
        work.run({ () -> OutputWriteResult in
            // Before writing, the device must still be the default output.
            guard AudioHAL.defaultDevice(input: false) == write.device else { return .discarded }
            var ok = true
            if let volume = write.volume { ok = AudioHAL.setVolume(write.device, AudioHAL.output, volume) }
            if ok, let muted = write.muted { ok = AudioHAL.setMute(write.device, AudioHAL.output, muted) }
            return ok ? .written : .failed
        }) { [weak self] result in self?.finished(write, result) }
    }

    private func finished(_ write: IslandOutputWriteQueue.Request, _ result: OutputWriteResult) {
        settle(write.waiters, result)
        let next = writes.finish(currentLifetime: lifetime)
        settle(next.discarded, .discarded)
        if let start = next.start { perform(start) } else if observing { scheduleRead(after: 0) }
    }

    private func settle(_ ids: [Int], _ result: OutputWriteResult) {
        for id in ids { waiters.removeValue(forKey: id)?(result) }
    }

    // MARK: Devices and input

    /// Switching is how someone gets away from a stuck output, so it is allowed while stalled.
    private func select(_ device: IslandAudioDevice, input: Bool) {
        let id = device.id
        work.run({ AudioHAL.setDefaultDevice(id, input: input) }) { [weak self] status in
            guard let self else { return }
            if !input { self.audio.error = status == noErr ? nil : "Could not switch: OSStatus \(status)" }
            if self.observing { self.scheduleRead(after: 0) }
        }
    }

    /// Input writes fold to the newest level, one at a time.
    private func setInputVolume(_ level: Double) {
        guard level.isFinite, !isStalled, listenedInput != nil else { return }
        audio.inputVolume = min(1, max(0, level))
        pendingInputVolume = audio.inputVolume
        if !writingInput { writeInput() }
    }

    private func writeInput() {
        guard let level = pendingInputVolume, let device = listenedInput else { return }
        pendingInputVolume = nil
        writingInput = true
        work.run({
            guard !AudioHAL.setVolume(device, AudioHAL.input, level) else { return }
            // No main volume: move every channel, keeping their balance.
            let channels = AudioHAL.scalars(device, AudioHAL.input).filter { $0.key != AudioHAL.main }
            let loudest = channels.values.max() ?? 0
            for (element, value) in channels {
                let scaled = loudest > 0 ? Float(level) * value / loudest : Float(level)
                _ = AudioHAL.setScalar(device, AudioHAL.input, element: element, scaled)
            }
        }) { [weak self] in
            guard let self else { return }
            self.writingInput = false
            if self.pendingInputVolume != nil { self.writeInput() } else if self.observing { self.scheduleRead(after: 0) }
        }
    }
}
