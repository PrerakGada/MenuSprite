import CoreAudio
import Foundation

/// A lookahead peak limiter for one mixer engine, safe to run on the realtime audio thread: its delay
/// storage is allocated once, up front, and `process` never allocates, locks or logs.
///
/// Every sample is delayed by `lookahead` frames. When an incoming frame would exceed the ceiling, the
/// gain ramps down linearly so it reaches the needed level exactly when that frame leaves the delay
/// line, holds, then recovers exponentially with a release that takes the same time at any sample rate.
/// One gain is shared by every channel of every buffer so the stereo image never shifts. Audio already
/// inside the ceiling passes bit-identical after the delay. It runs for every live engine, even below
/// 100 %, so moving into boost never inserts a fresh block of delay into playing audio.
public struct MixerLimiter {
    public static let ceiling: Float = 0.944
    public static let lookahead = 256
    public static let releaseSeconds = 0.160
    public static let fallbackSampleRate = 48_000.0

    /// The rate the release is computed from: the device's, or 48 kHz when it could not be read.
    public static func effectiveRate(_ rate: Double?) -> Double {
        guard let rate, rate.isFinite, rate > 0 else { return fallbackSampleRate }
        return rate
    }

    /// Per-frame recovery coefficient toward unity: exp(−1 / (rate × 0.160 s)).
    public static func releaseCoefficient(sampleRate: Double?) -> Double {
        exp(-1 / (effectiveRate(sampleRate) * releaseSeconds))
    }

    /// Channels the delay line was allocated for.
    public let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private var channels = 0
    private var position = 0
    public private(set) var gain = 1.0
    private var target = 1.0
    private var slope = 0.0
    private var hold = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = .allocate(capacity: self.capacity * Self.lookahead)
        storage.initialize(repeating: 0, count: self.capacity * Self.lookahead)
    }

    /// Frees the delay line. Call once, after the last `process`.
    public func deallocate() { storage.deallocate() }

    /// The storage address, so tests can check a shape change reuses it.
    public var storageAddress: UnsafeRawPointer { UnsafeRawPointer(storage) }

    /// Limits the first `frames` frames of every buffer in place.
    public mutating func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, releaseCoefficient: Double) {
        guard frames > 0 else { return }
        var total = 0
        for buffer in buffers { total += Int(buffer.mNumberChannels) }
        guard total > 0 else { return }
        if total > capacity {
            processWithoutLookahead(buffers, frames: frames, releaseCoefficient: releaseCoefficient)
            return
        }
        if total != channels {
            // A new stream shape starts from an empty delay line, in the same storage.
            storage.update(repeating: 0, count: capacity * Self.lookahead)
            channels = total
            position = 0
        }
        let length = Self.lookahead
        for frame in 0..<frames {
            require(peak(buffers, frame: frame))
            advance(releaseCoefficient)
            let gain = Float(self.gain)
            var channel = 0
            for buffer in buffers {
                let count = Int(buffer.mNumberChannels)
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { channel += count; continue }
                for index in 0..<count {
                    let slot = storage + (channel * length + position)
                    let delayed = slot.pointee
                    slot.pointee = data[frame * count + index]
                    data[frame * count + index] = gain == 1 ? delayed : delayed * gain
                    channel += 1
                }
            }
            position = position + 1 == length ? 0 : position + 1
        }
    }

    /// More channels than the delay line holds: limit in place with no delay rather than fail.
    private mutating func processWithoutLookahead(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, releaseCoefficient: Double) {
        for frame in 0..<frames {
            let peak = peak(buffers, frame: frame)
            if peak > Self.ceiling {
                gain = min(gain, Double(Self.ceiling / peak))
                target = gain
                slope = 0
                hold = 2 * Self.lookahead
            } else {
                advance(releaseCoefficient)
            }
            let gain = Float(self.gain)
            guard gain != 1 else { continue }
            for buffer in buffers {
                let count = Int(buffer.mNumberChannels)
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for index in 0..<count { data[frame * count + index] *= gain }
            }
        }
    }

    private func peak(_ buffers: UnsafeMutableAudioBufferListPointer, frame: Int) -> Float {
        var peak: Float = 0
        for buffer in buffers {
            let count = Int(buffer.mNumberChannels)
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for index in 0..<count { peak = max(peak, abs(data[frame * count + index])) }
        }
        return peak
    }

    /// A frame entering the delay line needs the gain at or below ceiling / peak by the time it leaves.
    private mutating func require(_ peak: Float) {
        guard peak > Self.ceiling else { return }
        let needed = Double(Self.ceiling) / Double(peak)
        hold = 2 * Self.lookahead
        let ramping = slope > 0
        if ramping ? target <= needed : gain <= needed { return }
        // A faster ramp already under way is kept; the new one must also land by its own deadline.
        slope = max(ramping ? slope : 0, (gain - needed) / Double(Self.lookahead))
        target = ramping ? min(target, needed) : needed
    }

    private mutating func advance(_ coefficient: Double) {
        if slope > 0 {
            let next = gain - slope
            if next <= target + 1e-12 {
                gain = target
                slope = 0
            } else {
                gain = next
            }
        } else if gain < 1, hold == 0 {
            let next = 1 - (1 - gain) * coefficient
            gain = 1 - next < 1e-6 ? 1 : next
            target = gain
        }
        if hold > 0 { hold -= 1 }
    }
}
