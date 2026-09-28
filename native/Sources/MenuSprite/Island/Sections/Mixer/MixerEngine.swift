import CoreAudio
import Foundation
import IslandKit

/// One app's audio path through the mixer: a private process tap of the app's audio objects that
/// mutes the app while the tap is being read, a private aggregate device whose only sub-device is
/// the target output and whose input is that tap, and an IO block that plays the tap back scaled.
///
/// Because the tap mutes only while it is read, stopping the IO block hands the app straight back to
/// its normal output at full volume: every failure here fails open. Built off the main thread; the
/// IO block captures only the renderer, whose realtime state is atomics and preallocated storage.
final class MixerEngine: @unchecked Sendable {
    /// Aggregate UIDs start with this, so the mixer never lists or targets its own devices.
    static let uidPrefix = "in.prerakgada.MenuSprite.mixer."

    struct Failure: Error {
        let step: String
        let status: OSStatus
    }

    let configuration: MixerEngineConfiguration
    let renderer: MixerRenderer
    private let tap: AudioObjectID
    private let aggregate: AudioObjectID
    private let ioProc: AudioDeviceIOProcID
    private let rateListener: MixerListener?

    private init(configuration: MixerEngineConfiguration, renderer: MixerRenderer, tap: AudioObjectID,
                 aggregate: AudioObjectID, ioProc: AudioDeviceIOProcID, rateListener: MixerListener?) {
        self.configuration = configuration
        self.renderer = renderer
        self.tap = tap
        self.aggregate = aggregate
        self.ioProc = ioProc
        self.rateListener = rateListener
    }

    /// Creates and starts an engine. Any failure destroys what was created, in reverse order.
    /// Blocking: call on the build queue. `rateQueue` recomputes the limiter release on rate changes.
    static func build(_ configuration: MixerEngineConfiguration, gain: Double, rateQueue: DispatchQueue) throws -> MixerEngine {
        let description = CATapDescription(stereoMixdownOfProcesses: configuration.objects)
        description.name = "MenuSprite Volume mixer"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else { throw Failure(step: "tap", status: status) }

        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MenuSprite Volume mixer",
            kAudioAggregateDeviceUIDKey: uidPrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: configuration.device,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: configuration.device]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: 1]],
            kAudioAggregateDeviceTapAutoStartKey: 1,
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate)
        guard status == noErr, aggregate != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tap)
            throw Failure(step: "aggregate device", status: status)
        }

        let outputs = max(2, MixerHAL.outputChannels(aggregate))
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = MixerHAL.address(kAudioTapPropertyFormat)
        let tapChannels = AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &formatSize, &format) == noErr && format.mChannelsPerFrame > 0
            ? Int(format.mChannelsPerFrame) : 2
        let renderer = MixerRenderer(tapChannels: tapChannels, outputCapacity: outputs,
                                     sampleRate: MixerHAL.double(aggregate, kAudioDevicePropertyNominalSampleRate), gain: gain)
        let device = aggregate
        let rateListener = MixerListener.add(aggregate, kAudioDevicePropertyNominalSampleRate) { [weak renderer] in
            guard let renderer else { return }
            rateQueue.async { renderer.setSampleRate(MixerHAL.double(device, kAudioDevicePropertyNominalSampleRate)) }
        }

        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { _, input, _, output, _ in
            renderer.render(input: input, output: output)
        }
        guard status == noErr, let procID else {
            rateListener?.remove()
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            throw Failure(step: "render callback", status: status)
        }
        status = AudioDeviceStart(aggregate, procID)
        guard status == noErr else {
            rateListener?.remove()
            AudioDeviceDestroyIOProcID(aggregate, procID)
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            throw Failure(step: "start", status: status)
        }
        return MixerEngine(configuration: configuration, renderer: renderer, tap: tap, aggregate: aggregate,
                           ioProc: procID, rateListener: rateListener)
    }

    /// Stops reading the tap: from this moment the app plays normally again. Call before `destroy`,
    /// never on the main thread.
    func stop() { AudioDeviceStop(aggregate, ioProc) }

    /// Removes the rate listener, the IO block, the aggregate device and the tap. A wedged HAL can park
    /// these calls indefinitely, so they run on the bounded teardown queue.
    func destroy() {
        rateListener?.remove()
        AudioDeviceDestroyIOProcID(aggregate, ioProc)
        AudioHardwareDestroyAggregateDevice(aggregate)
        AudioHardwareDestroyProcessTap(tap)
    }
}
