import Combine
import IslandKit
import SwiftUI

/// Recent captures: MenuSprite's own screenshots and screen recordings, hosted by the island. The
/// page lists the last twelve captures (or a capture's quick preview); the Screenshot and Screen
/// recording tiles and two optional global shortcuts open the chooser, whose controls hang from the
/// island (or float, per "Captures" in Where things open). All capture work lives in `CaptureService`;
/// nothing runs until the person captures something.
@MainActor
final class CapturesSection: IslandSection {
    let id = IslandSectionID.captures
    let service: CaptureService
    private unowned let environment: IslandEnvironment
    private let shortcuts: CaptureShortcuts
    private let screenshotControl: IslandControlModel
    private let recordingControl: IslandControlModel
    private var observations: Set<AnyCancellable> = []

    init(environment: IslandEnvironment) {
        self.environment = environment
        let headless = environment.isHeadless
        let options = CaptureOptions(defaults: headless ? nil : .standard)
        // Access is read when the page appears or a capture starts, not here.
        service = CaptureService(environment: environment, options: options, library: CaptureLibrary(), hasAccess: false)
        let service = service
        shortcuts = CaptureShortcuts(options: options) { tool in
            tool == .screenshot ? service.begin(.screenshot) : service.toggleRecording()
        }
        screenshotControl = IslandControlModel(.screenshot) { service.begin(.screenshot) }
        recordingControl = IslandControlModel(.recording) { service.toggleRecording() }
        environment.register(screenshotControl)
        environment.register(recordingControl)
        environment.register(indicator: .captures) { [weak environment] in
            guard let environment, !environment.settings.isVisible(.captures) else { return .available }
            return .unavailable("Show “Recent captures” on the Content tab.", fixTitle: "Show") { [weak environment] in
                environment?.actions.openSettings(.captures)
            }
        }
        service.recording.$state
            .map { state -> Bool in
                switch state {
                case .countdown, .recording, .finishing: true
                case .idle, .message: false
                }
            }
            .removeDuplicates()
            .sink { [weak recordingControl] active in
                recordingControl?.isOn = active
                recordingControl?.symbol = active ? "stop.circle.fill" : IslandControlID.recording.symbol
            }
            .store(in: &observations)
    }

    var availability: IslandAvailability { .available }

    func pageHeight(_ context: IslandPageContext) -> IslandPageHeight {
        guard service.preview.isHosted, let item = service.preview.item else { return .fill }
        return .fixed(CapturePreviewLayout.pageHeight(item.image.size, width: context.width, budget: context.budget))
    }

    func page(_ context: IslandPageContext) -> AnyView {
        AnyView(CapturesPage(service: service, context: context))
    }

    /// A capture being previewed gets the full-width header row for its actions.
    var wantsFullHeaderRow: Bool { service.preview.isHosted }

    /// The hosted preview's actions; nothing otherwise.
    func headerAccessory(_ context: IslandPageContext) -> AnyView? {
        service.preview.isHosted ? AnyView(CapturePreviewActions(controller: service.preview)) : nil
    }

    func options() -> AnyView? {
        AnyView(CapturesOptionsView(options: service.options, settings: environment.settingsStore, service: service,
                                    shortcuts: shortcuts, headless: environment.isHeadless))
    }

    func islandDidStart() {
        guard !environment.isHeadless else { return }
        shortcuts.start()
    }

    func islandDidStop() {
        shortcuts.stop()
        service.stop()
        service.library.releaseImages()
    }

    func pageDidAppear() {
        service.preview.pageDidAppear()
        guard !environment.isHeadless else { return }
        service.refreshAccess()
        service.library.reload()
    }

    func pageDidDisappear() {
        service.preview.pageDidDisappear()
        service.library.releaseImages()
    }
}

extension CapturesSection: IslandRenderSampling {
    func renderSamples(display: IslandDisplayMetrics, settings: IslandSettings) -> [IslandRenderSample] {
        CapturesSamples(environment: environment, display: display, settings: settings, options: options()).all
    }
}

/// The two global shortcuts, registered with the system's hot-key service only while the island
/// runs and only when the person has recorded one. A combination another app owns is reported.
@MainActor
final class CaptureShortcuts: ObservableObject {
    @Published private(set) var taken: Set<CaptureTool> = []
    private let options: CaptureOptions
    private let perform: (CaptureTool) -> Void
    private var observation: AnyCancellable?

    private static func name(_ tool: CaptureTool) -> String { "captures.\(tool.rawValue)" }

    init(options: CaptureOptions, perform: @escaping (CaptureTool) -> Void) {
        self.options = options
        self.perform = perform
    }

    func start() {
        observation = options.$screenshotShortcut.combineLatest(options.$recordingShortcut)
            .sink { [weak self] screenshot, recording in self?.register(screenshot: screenshot, recording: recording) }
    }

    func stop() {
        observation = nil
        for tool in CaptureTool.allCases { IslandShortcuts.shared.unregister(Self.name(tool)) }
        taken = []
    }

    private func register(screenshot: IslandShortcut?, recording: IslandShortcut?) {
        var taken = Set<CaptureTool>()
        for (tool, shortcut) in [(CaptureTool.screenshot, screenshot), (.recording, recording)] {
            let registered = IslandShortcuts.shared.register(Self.name(tool), shortcut) { [weak self] in self?.perform(tool) }
            if !registered { taken.insert(tool) }
        }
        self.taken = taken
    }
}
