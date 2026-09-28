import CoreAudio
import Foundation

/// The mixer's view of the HAL: the system listeners (process list, devices, default outputs), one
/// running-output listener pair per listed audio object, and the scans. Everything runs on its own
/// serial queue; `changed` fires on a HAL thread and must only hop.
final class MixerObserver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "in.prerakgada.MenuSprite.mixer.hal", qos: .userInitiated)
    private let changed: @Sendable () -> Void
    // Touched only on `queue`.
    private var watching = false
    private var system: [MixerListener] = []
    private var perObject: [AudioObjectID: [MixerListener]] = [:]

    init(changed: @escaping @Sendable () -> Void) { self.changed = changed }

    func start() {
        queue.async { [self] in
            guard !watching else { return }
            watching = true
            let selectors = [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDevices,
                             kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice]
            system = selectors.compactMap { MixerListener.add(MixerHAL.system, $0, handler: changed) }
        }
    }

    func stop() {
        queue.async { [self] in
            watching = false
            system.forEach { $0.remove() }
            system = []
            perObject.values.joined().forEach { $0.remove() }
            perObject = [:]
        }
    }

    /// Reads the HAL and follows the running state of every object it found. Some HAL versions
    /// change `IsRunningOutput` without notifying, so `IsRunning` is watched too.
    func scan(_ completion: @escaping @Sendable (MixerScan) -> Void) {
        queue.async { [self] in
            let scan = MixerProcessScanner.scan()
            if watching {
                for (object, listeners) in perObject where !scan.objects.contains(object) {
                    listeners.forEach { $0.remove() }
                    perObject[object] = nil
                }
                for object in scan.objects where perObject[object] == nil {
                    perObject[object] = [kAudioProcessPropertyIsRunningOutput, kAudioProcessPropertyIsRunning]
                        .compactMap { MixerListener.add(object, $0, handler: changed) }
                }
            }
            completion(scan)
        }
    }
}
