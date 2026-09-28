import Combine
import IslandKit
import SwiftUI

/// A mirror to check yourself before a call. The camera starts only when the person presses Open
/// camera on this page, and stops the moment the page is not on screen: another page, Explore or the
/// app panel, the island collapsing, a capture being framed, the section hidden, the island stopping
/// (off, lock, sleep). Zero cost at rest.
@MainActor
final class CameraSection: IslandSection {
    let id = IslandSectionID.camera
    let service: CameraMirrorService
    private unowned let environment: IslandEnvironment
    private var presentation: Set<AnyCancellable> = []

    init(environment: IslandEnvironment) {
        self.environment = environment
        service = CameraMirrorService(hold: { [weak environment] on in environment?.actions.holdOpen(on) },
                                      headless: environment.isHeadless,
                                      preview: environment.isHeadless ? CameraPreviewData.requested() : nil)
    }

    var availability: IslandAvailability { .available }

    func page(_ context: IslandPageContext) -> AnyView {
        AnyView(CameraMirrorPage(service: service, context: context,
                                 open: { [weak self] in self?.openCamera() }, stop: { [weak self] in self?.stopCamera() }))
    }

    func options() -> AnyView? { AnyView(CameraMirrorOptions(service: service)) }

    func pageDidDisappear() { stopCamera() }
    func islandDidStop() { stopCamera() }

    /// The island is open on this page with nothing else in front: the only time the camera may run.
    private var canPresent: Bool {
        let settings = environment.settings
        return environment.isOpen && environment.destination == .section(.camera) && !environment.captureControlsActive
            && settings.enabled && settings.isVisible(.camera)
    }

    private func openCamera() {
        guard canPresent else { return }
        service.open()
        guard presentation.isEmpty else { return }
        // Re-checked on every presentation change while the camera is up.
        let recheck: () -> Void = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { if self?.canPresent == false { self?.stopCamera() } } }
        }
        environment.$isOpen.dropFirst().sink { _ in recheck() }.store(in: &presentation)
        environment.$destination.dropFirst().sink { _ in recheck() }.store(in: &presentation)
        environment.$captureControlsActive.dropFirst().sink { _ in recheck() }.store(in: &presentation)
        environment.settingsStore.$value.dropFirst().sink { _ in recheck() }.store(in: &presentation)
    }

    private func stopCamera() {
        presentation.removeAll()
        service.stop()
    }
}
