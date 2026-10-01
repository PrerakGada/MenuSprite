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
    /// The last sprite an agent saved through the socket, so an open studio holding an older copy can
    /// reload it instead of saving that copy over the agent's change on its next edit.
    @Published private(set) var lastAgentChange: AgentChange?
    struct AgentChange: Equatable { let id: UUID; let revision: Int }
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
    /// What agents' previews need while they draw, by request: readings sampled every second and commands
    /// kept running, so nothing a render waits for is pruned before the picture is taken. Each render
    /// withdraws its own entry when it finishes; empty at rest.
    private var agentDemand: [UUID: (metrics: Set<String>, commands: Set<CommandSource>)] = [:]
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
    /// Commands behind sprite variables; they run only while a sprite or the studio needs them.
    let commands = CommandVariableRunner()
    /// The design open in the studio, sampled while it is shown even if unsaved.
    private var previewDesign: SpriteDesign?
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
        commands.changed = { [weak self] in self?.objectWillChange.send(); self?.changed?() }
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
    /// Samples what the studio's draft shows and compares, including its commands; nil stops it.
    func preview(design: SpriteDesign?) {
        previewDesign = design
        editorIDs = Set((design?.displayedReadingIDs ?? []) + (design?.ruleOnlyReadingIDs ?? []) + (design?.boardReadingIDs ?? []))
        schedule()
    }
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
    /// Whether a sprite's board is open in the menu bar right now.
    func isBoardOpen(_ id: UUID) -> Bool { boards.contains(id) }
    /// An agent's render registers what it draws under its own token; empty sets withdraw it. Scheduled at
    /// once, so the first sample and the first command runs start without the usual debounce.
    func setAgentDemand(_ owner: UUID, metrics: Set<String>, commands: Set<CommandSource>) {
        let had = agentDemand[owner] != nil
        agentDemand[owner] = metrics.isEmpty && commands.isEmpty ? nil : (metrics, Set(commands.map(\.normalized)))
        if had || agentDemand[owner] != nil { schedule(immediate: true) }
    }
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
        if let design = config.design { return designText(design) }
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

    // MARK: Gallery

    /// Saved sprites made from `templateID`.
    func sprites(from templateID: String) -> [SpriteConfiguration] { sprites.filter { $0.templateID == templateID } }
    /// Adds a sprite made from `template` to the end of the menu bar and returns it.
    @discardableResult
    func add(_ template: SpriteTemplate) -> SpriteConfiguration {
        let config = template.make(metric: knownMetric)
        save(config)
        return config
    }
    /// Adds every template in `set` that is not already in the menu bar; returns how many were added.
    @discardableResult
    func add(_ set: SpriteTemplateSet) -> Int {
        let missing = set.templateIDs.filter { sprites(from: $0).isEmpty }.compactMap(SpriteTemplates.template)
        for template in missing { add(template) }
        notice = missing.isEmpty ? "Every sprite in \(set.name) is already in your menu bar."
            : "Added \(missing.count) sprite\(missing.count == 1 ? "" : "s") from \(set.name)."
        return missing.count
    }
    /// Saves `value` and returns it as stored (normalized, design pruned).
    @discardableResult
    func save(_ value: SpriteConfiguration) -> SpriteConfiguration {
        var config = value
        if Self.migratesDesignsOnLoad, config.design == nil { config.design = SpriteDesign.migrated(from: config, metric: knownMetric) }
        config.normalize()
        if let index = sprites.firstIndex(where: { $0.id == config.id }) { sprites[index] = config }
        else { sprites.append(config) }
        persist(); changed?(); schedule()
        return config
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
    /// Puts these sprites in this order within the places they already hold; every other sprite keeps
    /// its place. The left strip's drag uses it, so the list shows the strip's order.
    func reorder(_ ids: [UUID]) {
        let slots = sprites.indices.filter { ids.contains(sprites[$0].id) }
        let byID = Dictionary(sprites.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard slots.count == ids.count, Set(ids).count == ids.count else { return }
        for (slot, id) in zip(slots, ids) { if let sprite = byID[id] { sprites[slot] = sprite } }
        persist(); changed?()
    }
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
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            sprites = SpriteConfiguration.initial; migrateDesigns(backup: false); persist(); return
        }
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
            migrateDesigns(backup: true)
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
            if let design = config.design { ids += design.ruleOnlyReadingIDs }
            for id in ids { result[id] = min(result[id] ?? 60, config.interval) }
        }
        if libraryOpen {
            for id in Set(visibleCounts.keys).union(editorIDs) { result[id] = min(result[id] ?? 60, 2) }
        }
        for id in hubMetrics { result[id] = min(result[id] ?? 60, hubInterval) }
        for entry in surfaceMetrics.values {
            for id in entry.ids { result[id] = min(result[id] ?? 60, entry.interval) }
        }
        // A render waits for two samples; at one a second that is about two seconds.
        for entry in agentDemand.values {
            for id in entry.metrics { result[id] = min(result[id] ?? 60, 1) }
        }
        for id in boards {
            guard let config = sprites.first(where: { $0.id == id }), config.enabled else { continue }
            var ids = config.processPanelKind?.metricIDs ?? config.metricIDs
            // A custom board samples what its blocks show instead of the classic panel's readings.
            if let design = config.design, let board = design.board {
                ids = config.metricIDs + design.ruleOnlyReadingIDs + design.boardReadingIDs
                if board.root.flattened.contains(where: { $0.kind == .energy }) { ids += ProcessPanelKind.power.metricIDs }
            }
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
        let wantedCommands = suspended ? (all: [], previews: []) : commandDemandParts()
        commands.setDemand(wantedCommands.all, previews: wantedCommands.previews)
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
                if force { self.aiLastForced = Date(); await usage.restartAutoPacing() }
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

// MARK: - Designs

extension MonitoringStore {
    /// Gives every sprite saved before the studio a design that draws what it drew. The file is copied
    /// aside once first, and the old settings stay in it, so an older build still reads it.
    /// Sprites saved before the studio are converted on load (the settings stay, for older builds).
    static let migratesDesignsOnLoad = true

    fileprivate func migrateDesigns(backup: Bool) {
        guard Self.migratesDesignsOnLoad, sprites.contains(where: { $0.design == nil }) else { return }
        if backup, FileManager.default.fileExists(atPath: configurationURL.path) {
            let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.omitted)) + "-\(Int(Date().timeIntervalSince1970) % 100_000)"
            let copy = configurationURL.deletingLastPathComponent().appendingPathComponent("monitoring.before-sprite-studio-\(stamp).json")
            try? FileManager.default.copyItem(at: configurationURL, to: copy)
        }
        sprites = sprites.map { config in
            guard config.design == nil else { return config }
            var value = config
            value.design = SpriteDesign.migrated(from: config, metric: { [weak self] id in self?.knownMetric(id) })
            value.normalize()
            return value
        }
        persist()
    }

    /// A catalog entry, or nil for a reading this Mac has not reported (the migration then keeps the id).
    func knownMetric(_ id: String) -> Metric? { catalog.first { $0.id == id } }

    /// Every command a running sprite, an open board, the studio's draft or an agent's render needs.
    ///
    /// An enabled sprite's command value runs all the time only when its face or a rule reads it, or it is
    /// marked `background`; a value only the board shows runs while that board is open, as script rows and
    /// script blocks always have. A sprite of board-only values therefore costs nothing until it is clicked.
    func commandDemand() -> Set<CommandSource> { commandDemandParts().all }

    /// The same, and which of those only an agent's render wants: their first run is a `preview`.
    private func commandDemandParts() -> (all: Set<CommandSource>, previews: Set<CommandSource>) {
        var result = Set(sprites.filter(\.enabled).flatMap { $0.design.map(Self.continuousCommands) ?? [] })
        if let previewDesign {
            result.formUnion(previewDesign.commandVariables.compactMap(\.command))
            result.formUnion(previewDesign.boardScriptCommands)
        }
        for id in boards {
            guard let config = sprites.first(where: { $0.id == id }), config.enabled, let design = config.design else { continue }
            result.formUnion(design.commandVariables.compactMap(\.command))
            result.formUnion(design.boardScriptCommands)
        }
        let agents = agentDemand.values.reduce(into: Set<CommandSource>()) { $0.formUnion($1.commands) }
        return (result.union(agents), agents.subtracting(result.map(\.normalized)))
    }

    /// The command values a sprite needs while its board is closed: those its face or its rules read
    /// (a rule may restyle the face at any moment), and those marked `background` (a chart's history).
    static func continuousCommands(_ design: SpriteDesign) -> [CommandSource] {
        let used = Set(design.root.flattened.flatMap(\.referencedVariables) + design.rules.flatMap(\.referencedVariables))
        return design.commandVariables.compactMap { variable in
            guard let command = variable.command, used.contains(variable.id) || command.background else { return nil }
            return command
        }
    }

    // MARK: Agents

    enum SpriteMatch {
        case one(SpriteConfiguration)
        case several([SpriteConfiguration])
        case noMatch
    }

    /// The sprite an agent means: an exact id, then a name (case-insensitive), then an id prefix of at least
    /// four characters. A name is tried before a prefix so a sprite called "beef" is not lost to an id.
    func sprite(matching reference: String) -> SpriteMatch {
        let wanted = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return .noMatch }
        if let id = UUID(uuidString: wanted), let found = sprites.first(where: { $0.id == id }) { return .one(found) }
        let named = sprites.filter { $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if named.count == 1 { return .one(named[0]) }
        if named.count > 1 { return .several(named) }
        guard wanted.count >= 4 else { return .noMatch }
        let prefix = wanted.lowercased()
        let prefixed = sprites.filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }
        switch prefixed.count {
        case 0: return .noMatch
        case 1: return .one(prefixed[0])
        default: return .several(prefixed)
        }
    }

    /// Lets an agent's change land in an open studio: a studio holding this sprite would otherwise save its
    /// own older copy over it on the next edit. Observers reload from `sprites`.
    func agentSaved(_ config: SpriteConfiguration) { agentChanged(config.id) }
    /// The same after an agent switched, hid or removed a sprite: an open studio adopts the stored copy, or
    /// closes without saving when the sprite is gone, so it never writes back what the agent changed.
    func agentChanged(_ id: UUID) {
        if editingSprite?.id == id { editingSprite = sprites.first { $0.id == id } }
        lastAgentChange = AgentChange(id: id, revision: (lastAgentChange?.revision ?? 0) + 1)
    }

    /// Runs every command a design draws from again now (its values, board-only ones included, script rows and
    /// script blocks), side by side, one process per shared command, and returns when all have finished: after a
    /// board action changed something, a Refresh button, or `menusprite refresh`. Commands see
    /// `MENUSPRITE_TRIGGER=refresh` (or `trigger`). A run already going is waited for and followed by one more, so
    /// the values see what was just changed; two commands never overlap themselves.
    func rerun(_ design: SpriteDesign, trigger: CommandTrigger = .refresh) async {
        await commands.run(design.commandVariables.compactMap(\.command) + design.boardScriptCommands, trigger: trigger)
    }

    /// The live values a design draws from, captured now.
    ///
    /// `overrides` (an agent's preview only) are stand-ins by value id: what the reading or command would have
    /// produced, formatted, compared and drawn exactly as the live value would be (a reading's unit, a command's
    /// decimals and suffix, `clock`). A `pace` (also accepted under "id.pace") replaces a limit's pace alone.
    /// Empty overrides draw the live values.
    func designValues(_ design: SpriteDesign, overrides: [String: ValueOverride] = [:]) -> DesignValues {
        var metrics: [String: Metric] = [:]
        var paces: [String: String] = [:]
        var results: [String: CommandResult] = [:]
        for variable in design.variables {
            if let id = variable.readingID {
                metrics[id] = metric(id)
                if metric(id).group == .ai {
                    paces[id] = switch usagePace(id)?.level {
                    case .onTrack: "on track"; case .ahead: "ahead"; case .over: "over"; case nil: ""
                    }
                }
            }
            if let command = variable.command, let result = commands.result(for: command) { results[variable.id] = result }
        }
        var standIns: [String: Reading] = [:], standInNumbers: [String: Double] = [:], pacedIDs: [String: String] = [:]
        for (key, override) in overrides {
            if key.hasSuffix(".pace"), let pace = override.pace ?? override.text { pacedIDs[String(key.dropLast(5))] = pace; continue }
            if let pace = override.pace { pacedIDs[key] = pace }
            guard override.text != nil || override.number != nil || override.missing, let variable = design.variable(key) else { continue }
            if override.missing {
                switch variable.source {
                case .reading: standIns[key] = Reading(unavailable: "Stood in as missing")
                case .command: results[key] = CommandResult(output: "", errorOutput: "", status: 1, problem: "Stood in as missing",
                                                            elapsed: 0, finishedAt: Date())
                case .constant: break
                }
                continue
            }
            let number = override.number ?? override.text.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            switch variable.source {
            case .reading:
                standIns[key] = override.text.map { Reading(text: $0) } ?? Reading(number ?? 0)
                if let number { standInNumbers[key] = number }
            case .command:
                results[key] = CommandResult(text: override.text, number: number, output: override.text ?? number.map { $0 == $0.rounded() && abs($0) < 1e15 ? String(Int($0)) : String($0) } ?? "",
                                             errorOutput: "", status: 0, elapsed: 0, finishedAt: Date())
            case .constant:
                standIns[key] = override.text.map { Reading(text: $0) } ?? Reading(number ?? 0)
                if let number { standInNumbers[key] = number }
            }
        }
        let live = self.readings
        let metrics_ = metrics, paces_ = paces, results_ = results, standIns_ = standIns, standInNumbers_ = standInNumbers, paced = pacedIDs
        @Sendable func reading(_ variable: SpriteVariable) -> Reading? {
            standIns_[variable.id] ?? variable.readingID.flatMap { live[$0] }
        }
        @Sendable func config(_ format: ValueFormat) -> SpriteConfiguration {
            var config = SpriteConfiguration(metricIDs: [])
            config.showUnits = format.showUnit; config.decimals = format.decimals
            config.fahrenheit = format.fahrenheit; config.networkBits = format.bits
            return config
        }
        @Sendable func number(_ variable: SpriteVariable) -> Double? {
            if standIns_[variable.id] != nil { return standInNumbers_[variable.id] }
            switch variable.source {
            case .reading(let id): return live[id]?.number
            case .command: return results_[variable.id].flatMap { $0.available ? $0.number : nil }
            case .constant(let text): return Double(text)
            }
        }
        @Sendable func digits(_ value: Double, _ format: ValueFormat) -> String {
            String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), format.decimals, value)
        }
        return DesignValues(
            formatted: { variable in
                switch variable.source {
                case .reading(let id):
                    guard let metric = metrics_[id] else { return "—" }
                    let value = reading(variable)
                    // A duration read as the moment it runs out: when a limit resets, when the battery empties.
                    if variable.format.clock, metric.unit == .seconds, let value, value.text == nil, let seconds = value.number {
                        return ValueFormat.clockTime(value.measuredAt.addingTimeInterval(seconds))
                    }
                    return MetricFormat.string(value, metric: metric, config: config(variable.format), compact: true)
                case .command:
                    guard let result = results_[variable.id], result.available else { return "—" }
                    // A command's number of seconds counts from when it finished.
                    if variable.format.clock, let seconds = result.number {
                        return ValueFormat.clockTime(result.finishedAt.addingTimeInterval(seconds)) + variable.format.suffix
                    }
                    if let text = result.text { return text + variable.format.suffix }
                    return digits(result.number ?? 0, variable.format) + variable.format.suffix
                case .constant(let text):
                    guard let standIn = standIns_[variable.id] else { return text }
                    return standIn.text ?? standIn.number.map { digits($0, variable.format) } ?? text
                }
            },
            number: number,
            text: { variable in
                switch variable.source {
                case .reading: reading(variable)?.text
                case .command: results_[variable.id].flatMap { $0.available ? $0.text : nil }
                case .constant(let text): standIns_[variable.id].map(\.text) ?? text
                }
            },
            aspect: { variable, aspect in
                guard aspect == .pace else { return nil }
                if let pace = paced[variable.id] { return pace }
                guard let id = variable.readingID else { return nil }
                return paces_[id]
            },
            widthTemplates: { variable in
                // A clock time's width cannot be predicted (weekday and month names vary), and it changes rarely.
                guard let id = variable.readingID, let metric = metrics_[id], !(variable.format.clock && metric.unit == .seconds) else { return [] }
                return MetricFormat.widthTemplates(metric: metric, config: config(variable.format))
            })
    }

    /// The design's visible text, for accessibility and one-line summaries.
    func designText(_ design: SpriteDesign) -> String {
        let values = designValues(design)
        let overrides = SpriteRules.evaluate(design, values: values)
        func walk(_ node: DesignNode) -> [String] {
            if overrides[node.id]?.hidden ?? node.style.hidden { return [] }
            if node.kind == .text {
                return [(overrides[node.id]?.text ?? node.segments).map { segment in
                    switch segment {
                    case .literal(let text): text
                    case .value(let id): design.variable(id).map(values.formatted) ?? "?"
                    }
                }.joined()]
            }
            if node.kind == .battery, let variable = node.variable.flatMap(design.variable) { return [values.formatted(variable)] }
            return node.children.flatMap(walk)
        }
        return walk(design.root).joined(separator: " ")
    }

    /// The menu-bar drawing of `config`, with its battery glyph when it has one.
    func renderDesign(_ config: SpriteConfiguration, design: SpriteDesign? = nil, height: CGFloat = NSStatusBar.system.thickness,
                      reserved: [String: CGFloat] = [:], ceiling: Int? = nil) -> DesignRenderer.Output? {
        guard let design = design ?? config.design else { return nil }
        var glyph: BatteryGlyph?
        if design.root.flattened.contains(where: { $0.kind == .battery }) {
            glyph = batteryGlyph(ceiling: ceiling)
            glyph?.percentInside = config.enabled
        }
        return DesignRenderer.render(design, values: designValues(design), height: height, reserved: reserved, battery: glyph)
    }
}

extension MonitoringStore {
    /// Off-screen renders only: readings the harness cannot sample (AI limits need the network).
    func injectReadingsForValidation(_ values: [String: Reading]) { readings.merge(values) { _, new in new } }
}
