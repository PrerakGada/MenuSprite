import Combine
import IslandKit
import SwiftUI

/// Display brightness and the keyboard light for the island: the Controls brightness card, the
/// brightness keys and notice (only once "Control displays" is on), and the keyboard-light notice,
/// read shortly after macOS handles an illumination key. The key tap exists only while one of those
/// notices is wanted and Accessibility is already granted; illumination keys are never taken.
@MainActor
final class DisplayModule: IslandFeature {
    private unowned let environment: IslandEnvironment
    private let settings = IslandDisplaySettings.shared
    private let brightness: BrightnessController
    private lazy var tap = IslandSystemKeyTap { [unowned self] key in self.handle(key) }
    private var gate = IslandBrightnessKeyGate()
    /// nil until the backlight has been looked for.
    private var hasKeyboardBacklight: Bool?
    private var keyboardRead: Task<Void, Never>?
    private var controlDisplaysObservation: AnyCancellable?
    private var settingsObservation: AnyCancellable?
    private var accessibility: IslandAccessibilityObserver?
    private var started = false

    init(environment: IslandEnvironment) {
        self.environment = environment
        brightness = BrightnessController(settings: settings)
        brightness.onChange = { [weak self] level in self?.showBrightness(level) }

        let brightness = brightness
        let settings = settings
        environment.register(card: .brightness, IslandCardProvider(availability: { .available }) { [unowned environment] style, context in
            AnyView(BrightnessLevelView(controller: brightness, settings: settings, environment: environment,
                                        style: style, readsMonitors: !context.isPreview))
        })
        environment.register(indicator: .brightness) { [unowned environment] in
            guard let reason = IslandDisplayRouting.brightnessReason(controlDisplays: settings.controlDisplays) else { return .available }
            return .unavailable(reason, fixTitle: "Open settings") { environment.actions.openSettings(.controls) }
        }
        environment.register(indicator: .keyboardLight) { [weak self] in
            // Until the backlight has been looked for, assume it is there.
            guard let reason = IslandDisplayRouting.keyboardLightReason(hasBacklight: self?.hasKeyboardBacklight ?? true) else { return .available }
            return .unavailable(reason)
        }
        controlDisplaysObservation = settings.$controlDisplays.dropFirst().removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.controlDisplaysChanged() } }
    }

    func islandDidStart() {
        started = true
        settingsObservation = environment.settingsStore.$value
            .map { [$0.enabled, $0.indicators.contains(.brightness), $0.indicators.contains(.keyboardLight)] }
            .removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.sync() } }
        if !environment.isHeadless { accessibility = IslandAccessibilityObserver { [weak self] in self?.sync() } }
        findKeyboardBacklight()
        sync()
    }

    func islandDidStop() {
        started = false
        settingsObservation = nil
        accessibility = nil
        keyboardRead?.cancel()
        keyboardRead = nil
        sync()
    }

    private func controlDisplaysChanged() {
        environment.invalidate()
        brightness.controlDisplaysChanged()
        sync()
    }

    private func sync() {
        let brightnessRouted = started && environment.wants(.brightness)
        let keyboardRouted = started && hasKeyboardBacklight == true && environment.wants(.keyboardLight)
        brightness.setKeysNeedRoutes(brightnessRouted)
        if (brightnessRouted || keyboardRouted) && !environment.isHeadless {
            guard !tap.isInstalled else { return }
            gate.reset()
            tap.install()
        } else {
            tap.remove()
            gate.reset()
        }
    }

    private func findKeyboardBacklight() {
        guard hasKeyboardBacklight == nil else { return }
        brightness.work.run({ KeyboardBacklight.builtIn != nil }) { [weak self] found in
            guard let self else { return }
            self.hasKeyboardBacklight = found
            self.environment.invalidate()
            self.sync()
        }
    }

    // MARK: Keys

    private func handle(_ key: IslandSystemKey) -> IslandSystemKeyTap.Verdict {
        if IslandMediaKey.illuminationKeys.contains(key.event.code) {
            // Observed, never taken: macOS changes the light, and the island reports what it set.
            if IslandKeyboardLightKeys.triggersRead(key.event, modifiers: key.modifiers), environment.wants(.keyboardLight) {
                readKeyboardLight()
            }
            return .pass
        }
        let conditions = IslandBrightnessKeyGate.Conditions(routed: started && environment.wants(.brightness),
                                                            showsNotices: environment.notices.canShow(),
                                                            hasTarget: brightness.keyTarget != nil)
        switch gate.handle(key.event, modifiers: key.modifiers, conditions: conditions) {
        case .pass:
            return .pass
        case .consume:
            return .consume
        case .step(let up, let fine):
            // A step that could not be applied goes back to macOS, which handles the key natively.
            brightness.step(up: up, fine: fine) { applied in
                if !applied { IslandSystemKeyTap.postToSystem(key) }
            }
            return .consume
        }
    }

    /// One read shortly after the last illumination key of a burst; the level is read, never predicted.
    private func readKeyboardLight() {
        keyboardRead?.cancel()
        keyboardRead = Task { [weak self] in
            try? await Task.sleep(for: .seconds(IslandKeyboardLightKeys.readDelay))
            guard !Task.isCancelled, let self else { return }
            self.brightness.work.run({ KeyboardBacklight.builtIn?.level() }) { [weak self] level in
                if let level { self?.showKeyboardLight(level) }
            }
        }
    }

    // MARK: Notices

    private func showBrightness(_ level: Double) {
        guard environment.wants(.brightness) else { return }
        post(.brightness, symbol: "sun.max.fill", title: "Brightness", level: level)
    }

    private func showKeyboardLight(_ level: Double) {
        guard started, environment.wants(.keyboardLight) else { return }
        post(.keyboardLight, symbol: "keyboard", title: "Keyboard light", level: level)
    }

    private func post(_ kind: IslandNoticeKind, symbol: String, title: String, level: Double) {
        environment.notices.post(IslandNotice(kind: kind, style: .level(symbol: symbol, value: level),
                                              label: "\(title), \(IslandLevelReadout.percent(level))%"))
    }
}
