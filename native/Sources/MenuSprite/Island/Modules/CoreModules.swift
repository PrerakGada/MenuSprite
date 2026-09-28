import AppKit
import Combine
import IOKit.ps
import IslandKit
import SwiftUI
import SystemMonitoring

/// The Keep awake tile: toggles MenuSprite's own keep-awake session.
@MainActor
final class KeepAwakeModule: IslandFeature {
    let control: IslandControlModel
    private var observation: AnyCancellable?

    init(environment: IslandEnvironment) {
        let power = environment.power
        control = IslandControlModel(.keepAwake) { power.awake ? power.stopAwake() : power.startAwake() }
        observation = power.$awake.sink { [weak control] awake in
            control?.isOn = awake
            control?.symbol = awake ? "cup.and.saucer.fill" : "cup.and.saucer"
        }
        control.isOn = power.awake
        environment.register(control)
    }
}

/// The Open app panel tile: MenuSprite's hub, in the island or its own window per settings.
@MainActor
final class AppPanelModule: IslandFeature {
    init(environment: IslandEnvironment) {
        let control = IslandControlModel(.panel) { [weak environment] in environment?.actions.openAppPanel() }
        control.symbol = "bubble.middle.top"
        environment.register(control)
    }
}

/// Reads the internal battery from the power-sources API. No polling: the owner listens for the
/// power-sources notification.
struct IslandBatteryState: Equatable {
    var percent: Int
    var charging: Bool
    var external: Bool

    static func read() -> IslandBatteryState? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = info[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let percent = Int((Double(current) / Double(maximum) * 100).rounded())
            return IslandBatteryState(percent: percent, charging: info[kIOPSIsChargingKey] as? Bool ?? false,
                                      external: info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }

    /// The battery notice for a change from `old` to `self`, or nil when nothing worth saying changed:
    /// plugging in or out, crossing down to 20%, or charging stopping at 100%. A charge limiter
    /// holding the level (charging flipping while plugged in) says nothing.
    func notice(from old: IslandBatteryState) -> (title: String, symbol: String)? {
        let low = old.percent > 20 && percent <= 20
        let plug = old.external != external
        let full = old.charging && !charging && percent == 100 && external
        guard low || plug || full else { return nil }
        let symbol = external ? "battery.100percent.bolt" : "battery.25percent"
        if low { return ("Low battery", symbol) }
        if external && charging { return ("Charging", symbol) }
        if external && percent >= 100 { return ("Fully charged", symbol) }
        if external { return ("Plugged in", symbol) }
        return ("On battery", symbol)
    }
}

/// Battery at rest and the Battery notice. Installs the power-sources run-loop source only while
/// either is wanted, and only on a Mac with an internal battery.
@MainActor
final class BatteryModule: ObservableObject, IslandFeature {
    @Published private(set) var state: IslandBatteryState?
    private unowned let environment: IslandEnvironment
    private var source: CFRunLoopSource?
    private var settingsObservation: AnyCancellable?

    init(environment: IslandEnvironment) {
        self.environment = environment
        environment.register(rest: .battery, IslandRestProvider { [weak self] in
            guard let self, SystemCard.hasBattery else { return nil }
            return (AnyView(BatteryRestLeft(module: self)), AnyView(BatteryRestRight(module: self)))
        })
        environment.register(indicator: .battery) {
            SystemCard.hasBattery ? .available : .unavailable("This Mac has no battery.")
        }
    }

    private var wanted: Bool {
        let settings = environment.settings
        return SystemCard.hasBattery && (settings.atRest == .battery || settings.indicators.contains(.battery))
    }

    func islandDidStart() {
        settingsObservation = environment.settingsStore.$value
            .map { ($0.atRest == .battery, $0.indicators.contains(.battery)) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] _ in Task { @MainActor in self?.sync() } }
        sync()
    }

    func islandDidStop() {
        settingsObservation = nil
        stopObserving()
    }

    private func sync() {
        if wanted { startObserving() } else { stopObserving() }
    }

    private func startObserving() {
        guard source == nil else { return }
        state = IslandBatteryState.read()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let loop = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let module = Unmanaged<BatteryModule>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { module.powerChanged() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), loop, .defaultMode)
        source = loop
    }

    private func stopObserving() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
    }

    private func powerChanged() {
        guard let new = IslandBatteryState.read() else { return }
        let old = state
        state = new
        guard let old, environment.settings.indicators.contains(.battery), let notice = new.notice(from: old) else { return }
        environment.notices.post(IslandNotice(kind: .battery,
                                              style: .text(symbol: notice.symbol, image: nil, title: notice.title,
                                                           detail: "\(new.percent)%", cameraGap: 16, maxWing: 240),
                                              label: "\(notice.title), \(new.percent)%"))
    }
}

private struct BatteryRestLeft: View {
    @ObservedObject var module: BatteryModule
    var body: some View {
        let state = module.state
        BatteryGlyphView(glyph: BatteryGlyph(percent: state.map { Double($0.percent) }, charging: state?.charging ?? false))
            .frame(width: 22, height: 11)
            .foregroundStyle(.white.opacity(0.9))
    }
}

private struct BatteryRestRight: View {
    @ObservedObject var module: BatteryModule
    var body: some View {
        Text(module.state.map { "\($0.percent)%" } ?? "")
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(1)
    }
}

/// Draws MenuSprite's own battery glyph (real level and charging bolt) in SwiftUI.
struct BatteryGlyphView: View {
    let glyph: BatteryGlyph
    var body: some View {
        Canvas { context, size in
            let glyph = glyph
            let image = NSImage(size: size, flipped: false) { rect in glyph.draw(in: rect, ink: .white); return true }
            context.draw(Image(nsImage: image), in: CGRect(origin: .zero, size: size))
        }
    }
}
