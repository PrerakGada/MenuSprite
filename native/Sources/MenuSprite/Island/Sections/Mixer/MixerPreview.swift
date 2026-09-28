import IslandKit

/// Made-up mixer states for the off-screen render harness only (`--mixer-preview populated|empty|permission`,
/// add `,options` for the options view). Nothing here reads or touches audio.
enum MixerPreview {
    enum State: String {
        case populated, empty, permission
    }

    /// The requested preview, if the harness asked for one.
    static func requested(arguments: [String] = CommandLine.arguments) -> (state: State, options: Bool)? {
        guard let index = arguments.firstIndex(of: "--mixer-preview"), arguments.indices.contains(index + 1) else { return nil }
        let parts = arguments[index + 1].split(separator: ",").map(String.init)
        guard let state = parts.first.flatMap(State.init(rawValue:)) else { return nil }
        return (state, parts.contains("options"))
    }

    @MainActor
    static func controller(_ state: State, systemAudio: IslandSystemAudio) -> MixerController {
        fill(systemAudio)
        let outputs = [MixerDevice(uid: "speakers", name: "MacBook Pro Speakers", isDefault: true),
                       MixerDevice(uid: "airpods", name: "AirPods Pro", isDefault: false)]
        switch state {
        case .populated:
            return MixerController(preview: rows, outputs: outputs, permission: .granted, systemAudio: systemAudio)
        case .empty:
            return MixerController(preview: [], outputs: outputs, permission: .granted, systemAudio: systemAudio)
        case .permission:
            return MixerController(preview: [], outputs: outputs, permission: .notDetermined, systemAudio: systemAudio)
        }
    }

    private static var rows: [MixerRow] {
        func row(_ bundle: String, _ name: String, gain: Double, playing: Bool = false, route: String? = nil, missing: Bool = false,
                 pinned: Bool = false, bypassed: Bool = false, unapplied: Bool = false) -> MixerRow {
            MixerRow(app: MixerApp(id: bundle, storageKey: bundle, name: name, bundleID: bundle, pid: 0, objects: [1],
                                   isPlaying: playing, isBypassed: bypassed),
                     gain: gain, route: route, routeMissing: missing, isPinned: pinned, canMoveLeft: true, canMoveRight: true,
                     couldNotApply: unapplied)
        }
        return [row("com.apple.Music", "Music", gain: 1, playing: true, pinned: true),
                row("com.apple.Safari", "Safari", gain: 1.5, playing: true),
                row("com.apple.podcasts", "Podcasts", gain: 0.45, route: "airpods", unapplied: true),
                row("com.apple.QuickTimePlayerX", "QuickTime Player", gain: 0, route: "studio-display", missing: true),
                row("us.zoom.xos", "zoom.us", gain: 1, bypassed: true),
                row(MixerListing.finderBundleID, "Finder", gain: 1)]
    }

    /// Only fills the shared system-audio state when nothing else has.
    @MainActor
    private static func fill(_ audio: IslandSystemAudio) {
        guard audio.output == nil else { return }
        let speakers = IslandAudioDevice(id: 1, uid: "speakers", name: "MacBook Pro Speakers")
        audio.outputs = [speakers, IslandAudioDevice(id: 2, uid: "airpods", name: "AirPods Pro", symbol: "airpodspro")]
        audio.output = speakers
        audio.volume = 0.56
        audio.hasMute = true
        let microphone = IslandAudioDevice(id: 3, uid: "mic", name: "MacBook Pro Microphone", symbol: "mic")
        audio.inputs = [microphone]
        audio.input = microphone
        audio.inputVolume = 0.7
    }
}
