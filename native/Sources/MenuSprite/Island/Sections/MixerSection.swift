import Combine
import IslandKit
import SwiftUI

/// The Volume mixer: the system output and microphone, and a fader per app that plays sound, with
/// boost to 200 %, mute and its own output. Per-app engines run while the island runs and an app has
/// its own level or output, whether or not the page is open; the app list is read only while the
/// page is visible. The Controls tile opens this page.
@MainActor
final class MixerSection: IslandSection {
    let id = IslandSectionID.mixer
    private unowned let environment: IslandEnvironment
    private let controller: MixerController
    private let control: IslandControlModel
    private let previewOptions: Bool
    private var retainsAudio = false
    private var settingsObservation: AnyCancellable?

    init(environment: IslandEnvironment) {
        self.environment = environment
        if environment.isHeadless, let preview = MixerPreview.requested() {
            controller = MixerPreview.controller(preview.state, systemAudio: environment.systemAudio)
            previewOptions = preview.options
        } else {
            controller = MixerController(store: MixerStore(defaults: environment.isHeadless ? nil : .standard),
                                         systemAudio: environment.systemAudio, headless: environment.isHeadless)
            previewOptions = false
        }
        control = IslandControlModel(.mixer) { [weak environment] in environment?.open(.mixer) }
        control.availability = Self.tileAvailability(environment)
        environment.register(control)
        settingsObservation = environment.settingsStore.$value
            .map { $0.isVisible(.mixer) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] shown in self?.sectionVisibilityChanged(shown) }
    }

    var availability: IslandAvailability { .available }

    func pageHeight(_ context: IslandPageContext) -> IslandPageHeight { .fill }

    func page(_ context: IslandPageContext) -> AnyView {
        AnyView(MixerPage(controller: controller, audio: environment.systemAudio, context: context, showsOptions: previewOptions))
    }

    func options() -> AnyView? { AnyView(MixerSettingsOptions(controller: controller, store: controller.store)) }

    func islandDidStart() { controller.setRunning(true, sectionShown: environment.settings.isVisible(.mixer)) }

    func islandDidStop() {
        pageDidDisappear()
        controller.stop()
    }

    func pageDidAppear() {
        if !retainsAudio {
            retainsAudio = true
            environment.systemAudio.retain()
        }
        controller.setPageVisible(true)
    }

    func pageDidDisappear() {
        if retainsAudio {
            retainsAudio = false
            environment.systemAudio.release()
        }
        controller.setPageVisible(false)
    }

    /// The tile works only while the page it opens is shown.
    private static func tileAvailability(_ environment: IslandEnvironment) -> IslandAvailability {
        guard !environment.settings.isVisible(.mixer) else { return .available }
        return .unavailable("Show “\(IslandSectionID.mixer.title)” on the Content tab.") { [weak environment] in
            environment?.actions.openSettings(.mixer)
        }
    }

    private func sectionVisibilityChanged(_ shown: Bool) {
        control.availability = Self.tileAvailability(environment)
        controller.setSectionShown(shown)
        environment.invalidate()
    }
}
