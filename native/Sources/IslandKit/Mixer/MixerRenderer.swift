import CoreAudio
import Foundation
import Synchronization

/// The work one mixer engine does on every IO cycle: take the app's tapped audio from the input side
/// of its private aggregate device, scale it, write it to the output side, silence everything not
/// written and run the limiter. Built for the realtime thread: the gain, the cycle counter and the
/// release coefficient are atomics, the limiter's storage is preallocated, and `render` never
/// allocates, locks or logs. Other threads only call the atomic setters and getters.
public final class MixerRenderer: @unchecked Sendable {
    public let tapChannels: Int
    private let gainBits: Atomic<UInt32>
    private let cycleCount = Atomic<UInt64>(0)
    private let releaseBits: Atomic<UInt64>
    private let limiter: UnsafeMutablePointer<MixerLimiter>

    public init(tapChannels: Int, outputCapacity: Int, sampleRate: Double?, gain: Double) {
        self.tapChannels = max(1, tapChannels)
        gainBits = Atomic(Float(MixerLevel.clamp(gain, maximum: MixerLevel.appMaximum) ?? 1).bitPattern)
        releaseBits = Atomic(MixerLimiter.releaseCoefficient(sampleRate: sampleRate).bitPattern)
        limiter = .allocate(capacity: 1)
        limiter.initialize(to: MixerLimiter(capacity: max(2, outputCapacity)))
    }

    deinit {
        limiter.pointee.deallocate()
        limiter.deinitialize(count: 1)
        limiter.deallocate()
    }

    /// 0…2, applied from the next buffer on. Non-finite values are ignored.
    public var gain: Double {
        get { Double(Float(bitPattern: gainBits.load(ordering: .relaxed))) }
        set {
            guard let value = MixerLevel.clamp(newValue, maximum: MixerLevel.appMaximum) else { return }
            gainBits.store(Float(value).bitPattern, ordering: .relaxed)
        }
    }

    /// Cycles that delivered the app's audio to the device; the watchdog watches it advance.
    public var cycles: UInt64 { cycleCount.load(ordering: .relaxed) }

    /// A headset renegotiating its rate changes the release under a running engine.
    public func setSampleRate(_ rate: Double?) {
        releaseBits.store(MixerLimiter.releaseCoefficient(sampleRate: rate).bitPattern, ordering: .relaxed)
    }

    /// Frames in a buffer of 32-bit float samples.
    public static func frames(bytes: UInt32, channels: UInt32) -> Int {
        channels == 0 ? 0 : Int(bytes) / (MemoryLayout<Float>.size * Int(channels))
    }

    /// The input buffer carrying the tap: the last one with the tap's channel count (a device that
    /// also records puts its microphone first), or the only buffer there is. Otherwise none, so a
    /// microphone is never played out of the speakers.
    public static func tapBuffer(in input: UnsafeMutableAudioBufferListPointer, tapChannels: Int) -> AudioBuffer? {
        var found: AudioBuffer?
        for buffer in input where Int(buffer.mNumberChannels) == tapChannels && buffer.mData != nil { found = buffer }
        if found == nil, input.count == 1, input[0].mData != nil, input[0].mNumberChannels > 0 { found = input[0] }
        return found
    }

    public func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let tap = Self.tapBuffer(in: inputs, tapChannels: tapChannels), let source = tap.mData?.assumingMemoryBound(to: Float.self) else {
            Self.silence(outputs, from: 0)
            return
        }
        let sourceChannels = Int(tap.mNumberChannels)
        var frames = Self.frames(bytes: tap.mDataByteSize, channels: tap.mNumberChannels)
        var total = 0
        for buffer in outputs where buffer.mData != nil && buffer.mNumberChannels > 0 {
            frames = min(frames, Self.frames(bytes: buffer.mDataByteSize, channels: buffer.mNumberChannels))
            total += Int(buffer.mNumberChannels)
        }
        let gain = Float(bitPattern: gainBits.load(ordering: .relaxed))
        var delivered = false
        var channel = 0
        for buffer in outputs {
            let count = Int(buffer.mNumberChannels)
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { channel += count; continue }
            for index in 0..<count {
                if frames > 0, write(to: data, stride: count, offset: index, outputChannel: channel, totalOutputs: total,
                                     source: source, sourceChannels: sourceChannels, frames: frames, gain: gain) {
                    delivered = true
                } else {
                    for frame in 0..<frames { data[frame * count + index] = 0 }
                }
                channel += 1
            }
        }
        Self.silence(outputs, from: frames)
        guard delivered else { return }
        cycleCount.wrappingAdd(1, ordering: .relaxed)
        limiter.pointee.process(outputs, frames: frames, releaseCoefficient: Double(bitPattern: releaseBits.load(ordering: .relaxed)))
    }

    /// Output channel n takes tap channel n; a mono tap feeds the first two; a lone mono output gets
    /// the tap's channels averaged. Returns false for channels with no source (left silent).
    private func write(to data: UnsafeMutablePointer<Float>, stride: Int, offset: Int, outputChannel: Int, totalOutputs: Int,
                       source: UnsafeMutablePointer<Float>, sourceChannels: Int, frames: Int, gain: Float) -> Bool {
        if totalOutputs == 1 {
            let scale = gain / Float(sourceChannels)
            for frame in 0..<frames {
                var sum: Float = 0
                for input in 0..<sourceChannels { sum += source[frame * sourceChannels + input] }
                data[frame * stride + offset] = sum * scale
            }
            return true
        }
        let input: Int
        if sourceChannels == 1 {
            guard outputChannel < 2 else { return false }
            input = 0
        } else {
            guard outputChannel < sourceChannels else { return false }
            input = outputChannel
        }
        for frame in 0..<frames { data[frame * stride + offset] = source[frame * sourceChannels + input] * gain }
        return true
    }

    /// Output buffers arrive holding stale audio; everything from `frame` on is zeroed.
    private static func silence(_ outputs: UnsafeMutableAudioBufferListPointer, from frame: Int) {
        for buffer in outputs {
            guard let data = buffer.mData else { continue }
            let offset = frame * MemoryLayout<Float>.size * Int(buffer.mNumberChannels)
            let size = Int(buffer.mDataByteSize)
            guard offset < size else { continue }
            memset(data + offset, 0, size - offset)
        }
    }
}
