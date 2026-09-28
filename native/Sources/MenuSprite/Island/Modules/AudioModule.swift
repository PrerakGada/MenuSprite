import Combine
import IslandKit
import SwiftUI

/// System volume for the island: the shared output and input state, the Controls volume card, the
/// volume keys and notice, and the Mute microphone tile. CoreAudio is observed only while a card,
/// the mixer or Now Playing holds interest, or while the volume indicator is wanted; the key tap
/// only while that indicator is wanted and Accessibility is already granted.
@MainActor
final class AudioModule: IslandFeature {
    private unowned let environment: IslandEnvironment
    private let output: SystemAudioController
    private let keys: VolumeKeyHandler
    private let microphone: MicMuteController
    private var settingsObservation: AnyCancellable?
    private var accessibility: IslandAccessibilityObserver?
    private var started = false

    init(environment: IslandEnvironment) {
        self.environment = environment
        output = SystemAudioController(audio: environment.systemAudio)
        keys = VolumeKeyHandler(controller: output)
        microphone = MicMuteController()

        output.isOpen = { [unowned environment] in environment.isOpen }
        output.onChange = { [weak self] in self?.showNotice() }
        keys.conditions = { [weak self] in self?.keyConditions ?? .init(routed: false, showsNotices: false, hasVolume: false, hasMute: false) }
        keys.showNotice = { [weak self] in self?.showNotice() }

        let output = output
        environment.register(card: .volume, IslandCardProvider(availability: { .available }) { [unowned environment] style, _ in
            AnyView(VolumeLevelView(audio: environment.systemAudio, controller: output, environment: environment, style: style))
        })
        environment.register(indicator: .volume) { .available }
        environment.register(microphone.control)
    }

    func islandDidStart() {
        started = true
        settingsObservation = environment.settingsStore.$value
            .map { ($0.enabled, $0.indicators.contains(.volume)) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] _ in Task { @MainActor in self?.sync() } }
        if !environment.isHeadless {
            accessibility = IslandAccessibilityObserver { [weak self] in self?.sync() }
            microphone.start()
        }
        sync()
    }

    func islandDidStop() {
        started = false
        settingsObservation = nil
        accessibility = nil
        sync()
        if !environment.isHeadless { microphone.stop() }
    }

    private func sync() {
        let wanted = started && environment.wants(.volume)
        output.indicatorWanted = wanted
        keys.setInstalled(wanted && !environment.isHeadless)
    }

    private var keyConditions: IslandVolumeKeyGate.Conditions {
        let audio = environment.systemAudio
        return .init(routed: started && environment.wants(.volume), showsNotices: environment.notices.canShow(),
                     hasVolume: audio.volume != nil, hasMute: audio.hasMute)
    }

    private func showNotice() {
        let audio = environment.systemAudio
        guard environment.wants(.volume), audio.volume != nil || audio.isMuted else { return }
        let readout = IslandLevelReadout.volume(level: audio.volume ?? 0, muted: audio.isMuted)
        environment.notices.post(IslandNotice(kind: .volume, style: .level(symbol: readout.symbol, value: readout.value),
                                              label: "Volume, \(IslandLevelReadout.percent(readout.value))%"))
    }
}
