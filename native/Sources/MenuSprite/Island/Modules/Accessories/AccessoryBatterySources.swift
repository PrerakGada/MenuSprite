import Foundation
import IOKit
import IslandKit

/// Reads accessory batteries from the IORegistry: only entries that carry a battery key are
/// matched (the kernel filters them), and only the few properties a reading needs are fetched.
/// Needs no permission. Blocking IPC, so callers run it off the main thread.
enum AccessoryRegistrySweep {
    nonisolated static func read(observedAt: Date) -> [AccessoryReading] {
        var readings: [AccessoryReading] = []
        var seen = Set<UInt64>()
        for className in AccessoryRegistry.classes {
            for key in AccessoryRegistry.batteryKeys {
                let matching = IOServiceMatching(className) as NSMutableDictionary
                matching["IOPropertyExistsMatch"] = key
                var iterator: io_iterator_t = 0
                guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { continue }
                defer { IOObjectRelease(iterator) }
                while case let service = IOIteratorNext(iterator), service != 0 {
                    defer { IOObjectRelease(service) }
                    var entryID: UInt64 = 0
                    IORegistryEntryGetRegistryEntryID(service, &entryID)
                    guard seen.insert(entryID).inserted else { continue }
                    var properties: [String: Any] = [:]
                    for property in AccessoryRegistry.keys {
                        properties[property] = IORegistryEntryCreateCFProperty(service, property as CFString, kCFAllocatorDefault, 0)?
                            .takeRetainedValue()
                    }
                    if let reading = AccessoryRegistry.reading(properties, entryID: entryID, observedAt: observedAt) {
                        readings.append(reading)
                    }
                }
            }
        }
        return AccessoryReading.merge([readings])
    }
}

/// Runs Apple's `system_profiler` for its Bluetooth report, the permission-free source of earbud
/// levels and paired devices' types. A child process with a 2-second timeout and a 4 MB output
/// cap, cancellable, run on its own utility queue so nothing blocks the main thread or the
/// concurrency pool. One runner serves one activation; once cancelled it never starts again.
final class AccessoryBluetoothReportRunner: Sendable {
    static let timeout: TimeInterval = 2
    static let outputCap = 4 << 20

    private let queue = DispatchQueue(label: "in.prerakgada.MenuSprite.island.accessories.report", qos: .utility)
    private let child = ReportChild()

    func run(observedAt: Date) async -> AccessoryBluetoothReport.Result? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: self.runBlocking(observedAt: observedAt)) }
            }
        } onCancel: {
            child.cancel()
        }
    }

    private func runBlocking(observedAt: Date) -> AccessoryBluetoothReport.Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = AccessoryBluetoothReport.arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard child.start(process) else { return nil }
        let child = child
        let deadline = DispatchWorkItem { child.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.timeout, execute: deadline)

        var output = Data()
        var overflowed = false
        let reader = pipe.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            output.append(chunk)
            if output.count > Self.outputCap {
                overflowed = true
                child.terminate()
                break
            }
        }
        process.waitUntilExit()
        deadline.cancel()
        child.finish()
        try? reader.close()
        guard !overflowed, process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return AccessoryBluetoothReport.parse(output, observedAt: observedAt)
    }
}

/// The report's running child process, reachable from the cancel handler and the timeout.
/// `Process.terminate()` is safe from any thread; the lock only guards the handoff.
private final class ReportChild: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    /// Launches the process unless the run was already cancelled.
    func start(_ process: Process) -> Bool {
        lock.withLock {
            guard !cancelled, (try? process.run()) != nil else { return false }
            self.process = process
            return true
        }
    }

    func terminate() { lock.withLock { process?.terminate() } }
    func finish() { lock.withLock { process = nil } }
    func cancel() {
        lock.withLock {
            cancelled = true
            process?.terminate()
        }
    }
}
