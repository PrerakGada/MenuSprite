import Foundation
import AppKit
import SystemMonitoring
import AIAccounts

@MainActor
final class MonitoringStore: ObservableObject {
    @Published private(set) var catalog = MonitoringCatalog.base
    @Published private(set) var readings: [String: Reading] = [:]
    @Published private(set) var history: [String: [HistoryPoint]] = [:]
    @Published private(set) var sprites: [SpriteConfiguration] = []
    @Published private(set) var isSampling = false
    @Published private(set) var discoveringSensors = false
    @Published private(set) var lastSample: Date?
    @Published private(set) var sampleCount = 0
    @Published var notice: String?
    @Published var editingSprite: SpriteConfiguration?
    @Published var isShowingEditor = false
    private(set) var libraryOpen = false
    private(set) var suspended = false
    private var visibleCounts: [String: Int] = [:]
    private var editorIDs: Set<String> = []
    private var boards: Set<UUID> = []
    /// Readings the hub panel's visible tab needs. The hub has no sprite of its own, so its
    /// demand is tracked separately and cleared when the panel closes or switches tabs.
    private var hubMetrics: Set<String> = []
    private var hubInterval: Double = 2
    private var surfaceMetrics: [String: (ids: Set<String>, interval: Double)] = [:]
    private(set) var energyHistoryBreaks: [String: [Date]] = [:]
    private let sampler = SystemSampler()
    private let usage: any UsageFetching
    /// Estimated spend is reconstructed from local logs, so it is a separate source from the usage
    /// endpoints and survives their failures.
    private let spend: (any SpendEstimating)?
    private let configurationURL: URL
    private var task: Task<Void, Never>?
    private var aiTask: Task<Void, Never>?
    private var planTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var generation = 0
    private var removedSprite: SpriteConfiguration?
    private var aiForcePending = false
    private var aiLastForced: Date?
    private var aiLastCheck: Date?
    private var aiCheckedIDs: Set<String> = []
    private var aiSnapshots: [AIProvider: UsageSnapshot] = [:]
    var changed: (() -> Void)?

    /// Claude Code re-reads its keychain login on a 30-second cache, so checking the live login more
    /// often cannot notice a switch any sooner.
    static let aiCheckInterval: Double = 30
    /// Refresh also runs on window activation; the usage endpoints rate-limit repeated fetches.
    static let aiForceFloor: TimeInterval = 60

    /// Version 2 seeded the battery item once. The marker lives in the saved file rather than
    /// in preferences, so deleting the item keeps it deleted and a test store stays self-contained.
    private struct Saved: Codable { var version = 2; var sprites: [SpriteConfiguration]; var cachedMetrics: [Metric]? = nil }
    static let currentConfigurationVersion = 2

    init(configurationURL: URL? = nil, usage: any UsageFetching = UsageService.shared,
         spend: (any SpendEstimating)? = nil) {
        self.usage = usage
        self.spend = spend
        self.configurationURL = configurationURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuSprite", isDirectory: true).appendingPathComponent("monitoring.json")
        let coreCount = ProcessInfo.processInfo.processorCount
        for index in 0..<coreCount {
            catalog.append(Metric("cpu.core.\(index)", "CPU core \(index + 1) usage", "Core \(index + 1)", .cpu, .percent,
                "Logical core index from Mach. Performance/efficiency identity is not inferred from its position.", source: "host_processor_info core \(index)", advanced: true))
        }
        load()
    }
    func start() { schedule() }
    func stop() {
        generation += 1; task?.cancel(); task = nil; aiTask?.cancel(); aiTask = nil; planTask?.cancel(); planTask = nil
        discoveryTask?.cancel(); discoveryTask = nil; isSampling = false
        Task { await sampler.idle() }
    }
    func setLibraryOpen(_ open: Bool) {
        libraryOpen = open
        if open { discoverSensors() }
        else { visibleCounts = [:]; editorIDs = [] }
        schedule()
    }
    func visible(_ id: String, _ visible: Bool) {
        guard libraryOpen else { return }
        let count = max(0, (visibleCounts[id] ?? 0) + (visible ? 1 : -1))
        if count == 0 { visibleCounts[id] = nil } else { visibleCounts[id] = count }
        schedule()
    }
    func preview(_ ids: [String]) { editorIDs = Set(ids); schedule() }
    func openBoard(_ id: UUID) { boards.insert(id); schedule() }
    /// The hub samples only what its visible tab shows; an empty set stops that demand entirely.
    func setHubMetrics(_ ids: Set<String>, interval: Double = 2) {
        guard ids != hubMetrics || interval != hubInterval else { return }
        hubMetrics = ids; hubInterval = interval; schedule()
    }
    /// Other surfaces (Dynamic Island pages, its settings preview) register what they show under their
    /// own name, the same way the hub does; an empty set withdraws that surface's demand.
    func setSurfaceMetrics(_ owner: String, _ ids: Set<String>, interval: Double = 2) {
        let current = surfaceMetrics[owner]
        guard current?.ids != ids || current?.interval != interval else { return }
        surfaceMetrics[owner] = ids.isEmpty ? nil : (ids, interval)
        if current != nil || !ids.isEmpty { schedule() }
    }
    func closeBoard(_ id: UUID) { boards.remove(id); schedule() }
    func suspend() {
        suspended = true; generation += 1; task?.cancel(); task = nil; aiTask?.cancel(); aiTask = nil; isSampling = false
        Task { await sampler.resetBaselines() }
    }
    func resume() { suspended = false; schedule() }
    /// Also refetches AI usage, bypassing its five-minute cache at most once a minute.
    func refresh() {
        if aiLastForced.map({ Date().timeIntervalSince($0) >= Self.aiForceFloor }) ?? true { aiForcePending = true }
        schedule(immediate: true)
    }

    func metric(_ id: String) -> Metric {
        let group: MetricGroup = id.hasPrefix("sensor.") ? .sensors : (id.hasPrefix("network.") ? .network : (id.hasPrefix(AIUsageMetrics.prefix) ? .ai : .system))
        return catalog.first { $0.id == id } ?? Metric(id, "Missing reading · \(id)", "Missing", group, .text,
            "The saved reading is not reported by the current device. Choose another reading or reconnect the device.", source: "Saved sprite reference")
    }
    func display(_ id: String, config: SpriteConfiguration = .init(), compact: Bool = false) -> String {
        MetricFormat.string(readings[id], metric: metric(id), config: config, compact: compact)
    }
    func menuText(_ config: SpriteConfiguration) -> String {
        guard config.enabled else { return "Paused" }
        return readoutColumns(config, ids: config.metricIDs).map { column in
            return config.showLabels ? "\(column.label) \(column.value)" : column.value
        }.joined(separator: "  ")
    }
    /// The text columns the menu bar draws. A charge drawn inside the battery glyph is not repeated.
    func menuColumns(_ config: SpriteConfiguration) -> [ReadoutColumn] {
        readoutColumns(config, ids: config.metricIDs.filter { !(config.drawsChargeInsideBattery && $0 == "battery.charge") })
    }
    private func readoutColumns(_ config: SpriteConfiguration, ids: [String]) -> [ReadoutColumn] {
        ids.map { id in
            let fallback = config.layout == .twoRows && id == "sensor.cpuTemperature" ? "TEMP" : metric(id).shortName
            let label = config.label(for: id, fallback: fallback)
            // The level bar needs a full scale, so only percentage readings become bars.
            let percent = config.layout == .bar && metric(id).unit == .percent ? readings[id]?.number : nil
            let ruleHex = menuColor(id, config: config)
            return ReadoutColumn(label: label, value: display(id, config: config, compact: true),
                                 colorHex: ruleHex ?? (config.enabled ? percent.flatMap(config.barHex) : nil),
                                 widthTemplates: MetricFormat.widthTemplates(metric: metric(id), config: config),
                                 level: percent.map { $0 / 100 })
        }
    }

    /// The last usage snapshot the AI readings were built from, nil until one was fetched. Read-only:
    /// surfaces that show limits register demand for an `ai.` reading and read the windows here.
    func usageSnapshot(_ provider: AIProvider) -> UsageSnapshot? { aiSnapshots[provider] }

    func usagePace(_ id: String, now: Date = Date()) -> UsagePace? {
        guard let provider = AIUsageMetrics.provider(for: id), let snapshot = aiSnapshots[provider],
              snapshot.notice == nil,
              let window = snapshot.window(String(id.dropFirst("ai.\(provider.rawValue).".count))) else { return nil }
        return UsagePace.evaluate(window, now: now)
    }

    private func menuColor(_ id: String, config: SpriteConfiguration) -> String? {
        if config.enabled, config.colorRule == .networkDirection {
            switch id { case "network.upload": return "FF9F0A"; case "network.download": return "30D158"; default: return nil }
        }
        if config.enabled, config.colorRule == .memoryPressure {
            return id.hasPrefix("memory.") ? SpriteColorRule.memoryPressureHex(readings["memory.pressure"]?.text) : nil
        }
        if config.enabled, config.colorRule == .powerDraw {
            return metric(id).unit == .watts ? SpriteColorRule.powerDrawHex(readings[id]?.number) : nil
        }
        guard config.enabled, config.colorRule.usesUsagePace,
              metric(id).group == .ai, metric(id).unit == .percent else { return nil }
        switch usagePace(id)?.level {
        case .onTrack: return "34C759"
        case .ahead: return "FFCC00"
        case .over: return "FF453A"
        case nil: return "A0A0A0"
        }
    }

    func newSprite(metricID: String? = nil) {
        let definition = metricID.map(metric)
        let symbol = definition.map { $0.unit == .rpm ? "fan" : ($0.unit == .watts ? "bolt" : $0.group.icon) } ?? "cpu"
        editingSprite = SpriteConfiguration(name: definition?.name ?? "My sprite", symbol: symbol,
                                             metricIDs: metricID.map { [$0] } ?? [])
        isShowingEditor = true
    }
    func edit(_ config: SpriteConfiguration) { editingSprite = config; isShowingEditor = true }
    func save(_ value: SpriteConfiguration) {
        var config = value; config.normalize()
        if let index = sprites.firstIndex(where: { $0.id == config.id }) { sprites[index] = config }
        else { sprites.append(config) }
        persist(); changed?(); schedule()
    }
    func setEnabled(_ id: UUID, _ value: Bool) {
        guard let index = sprites.firstIndex(where: { $0.id == id }) else { return }
        sprites[index].enabled = value; persist(); changed?(); schedule()
    }
    func setMenuBar(_ id: UUID, _ value: Bool) {
        guard let index = sprites.firstIndex(where: { $0.id == id }) else { return }
        sprites[index].showInMenuBar = value; persist(); changed?(); schedule()
    }
    func add(_ metricID: String, to id: UUID) {
        guard let index = sprites.firstIndex(where: { $0.id == id }) else { return }
        guard !sprites[index].metricIDs.contains(metricID) else { return }
        guard sprites[index].metricIDs.count < 8 else { notice = "A sprite holds up to eight readings. Create another sprite for more."; return }
        sprites[index].metricIDs.append(metricID); persist(); changed?(); schedule()
    }
    func remove(_ id: UUID) {
        removedSprite = sprites.first { $0.id == id }
        sprites.removeAll { $0.id == id }
        notice = "Removed \(removedSprite?.name ?? "sprite")."
        persist(); changed?(); schedule()
    }
    var canUndoRemove: Bool { removedSprite != nil }
    func undoRemove() { if let value = removedSprite { removedSprite = nil; save(value); notice = nil } }
    func move(_ id: UUID, offset: Int) {
        guard let index = sprites.firstIndex(where: { $0.id == id }), sprites.indices.contains(index + offset) else { return }
        sprites.swapAt(index, index + offset); persist(); changed?()
    }
    func replaceForValidation(_ values: [SpriteConfiguration]) { sprites = values; persist(); changed?(); schedule(immediate: true) }
    func sampleAllForValidation() async -> SampleBatch {
        let localIDs = Set(catalog.map(\.id).filter { !$0.hasPrefix(AIUsageMetrics.prefix) })
        let result = await sampler.sample(ids: localIDs, groups: Set(MetricGroup.allCases).subtracting([.ai]))
        readings.merge(result.readings) { _, new in new }; mergeCatalog(result.discovered)
        return result
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else { sprites = SpriteConfiguration.initial; persist(); return }
        do {
            let data = try Data(contentsOf: configurationURL)
            let saved = try JSONDecoder().decode(Saved.self, from: data)
            guard (1...Self.currentConfigurationVersion).contains(saved.version) else { throw CocoaError(.fileReadCorruptFile) }
            mergeCatalog(saved.cachedMetrics ?? [])
            var ids: Set<UUID> = []
            sprites = saved.sprites.filter { ids.insert($0.id).inserted }.map { config in var value = config; value.normalize(); return value }
            if saved.version < 2 {
                if !sprites.contains(where: \.isBatteryItem) { sprites.append(.battery) }
                persist()
            }
        } catch {
            // Preserve the original bytes before allowing an edit to replace corrupt state.
            let backup = configurationURL.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            do {
                try FileManager.default.copyItem(at: configurationURL, to: backup)
                notice = "Could not read the saved sprites. The original file was preserved as \(backup.lastPathComponent)."
            } catch { notice = "Could not read or back up saved sprites. Changes will not be saved until the configuration file is repaired."; savingBlocked = true }
            sprites = []
        }
    }
    /// The battery drawn in the menu bar, from the same readings the boards use.
    /// An unread charge draws an empty shell; nothing is estimated.
    /// The glyph for a battery item, carrying its charge inside when the sprite asks for that.
    func batteryGlyph(ceiling: Int?, for config: SpriteConfiguration) -> BatteryGlyph {
        var glyph = batteryGlyph(ceiling: ceiling)
        glyph.percentInside = config.enabled && config.drawsChargeInsideBattery
        return glyph
    }
    func batteryGlyph(ceiling: Int?) -> BatteryGlyph {
        let percent = readings["battery.charge"]?.number
        let state = readings["battery.state"]?.text
        let onBattery = state == "On battery"
        return BatteryGlyph(percent: percent,
                            charging: state == "Charging",
                            ceiling: ceiling,
                            alertHex: onBattery && (percent ?? 100) <= 10 ? "FF6B5E" : nil,
                            activity: BatteryActivity(state: state, amps: readings["battery.current"]?.number),
                            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    private var savingBlocked = false
    private func persist() {
        guard !savingBlocked else { return }
        do {
            try FileManager.default.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let referenced = Set(sprites.flatMap(\.metricIDs))
            try encoder.encode(Saved(sprites: sprites, cachedMetrics: catalog.filter { referenced.contains($0.id) })).write(to: configurationURL, options: .atomic)
        } catch { notice = "Could not save sprites: \(error.localizedDescription)" }
    }

    func discoverSensors() {
        guard discoveryTask == nil else { return }
        discoveringSensors = true
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            let result = await sampler.discoverSensors()
            let interfaces = await sampler.discoverInterfaces()
            guard !Task.isCancelled else { return }
            mergeCatalog(result.discovered)
            mergeCatalog(interfaces)
            readings.merge(result.readings) { _, new in new }
            if !result.sourceErrors.isEmpty { notice = result.sourceErrors.joined(separator: ". ") }
            discoveringSensors = false; discoveryTask = nil; changed?(); schedule()
        }
    }
    private func mergeCatalog(_ metrics: [Metric]) {
        let known = Set(catalog.map(\.id))
        let additions = metrics.filter { !known.contains($0.id) }
        if !additions.isEmpty { catalog += additions }
    }

    private func demand() -> [String: Double] {
        var result: [String: Double] = [:]
        for config in sprites where config.enabled {
            var ids = config.processPanelKind == .power ? config.metricIDs + ["battery.charge", "battery.temperature"] : config.metricIDs
            if config.colorRule == .memoryPressure { ids.append("memory.pressure") }
            for id in ids { result[id] = min(result[id] ?? 60, config.interval) }
        }
        if libraryOpen {
            for id in Set(visibleCounts.keys).union(editorIDs) { result[id] = min(result[id] ?? 60, 2) }
        }
        for id in hubMetrics { result[id] = min(result[id] ?? 60, hubInterval) }
        for entry in surfaceMetrics.values {
            for id in entry.ids { result[id] = min(result[id] ?? 60, entry.interval) }
        }
        for id in boards {
            guard let config = sprites.first(where: { $0.id == id }), config.enabled else { continue }
            let ids = config.processPanelKind?.metricIDs ?? config.metricIDs
            for metricID in ids { result[metricID] = min(result[metricID] ?? 60, config.interval) }
        }
        return result
    }
    var requestedMetricCount: Int { demand().count }
    var requestedHubMetricsForValidation: Set<String> { hubMetrics }
    var fastestInterval: Double? { demand().values.min() }

    private func schedule(immediate: Bool = false) {
        planTask?.cancel()
        planTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            self?.applySchedule()
        }
    }
    private func applySchedule() {
        generation += 1
        let currentGeneration = generation
        task?.cancel(); task = nil
        aiTask?.cancel(); aiTask = nil
        let requested = demand()
        guard !requested.isEmpty, !suspended else {
            isSampling = false; aiForcePending = false
            Task { await sampler.idle() }
            return
        }
        isSampling = true
        let aiRequested = requested.filter { $0.key.hasPrefix(AIUsageMetrics.prefix) }
        if aiRequested.isEmpty { aiForcePending = false }
        else { startAIUsage(ids: Set(aiRequested.keys), interval: aiRequested.values.min() ?? 60, generation: currentGeneration) }
        let localRequested = requested.filter { !$0.key.hasPrefix(AIUsageMetrics.prefix) }
        guard !localRequested.isEmpty else {
            Task { await sampler.idle() }
            return
        }
        var groups: [MetricGroup: Set<String>] = [:]
        var intervals: [MetricGroup: Double] = [:]
        for (id, interval) in localRequested {
            let group = metric(id).group
            groups[group, default: []].insert(id)
            intervals[group] = min(intervals[group] ?? 60, interval)
        }
        task = Task { [weak self] in
            guard let self else { return }
            await sampler.configure(active: Set(groups.keys))
            guard !Task.isCancelled, currentGeneration == generation else { return }
            var deadlines = Dictionary(uniqueKeysWithValues: groups.keys.map { ($0, 0.0) })
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                let due = Set(deadlines.filter { $0.value <= now }.map(\.key))
                if !due.isEmpty {
                    let ids = due.reduce(into: Set<String>()) { $0.formUnion(groups[$1] ?? []) }
                    let result = await sampler.sample(ids: ids, groups: due)
                    guard !Task.isCancelled, currentGeneration == generation else { return }
                    readings.merge(result.readings) { _, new in new }
                    if due.contains(.network) {
                        let currentInterfaces = Set(result.discovered.map(\.id))
                        let savedIDs = Set(sprites.flatMap(\.metricIDs))
                        let obsolete = Set(catalog.filter { $0.id.hasPrefix("network.if.") && !currentInterfaces.contains($0.id) && !savedIDs.contains($0.id) }.map(\.id))
                        if !obsolete.isEmpty {
                            catalog.removeAll { obsolete.contains($0.id) }
                            for id in obsolete { readings[id] = nil; history[id] = nil }
                        }
                    }
                    mergeCatalog(result.discovered)
                    for id in ids {
                        if let reading = result.readings[id], let value = reading.number {
                            var points = history[id] ?? []
                            points.append(.init(time: reading.measuredAt, value: value))
                            let capacity = ["sensor.PSTR", "battery.temperature", "battery.charge"].contains(id) ? 900 : 60
                            if points.count > capacity { points.removeFirst(points.count - capacity) }
                            history[id] = points
                        } else if ["sensor.PSTR", "battery.temperature", "battery.charge"].contains(id) {
                            var breaks = energyHistoryBreaks[id] ?? []
                            breaks.append(result.readings[id]?.measuredAt ?? Date())
                            if breaks.count > 900 { breaks.removeFirst(breaks.count - 900) }
                            energyHistoryBreaks[id] = breaks
                        }
                    }
                    lastSample = Date(); sampleCount += 1; changed?()
                    let end = ProcessInfo.processInfo.systemUptime
                    for group in due { deadlines[group] = end + (intervals[group] ?? 2) }
                }
                let wait = max(0.05, (deadlines.values.min() ?? now + 2) - ProcessInfo.processInfo.systemUptime)
                do { try await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
                catch { return }
            }
        }
    }

    /// AI usage lives on remote servers, so it runs apart from the local sampler: a slow response
    /// never delays CPU or memory readings. Each pass reads the live logins (cheap) and reuses the
    /// service's five-minute snapshot unless a login changed or Refresh asked for a new fetch.
    /// Sprite intervals shorter than the check interval only re-render these cached values.
    private func startAIUsage(ids: Set<String>, interval: Double, generation currentGeneration: Int) {
        let providers = AIProvider.allCases.filter { provider in ids.contains { AIUsageMetrics.provider(for: $0) == provider } }
        let period = max(Self.aiCheckInterval, interval)
        let usage = self.usage
        // Rescheduling (scrolling the library, toggling a sprite) must not turn into extra login checks.
        let firstWait = aiForcePending || !ids.isSubset(of: aiCheckedIDs)
            ? 0 : max(0, period - Date().timeIntervalSince(aiLastCheck ?? .distantPast))
        aiTask = Task { [weak self] in
            if firstWait > 0 {
                do { try await Task.sleep(for: .milliseconds(Int(firstWait * 1000))) } catch { return }
            }
            while !Task.isCancelled {
                guard let self, currentGeneration == self.generation else { return }
                let force = self.aiForcePending
                self.aiForcePending = false
                if force { self.aiLastForced = Date() }
                self.aiLastCheck = Date()
                self.aiCheckedIDs = ids
                let results = await withTaskGroup(of: (AIProvider, Result<UsageSnapshot, UsageError>).self) { group in
                    for provider in providers {
                        group.addTask { (provider, await usage.activeUsage(provider, force: force)) }
                    }
                    var collected: [(AIProvider, Result<UsageSnapshot, UsageError>)] = []
                    for await item in group { collected.append(item) }
                    return collected
                }
                // Scanning logs is local work on its own schedule; only ask for it when a spend
                // reading is actually on screen.
                var spending: [AIProvider: SpendSummary] = [:]
                if let source = self.spend, SpendPreference.isEnabled, ids.contains(where: { $0.contains(".spend") }) {
                    for provider in providers {
                        if let summary = await source.summary(provider, force: force) { spending[provider] = summary }
                    }
                }
                guard !Task.isCancelled, currentGeneration == self.generation else { return }
                self.applyAIResults(results, spend: spending, historyIDs: ids)
                do { try await Task.sleep(for: .milliseconds(Int(period * 1000))) } catch { return }
            }
        }
    }

    /// Readings for limits a provider reports beside its session and weekly windows — a model-scoped
    /// Sonnet or Opus allowance, say — so they can go in the menu bar like any other reading.
    private static func aiMetrics(for snapshot: UsageSnapshot) -> [Metric] {
        AIUsageMetrics.discoveredWindows(snapshot).map { discovered in
            Metric(discovered.id, "\(snapshot.provider.title) · \(discovered.label) limit used",
                   discovered.label, .ai, .percent,
                   "A model-scoped limit this account reports beside its session and weekly windows. It appears because the provider sent it, not because MenuSprite expected it.",
                   source: "\(snapshot.provider.title) usage endpoint · model-scoped limit")
        }
    }

    private func applyAIResults(_ results: [(AIProvider, Result<UsageSnapshot, UsageError>)],
                                spend: [AIProvider: SpendSummary] = [:], historyIDs: Set<String>) {
        let now = Date()
        var updated = false
        for (provider, result) in results {
            let snapshot = try? result.get()
            aiSnapshots[provider] = snapshot
            if let snapshot { mergeCatalog(Self.aiMetrics(for: snapshot)) }
            let fetchedAt = snapshot?.fetchedAt ?? now
            for (id, value) in AIUsageMetrics.values(for: provider, result: result, spend: spend[provider], now: now) {
                let reading: Reading
                switch value {
                case .percent(let number): reading = Reading(number, at: fetchedAt)
                case .count(let number), .currency(let number): reading = Reading(number, at: fetchedAt)
                case .seconds(let number): reading = Reading(number, at: now)
                case .text(let text): reading = Reading(text: text, at: fetchedAt)
                case .unavailable(let message):
                    // Keep the first time a problem was seen instead of republishing it every pass.
                    if readings[id]?.issue == message { continue }
                    reading = Reading(unavailable: message, at: now)
                }
                if readings[id] != reading { readings[id] = reading; updated = true }
                guard case .percent(let number) = value, historyIDs.contains(id) else { continue }
                var points = history[id] ?? []
                guard points.last?.time != fetchedAt else { continue }
                points.append(.init(time: fetchedAt, value: number))
                if points.count > 60 { points.removeFirst(points.count - 60) }
                history[id] = points
                updated = true
            }
        }
        // Reset anniversaries and cache notices can change the color even at the same percentage.
        if updated || !results.isEmpty { changed?() }
    }
}

extension SpriteConfiguration {
    var isMemoryBoard: Bool { !metricIDs.isEmpty && metricIDs.allSatisfy { $0.hasPrefix("memory.") } }
}
