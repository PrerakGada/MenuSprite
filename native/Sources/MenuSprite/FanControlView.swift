import AppKit
import PowerControl
import SwiftUI
import SystemMonitoring

/// Live fan speeds for the fan controls, read straight from the SMC (reading needs no root), and only
/// while a view showing them is on screen.
@MainActor
final class FanMonitor: ObservableObject {
    @Published private(set) var fans: [FanState] = []
    private var hardware: BatteryHardware?
    private var timer: Timer?
    func start() {
        if hardware == nil { hardware = BatteryHardware() }
        read()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.read() } }
        timer?.tolerance = 0.5
    }
    func stop() { timer?.invalidate(); timer = nil; hardware = nil }
    private func read() { fans = hardware?.fans() ?? [] }
}

/// Automatic, 80%, 90%, Full blast or any speed in between, with each fan's live speed.
/// Everything is written by the power helper; macOS gets the fans back when MenuSprite quits or sleeps.
struct FanControlView: View {
    @ObservedObject var power: PowerStore
    @StateObject private var monitor = FanMonitor()
    @State private var custom: Double = 60
    @State private var dragging = false

    private var controllable: Bool { power.helperInstalled }
    private var lowest: Double { Double(FanPolicy.lowestPercent(monitor.fans)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            speeds
            HStack(spacing: 6) {
                choice("Automatic", .automatic)
                ForEach(FanTarget.presets, id: \.self) { percent in
                    choice(percent == 100 ? "Full blast" : "\(percent)%", .percent(percent))
                }
            }
            HStack(spacing: 8) {
                Text("Custom").font(.system(size: 12))
                    .foregroundStyle(isCustom ? Color.accentColor : .secondary)
                Slider(value: Binding(get: { custom }, set: { custom = $0.rounded() }), in: min(lowest, 99)...100) { editing in
                    dragging = editing
                    if !editing { power.setFans(.percent(Int(custom))) }
                }
                .controlSize(.small).disabled(!controllable)
                .accessibilityLabel("Custom fan speed").accessibilityIdentifier("fan-custom")
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(Int(custom))%").font(.system(size: 12, weight: .medium, design: .rounded))
                    if let fan = monitor.fans.first {
                        Text("\(Int(FanPolicy.rpm(percent: Int(custom), for: fan))) rpm").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .monospacedDigit().frame(width: 58, alignment: .trailing)
            }
            Text(power.fanStatus)
                .font(.system(size: 11)).foregroundStyle(statusIsWarning ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action = power.helperActionTitle, !power.helperInstalled || power.helperOutdated {
                Button(action) { power.enableHelper() }.controlSize(.small)
            }
        }
        .onAppear {
            monitor.start()
            if let percent = power.fanTarget.percent { custom = Double(percent) }
            if controllable { power.refreshBatteryStatus() }
        }
        .onDisappear { monitor.stop() }
        .onChange(of: power.fanTarget) { _, target in
            if let percent = target.percent, !dragging { custom = Double(percent) }
        }
    }

    private var speeds: some View {
        HStack(alignment: .top, spacing: 18) {
            if monitor.fans.isEmpty {
                Text("This Mac reports no fans.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(monitor.fans, id: \.index) { fan in
                VStack(alignment: .leading, spacing: 1) {
                    Text(monitor.fans.count == 1 ? "Fan" : "Fan \(fan.index + 1)").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("\(Int(fan.rpm.rounded())) rpm").font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("\(Int((fan.rpm / fan.maximum * 100).rounded()))% of \(Int(fan.maximum))")
                        .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var isCustom: Bool { power.fanTarget.percent.map { !FanTarget.presets.contains($0) } ?? false }
    private var statusIsWarning: Bool {
        power.fanControlReason != nil || power.fanStatus.hasPrefix("Not applied") || power.fanStatus.hasPrefix("The power helper")
    }

    private func choice(_ title: String, _ target: FanTarget) -> some View {
        let selected = power.fanTarget == target
        return Button { power.setFans(target) } label: {
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .medium))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).disabled(!controllable).opacity(controllable ? 1 : 0.5)
        .accessibilityIdentifier("fan-\(target.percent.map(String.init) ?? "auto")")
    }
}

/// What a click on a fan sprite opens: the fan controls, then the sprite's other readings as plain values.
struct FanBoard: View {
    @ObservedObject var store: MonitoringStore
    @ObservedObject var power: PowerStore
    let id: UUID
    let configure: () -> Void
    private var config: SpriteConfiguration? { store.sprites.first { $0.id == id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Fans", systemImage: "fan").font(.headline)
                Spacer()
                Button("Configure…", action: configure).controlSize(.small)
            }
            FanControlView(power: power)
            if let config {
                let others = config.metricIDs.filter { !SpriteConfiguration.isFanReading($0) }
                if !others.isEmpty {
                    Divider()
                    ForEach(others, id: \.self) { metricID in
                        HStack(alignment: .firstTextBaseline) {
                            Text(store.metric(metricID).name).font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Text(store.display(metricID, config: config)).font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                        }
                    }
                }
            }
        }
        .padding(16).frame(width: 360)
    }
}

extension SpriteConfiguration {
    /// Fan speed, or any one fan's actual/target/limit reading.
    static func isFanReading(_ id: String) -> Bool {
        if id == "sensor.fanSpeed" { return true }
        let key = id.dropFirst("sensor.".count)
        return id.hasPrefix("sensor.F") && key.count == 4 && key.dropFirst().first?.isNumber == true
            && ["Ac", "Tg", "Mn", "Mx"].contains(String(key.suffix(2)))
    }
    /// A sprite showing any fan reading opens the fan controls instead of the graphs.
    var opensFanBoard: Bool { metricIDs.contains(where: Self.isFanReading) }
}
