import AppKit
import Combine
import IslandKit
import SwiftUI
import UniformTypeIdentifiers

/// Now Playing: the page, the Controls card, the compact music activity, the New track notice and the
/// hook the shell's swipe uses to skip. It owns the music reader (a perl child process) and runs it
/// only while something needs it: the page or card on screen, playing music allowed to take the
/// closed island, or New track notices switched on.
@MainActor
final class MusicSection: IslandSection {
    let id = IslandSectionID.music
    unowned let environment: IslandEnvironment
    let musicOptions: MusicOptions
    let model: MusicModel
    let lyrics: LyricsModel
    private let strip = MusicStripState()
    private var observations: Set<AnyCancellable> = []
    private var started = false
    private var pageVisible = false
    private var visibleCards = 0
    private var stripLive = false
    private var detector = MusicTrackChangeDetector()
    private var pendingNotice: Task<Void, Never>?

    init(environment: IslandEnvironment) {
        self.environment = environment
        musicOptions = MusicOptions()
        model = MusicModel(options: musicOptions)
        lyrics = LyricsModel(options: musicOptions)
        model.onPlayback = { [weak self] playback in self?.playbackChanged(playback) }
        model.onRestart = { [weak self] in self?.detector.reset() }
        environment.register(card: .nowPlaying, IslandCardProvider(
            availability: { [weak self] in self?.shownAvailability ?? .notBuilt },
            view: { [weak self] style, context in
                guard let self, case .card(let height) = style else { return AnyView(EmptyView()) }
                return AnyView(MusicCardHost(section: self, height: height, preview: context.isPreview))
            }))
        environment.register(indicator: .newTrack) { [weak self] in self?.shownAvailability ?? .notBuilt }
        environment.musicSkip = { [weak self] forward in self?.model.skip(forward: forward) ?? false }
    }

    var availability: IslandAvailability { .available }

    /// The card and the New track indicator need the section itself on.
    private var shownAvailability: IslandAvailability {
        guard !environment.settings.isVisible(.music) else { return .available }
        return .unavailable("Show “\(id.title)” on the Content tab.", fixTitle: "Show") { [weak environment] in
            environment?.actions.openSettings(.music)
        }
    }

    // MARK: Page

    /// Tall while the lyrics panel is open, so the presets give the page room for it.
    var isVertical: Bool { lyrics.isPanelOpen && model.phase == .ready }

    var hasVolume: Bool { environment.systemAudio.volume != nil || !environment.systemAudio.outputs.isEmpty }
    var lyricsAvailable: Bool { musicOptions.showLyrics && model.phase == .ready }

    func layout(for context: IslandPageContext) -> MusicPageLayout {
        let idle = model.phase == .idle || model.phase == .off
        return MusicPageLayout(size: environment.settings.size, budget: context.budget, idle: idle,
                               controlsRow: hasVolume || (lyricsAvailable && !idle),
                               panelOpen: lyrics.isPanelOpen && model.phase == .ready && !context.isPreview)
    }

    func pageHeight(_ context: IslandPageContext) -> IslandPageHeight { .fixed(layout(for: context).height) }

    func page(_ context: IslandPageContext) -> AnyView { AnyView(MusicPage(section: self, context: context)) }

    func options() -> AnyView? { AnyView(MusicOptionsView(options: musicOptions, settings: environment.settingsStore)) }

    func pageDidAppear() {
        guard !pageVisible else { return }
        pageVisible = true
        environment.systemAudio.retain()
        updateDemand()
    }

    func pageDidDisappear() {
        guard pageVisible else { return }
        pageVisible = false
        environment.systemAudio.release()
        // Leaving the page closes the panel and stops its lookup; this song's lyrics stay cached.
        lyrics.setPanelOpen(false)
        updateDemand()
    }

    fileprivate func cardAppeared() { visibleCards += 1; updateDemand() }
    fileprivate func cardDisappeared() { visibleCards = max(0, visibleCards - 1); updateDemand() }

    // MARK: Lifecycle

    func islandDidStart() {
        guard !started else { return }
        started = true
        let refresh: () -> Void = { [weak self] in Task { @MainActor in self?.updateDemand() } }
        environment.$isOpen.removeDuplicates().sink { _ in refresh() }.store(in: &observations)
        environment.$destination.removeDuplicates().sink { _ in refresh() }.store(in: &observations)
        environment.settingsStore.$value
            .map { [$0.enabled, $0.isVisible(.music), $0.atRest == .nothing, $0.showPlayingMusic, $0.opening == .hidden,
                    $0.indicators.contains(.newTrack), $0.hiddenCards.contains(.nowPlaying)] }
            .removeDuplicates()
            .sink { _ in refresh() }
            .store(in: &observations)
        // Shape changes of the visible page.
        let relayout: () -> Void = { [weak self] in
            Task { @MainActor in if let self, self.pageVisible { self.environment.invalidate() } }
        }
        model.$phase.removeDuplicates().dropFirst().sink { _ in relayout() }.store(in: &observations)
        lyrics.$isPanelOpen.removeDuplicates().dropFirst().sink { _ in relayout() }.store(in: &observations)
        musicOptions.$showLyrics.removeDuplicates().dropFirst().sink { _ in relayout() }.store(in: &observations)
        environment.systemAudio.$outputs.map(\.isEmpty).removeDuplicates().dropFirst().sink { _ in relayout() }.store(in: &observations)
        model.$cover.dropFirst().sink { [weak self] _ in Task { @MainActor in self?.updateActivity() } }.store(in: &observations)
        updateDemand()
    }

    func islandDidStop() {
        started = false
        observations.removeAll()
        pendingNotice?.cancel()
        pendingNotice = nil
        if pageVisible { pageDidDisappear() }
        visibleCards = 0
        lyrics.clear(closing: true)
        updateDemand()
    }

    /// Starts or stops the reader by the rule in MusicReaderDemand.
    private func updateDemand() {
        let settings = environment.settings
        let shown = settings.isVisible(.music)
        var demand = MusicReaderDemand()
        demand.islandRunning = settings.enabled && (started || pageVisible || visibleCards > 0)
        demand.sectionShown = shown
        demand.musicPageVisible = pageVisible || (environment.isOpen && environment.destination == .section(.music))
        demand.playbackCardVisible = visibleCards > 0
            || (environment.isOpen && environment.destination == .section(.controls) && !settings.hiddenCards.contains(.nowPlaying))
        demand.hiddenUntilHover = settings.opening == .hidden
        let background = MusicActivityGate.demand(settings, sectionShown: shown, newTrackAvailable: true)
        demand.restingMusic = started && background.resting
        demand.newTrackNotices = started && background.notices
        model.setRunning(demand.shouldRun)
        updateActivity()
    }

    // MARK: Compact activity and notice

    /// Publishes the music strip while something plays and playing music may take the closed island.
    /// Paused music is not shown at rest; its controls stay in the open island.
    private func updateActivity() {
        let settings = environment.settings
        let allowed = started && MusicActivityGate.allowsCompactMusic(settings, sectionShown: settings.isVisible(.music))
        guard allowed, model.isPlaying else {
            if stripLive {
                // The strip state stays as it was, so the leaving strip keeps drawing the last track.
                stripLive = false
                environment.activities.set(nil, for: .music)
            }
            return
        }
        if strip.cover != model.cover { strip.cover = model.cover }
        if !strip.playing { strip.playing = true }
        guard !stripLive else { return }
        stripLive = true
        let physical = environment.stripIsPhysical
        let geometry = MusicStripGeometry(stripHeight: environment.stripHeight, isPhysical: physical)
        var activity = IslandCompactStrip(kind: .music, wing: geometry.wing, minimumRoom: geometry.wing,
                                          left: AnyView(MusicStripLeft(state: strip)), right: AnyView(MusicStripRight(state: strip)),
                                          companionMark: AnyView(MusicCompanionMark(state: strip)))
        // The wing follows the camera's height; with less room than that the wings vanish (music never
        // drops below the camera).
        activity.wingForRoom = { room, height in
            let wing = MusicStripGeometry(stripHeight: height, isPhysical: physical).wing
            return room >= wing ? wing : 0
        }
        environment.activities.set(activity, for: .music)
    }

    private func playbackChanged(_ playback: MusicPlayback?) {
        lyrics.update(playback)
        updateActivity()
        guard let playback else { return }
        let isNewSong = detector.observe(player: playback.bundleID, title: playback.title, artist: playback.artist,
                                         playing: playback.isPlaying)
        guard isNewSong, started, environment.wants(.newTrack) else { return }
        // A burst of skips, or an artist landing after its title, gives one notice where playback settles.
        pendingNotice?.cancel()
        pendingNotice = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.postTrackNotice()
        }
    }

    private func postTrackNotice() {
        guard started, environment.wants(.newTrack), !environment.isOpen, !environment.captureControlsActive,
              let playback = model.playback, playback.isPlaying, !playback.title.isEmpty else { return }
        environment.notices.post(MusicTrackNotice.make(title: playback.title, artist: playback.artist, model: model))
    }

    // MARK: Lyrics import

    /// A standard open panel above the island (never a sheet, which would move and restyle it). The
    /// file applies only if the same song is still shown with the panel open.
    func chooseLyricsFile() {
        guard !environment.isHeadless, let revision = lyrics.currentRevision else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose lyrics for this song. They're kept only while it plays."
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.hidesOnDeactivate = false
        environment.actions.holdOpen(true)
        NSApp.activate()
        panel.begin { [weak self, panel] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.environment.actions.holdOpen(false)
                guard response == .OK, let url = panel.url else { return }
                self.lyrics.importLyrics(from: url, for: revision)
                self.environment.open(.music)
            }
        }
    }
}

/// The Controls card, counting itself as a visible consumer of the reader while on screen (never in
/// a settings preview).
private struct MusicCardHost: View {
    let section: MusicSection
    let height: CGFloat
    let preview: Bool

    var body: some View {
        MusicCard(model: section.model, height: height) { if !preview { section.environment.open(.music) } }
            .onAppear { if !preview { section.cardAppeared() } }
            .onDisappear { if !preview { section.cardDisappeared() } }
    }
}
