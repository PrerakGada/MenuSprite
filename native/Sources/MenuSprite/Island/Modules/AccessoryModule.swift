import AppKit
import Combine
import IslandKit
import SwiftUI

/// Accessory alerts: a notice when a Bluetooth accessory connects, and one warning when an
/// accessory's battery falls to 20%. Runs only while the island is on and the Accessory alerts
/// indicator is switched on, and asks for no permission: batteries come from the IORegistry (Magic
/// accessories) and Apple's Bluetooth report (earbuds, headphones), connections from CoreAudio and
/// IOKit notifications. Idle cost is one registry sweep a minute and one `system_profiler` run
/// every five minutes; connections are push-only. Clicking a notice opens the System page.
@MainActor
final class AccessoryModule: IslandFeature {
    static let samplingInterval: Duration = .seconds(60)
    static let reportInterval: TimeInterval = 300

    private unowned let environment: IslandEnvironment
    private var settingsObservation: AnyCancellable?
    private var isStarted = false
    private var isActive = false
    /// Bumped on every activation and deactivation so late callbacks from a stopped run are ignored.
    private var generation = 0
    private var sampling: Task<Void, Never>?
    private var monitor: AccessoryConnectionMonitor?
    private var presenter: Task<Void, Never>?
    /// Low-battery episodes. Kept through lock and sleep; forgotten when the alerts are switched off.
    private var watch: AccessoryBatteryWatch?
    private var connections = AccessoryConnections()
    private var queue = AccessoryNoticeQueue()
    /// Paired devices' types from the latest Bluetooth report, by address.
    private var reportedTypes: [String: AccessoryKind] = [:]

    init(environment: IslandEnvironment) {
        self.environment = environment
        environment.register(indicator: .accessories) { .available }
    }

    func islandDidStart() {
        isStarted = true
        settingsObservation = environment.settingsStore.$value
            .map { $0.enabled && $0.indicators.contains(.accessories) }
            .removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.sync() } }
        sync()
    }

    func islandDidStop() {
        isStarted = false
        settingsObservation = nil
        // Lock and sleep keep the episodes; switching the alerts off forgets them.
        deactivate(forgetting: !environment.wants(.accessories))
    }

    private func sync() {
        guard isStarted else { return }
        if environment.wants(.accessories) { activate() } else { deactivate(forgetting: true) }
    }

    // MARK: Lifecycle

    private func activate() {
        guard !isActive else { return }
        isActive = true
        generation += 1
        let generation = generation
        if watch == nil { watch = AccessoryBatteryWatch(activatedAt: Date()) }
        connections = AccessoryConnections()

        let monitor = AccessoryConnectionMonitor { [weak self] source, devices, isBaseline in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.connectionsChanged(source, devices, isBaseline: isBaseline, generation: generation)
                }
            }
        }
        monitor.start()
        self.monitor = monitor

        let runner = AccessoryBluetoothReportRunner()
        sampling = Task { [weak self] in
            var report: AccessoryBluetoothReport.Result?
            var reportedAt: Date?
            while !Task.isCancelled, self != nil {
                let now = Date()
                let registry = await Task.detached(priority: .utility) { AccessoryRegistrySweep.read(observedAt: now) }.value
                if reportedAt.map({ now.timeIntervalSince($0) >= Self.reportInterval }) ?? true {
                    reportedAt = now
                    if let fresh = await runner.run(observedAt: now) { report = fresh }
                }
                guard !Task.isCancelled else { return }
                self?.consume(AccessoryReading.merge([registry, report?.readings ?? []]),
                              types: report?.types ?? [:], generation: generation)
                try? await Task.sleep(for: Self.samplingInterval, tolerance: .seconds(5))
            }
        }
    }

    private func deactivate(forgetting: Bool) {
        if isActive {
            isActive = false
            generation += 1
            sampling?.cancel()
            sampling = nil
            monitor?.stop()
            monitor = nil
        }
        presenter?.cancel()
        presenter = nil
        queue.removeAll()
        connections = AccessoryConnections()
        if forgetting {
            watch = nil
            reportedTypes = [:]
        }
    }

    // MARK: Readings and connections

    private func consume(_ readings: [AccessoryReading], types: [String: AccessoryKind], generation: Int) {
        guard isActive, generation == self.generation, var watch else { return }
        reportedTypes = types
        let outcome = watch.consume(readings)
        self.watch = watch
        outcome.recovered.forEach { queue.withdrawLowBattery($0) }
        enqueue(outcome.warnings.compactMap(AccessoryNoticeContent.lowBattery))
    }

    private func connectionsChanged(_ source: AccessoryConnections.Source, _ devices: [String: AccessoryDevice],
                                    isBaseline: Bool, generation: Int) {
        guard isActive, generation == self.generation else { return }
        guard !isBaseline else {
            connections.baseline(source, devices)
            return
        }
        let change = connections.update(source, devices)
        change.disconnected.forEach { queue.drop(address: $0) }
        enqueue(change.connected.map { device in
            .connected(device, kind: .resolve(name: device.name, reported: reportedTypes[device.address], hint: device.hint))
        })
    }

    // MARK: Presenting

    private func enqueue(_ notices: [AccessoryNoticeContent]) {
        guard !notices.isEmpty else { return }
        let now = Date()
        notices.forEach { queue.enqueue($0, at: now) }
        guard presenter == nil else { return }
        presenter = Task { [weak self] in
            while !Task.isCancelled, self?.presentNext() == true {
                try? await Task.sleep(for: .seconds(AccessoryNoticeQueue.interval))
            }
            guard !Task.isCancelled else { return }
            self?.presenter = nil
        }
    }

    /// Shows the next waiting notice unless the island is open or the slot is busy with something
    /// more important; the notice then waits for the next turn. Returns whether to look again in
    /// 4.1 s: something was just shown, or something is still waiting.
    private func presentNext() -> Bool {
        guard let content = queue.next(at: Date()) else { return false }
        if !environment.isOpen, environment.notices.post(Self.islandNotice(content)) { queue.removeNext() }
        return true
    }

    /// The drawn width of notice text, as the island's notice layout measures it.
    static func textWidth(_ text: String) -> CGFloat { IslandTextMetrics.width(text) }

    /// The island notice for an accessory notice. The name is fitted to its wing here, shortened in
    /// the middle, so the drawn notice never outgrows 160 pt while VoiceOver still reads it whole.
    static func islandNotice(_ content: AccessoryNoticeContent) -> IslandNotice {
        let detail = AccessoryNoticeLayout.middleTruncated(content.detail, width: AccessoryNoticeLayout.nameWidth, measure: textWidth)
        return IslandNotice(kind: .accessory,
                            style: .text(symbol: content.symbol, image: nil, title: content.title, detail: detail,
                                         cameraGap: AccessoryNoticeLayout.cameraGap, maxWing: content.maxWing, meter: content.meter),
                            label: content.label, destination: .system)
    }
}
