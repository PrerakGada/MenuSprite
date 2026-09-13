import AppKit
import Combine
import SystemMonitoring

@MainActor
final class MemoryBoardStore: ObservableObject {
    @Published private(set) var snapshot: ProcessMemorySnapshot?
    @Published private(set) var loading = true
    @Published private(set) var ranked: [ProcessConsumerRate] = []
    @Published private(set) var hasInterval = false
    @Published private(set) var energyObserved = false
    let kind: ProcessPanelKind
    private var rates = ProcessActivityRates()
    init(kind: ProcessPanelKind = .memory) { self.kind = kind }
    var emptyMessage: String {
        if let error = snapshot?.error { return error }
        if kind != .memory && !hasInterval { return "Measuring the first interval…" }
        if kind == .power && !energyObserved { return "Per-app CPU energy is unavailable on this Mac." }
        return "No comparable process readings. Try Refresh."
    }
    var comparableCount: Int { ranked.reduce(0) { $0 + $1.processValues.count } }
    @Published private(set) var icons: [String: NSImage] = [:]
    private var task: Task<Void, Never>?
    private var generation = 0
    private(set) var sampleCount = 0
    private(set) var isRunning = false
    let interval: Double = 5

    func start() {
        guard task == nil else { return }
        generation += 1
        let expected = generation
        let sampler = ProcessMemorySampler()
        isRunning = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                let applications = NSWorkspace.shared.runningApplications.compactMap { app -> MemoryApplication? in
                    guard let url = app.bundleURL else { return nil }
                    return .init(pid: app.processIdentifier, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent, bundlePath: url.path)
                }
                let result = await sampler.sample(applications: applications)
                guard !Task.isCancelled, let self, self.generation == expected else { return }
                self.snapshot = result; self.loading = false; self.sampleCount += 1
                self.rates.update(result.consumers.flatMap(\.processes))
                self.ranked = self.rates.rank(result.consumers, by: self.kind)
                self.hasInterval = self.rates.hasInterval; self.energyObserved = self.rates.energyObserved
                self.loadIcons()
                do { try await Task.sleep(for: .seconds(self.kind != .memory && !self.hasInterval ? 1 : self.interval)) } catch { return }
            }
        }
    }
    private var iconConsumers: Set<String>?
    func setIconConsumers(_ ids: Set<String>?) {
        guard ids != iconConsumers else { return }
        iconConsumers = ids
        if isRunning { loadIcons() }
    }
    private func loadIcons() {
        var next: [String: NSImage] = [:]
        // Only the leading rows are shown; don't cache an icon for every process.
        for row in ranked.prefix(30).filter({ iconConsumers == nil || iconConsumers!.contains($0.id) }) {
            let consumer = row.consumer
            guard let path = consumer.presentation.iconBundlePath else { continue }
            if let existing = icons[path] { next[path] = existing }
            else {
                let icon: NSImage? = autoreleasepool {
                    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = context
                    NSWorkspace.shared.icon(forFile: path).draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
                    NSGraphicsContext.restoreGraphicsState()
                    bitmap.size = NSSize(width: 16, height: 16)
                    let result = NSImage(size: bitmap.size); result.addRepresentation(bitmap)
                    return result
                }
                if let icon { next[path] = icon }
            }
        }
        icons = next
    }
    func stop() {
        generation += 1; task?.cancel(); task = nil; isRunning = false
        snapshot = nil; icons = [:]; loading = true
        ranked = []; rates = ProcessActivityRates(); hasInterval = false; energyObserved = false
    }
    func refresh() { stop(); start() }
}

enum MemoryBoard {
    static let metricIDs = ["memory.usage", "memory.used", "memory.total", "memory.pressure", "memory.app", "memory.wired", "memory.compressed", "memory.cached", "memory.swapUsed"]
}

enum MemoryBoardFormat {
    static func bytes(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value >= 1_073_741_824 { return String(format: "%.2f GiB", value / 1_073_741_824) }
        if value >= 1_048_576 { return String(format: "%.1f MiB", value / 1_048_576) }
        return String(format: "%.0f KiB", value / 1024)
    }
}
