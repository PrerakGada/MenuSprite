import IslandKit

/// The volume, down and mute keys while the island shows volume notices. A consumed key is what
/// keeps macOS's own volume overlay away; the change goes through the output controller off the tap
/// thread, and a write that fails hands the key back to macOS so it is never lost.
@MainActor
final class VolumeKeyHandler {
    private let controller: SystemAudioController
    private var gate = IslandVolumeKeyGate()
    private lazy var tap = IslandSystemKeyTap { [unowned self] key in self.handle(key) }
    /// The conditions right now, read on every key.
    var conditions: () -> IslandVolumeKeyGate.Conditions = {
        .init(routed: false, showsNotices: false, hasVolume: false, hasMute: false)
    }
    /// Raise the volume notice with the current level.
    var showNotice: () -> Void = {}

    init(controller: SystemAudioController) { self.controller = controller }

    func setInstalled(_ installed: Bool) {
        if installed {
            guard !tap.isInstalled else { return }
            gate.reset()
            tap.install()
        } else {
            tap.remove()
            gate.reset()
        }
    }

    private func handle(_ key: IslandSystemKey) -> IslandSystemKeyTap.Verdict {
        let audio = controller.audio
        switch gate.handle(key.event, modifiers: key.modifiers, conditions: conditions()) {
        case .pass:
            return .pass
        case .consume:
            return .consume
        case .step(let up, let fine):
            let result = IslandVolumeStep.apply(current: audio.volume ?? 0, muted: audio.isMuted, up: up, fine: fine)
            controller.request(volume: result.volume, muted: result.unmute ? false : nil, own: false) { outcome in
                if outcome == .failed { IslandSystemKeyTap.postToSystem(key) }
            }
        case .toggleMute:
            controller.request(volume: nil, muted: !audio.isMuted, own: false) { outcome in
                if outcome == .failed { IslandSystemKeyTap.postToSystem(key) }
            }
        }
        if controller.keyFeedback() { showNotice() }
        return .consume
    }
}
