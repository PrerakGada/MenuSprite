import AppKit
import Combine
import IslandKit
import SwiftUI

/// Files arriving in one folder the person chooses: in progress and just finished, with a compact
/// strip beside the camera while something downloads and a notice when a download is proven done.
///
/// The watcher runs only while the island runs, the section is shown, its Downloads switch is on, a
/// folder is chosen and something needs it (the page, the strip or the notice). Hiding the section,
/// switching it off or stopping the island stops the watcher and drops what it read.
@MainActor
final class DownloadsSection: IslandSection {
    enum Setup: Equatable { case off, needsFolder, unavailable, ready }

    let id = IslandSectionID.downloads
    let model = DownloadsModel()
    let preferences: DownloadsPreferences
    private unowned let environment: IslandEnvironment
    private lazy var chooser = DownloadFolderChooser(environment: environment) { [weak self] url in self?.folderChosen(url) }
    private var running = false
    private var shown = false
    private var pageVisible = false
    private var watched: DownloadFolderSource?
    private var publishedName: String??
    private var lastShape: (Setup, Bool)?
    private var syncing = false
    private var resync = false
    private var settingsObservation: AnyCancellable?

    /// The render harness watches this temporary folder instead of a chosen one, so layouts can be
    /// checked without touching the person's Downloads folder or its permission.
    private static let renderFolder = ProcessInfo.processInfo.environment["MENUSPRITE_ISLAND_DOWNLOADS_FOLDER"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    init(environment: IslandEnvironment) {
        self.environment = environment
        preferences = DownloadsPreferences()
        preferences.changed = { [weak self] in self?.sync() }
        model.onChange = { [weak self] in self?.sync() }
        model.onCompletion = { [weak self] in self?.announce($0) }
    }

    var availability: IslandAvailability { .available }

    /// The list fills the page; the set-up controls and an empty folder take only what they need.
    func pageHeight(_ context: IslandPageContext) -> IslandPageHeight {
        guard setup == .ready else { return .fixed(min(context.budget, DownloadsSetupView.height(width: context.width))) }
        return isEmptyFolder ? .fixed(min(context.budget, 140)) : .fill
    }

    func page(_ context: IslandPageContext) -> AnyView {
        AnyView(DownloadsPage(section: self, model: model, preferences: preferences, context: context))
    }

    func options() -> AnyView? { AnyView(DownloadsOptions(section: self, model: model, preferences: preferences)) }

    func islandDidStart() {
        running = true
        shown = environment.settings.isVisible(.downloads)
        model.setUnavailable(false)
        // The publisher fires before the value lands, so the new visibility is taken from it directly.
        settingsObservation = environment.settingsStore.$value
            .map { $0.isVisible(.downloads) }
            .removeDuplicates()
            .sink { [weak self] visible in
                MainActor.assumeIsolated {
                    self?.shown = visible
                    self?.sync()
                }
            }
        sync()
    }

    func islandDidStop() {
        running = false
        settingsObservation = nil
        chooser.cancelIslandChooser()
        sync()
    }

    func pageDidAppear() {
        pageVisible = true
        sync()
    }

    func pageDidDisappear() {
        pageVisible = false
        chooser.cancelIslandChooser()
        sync()
    }

    // MARK: Folder

    var folderSource: DownloadFolderSource? {
        if environment.isHeadless { return Self.renderFolder.map { .path($0) } }
        return preferences.bookmark.map { .bookmark($0) }
    }

    var folderName: String? { environment.isHeadless ? Self.renderFolder?.lastPathComponent : preferences.folderName }

    var isEnabled: Bool { environment.isHeadless ? Self.renderFolder != nil : preferences.enabled }

    /// Known to be empty: the list stays full height until the first scan says otherwise.
    private var isEmptyFolder: Bool { model.isLoaded && model.items.isEmpty }

    var setup: Setup {
        if !isEnabled { return .off }
        if model.isUnavailable { return .unavailable }
        return folderSource == nil ? .needsFolder : .ready
    }

    func setEnabled(_ on: Bool) {
        guard !environment.isHeadless else { return }
        preferences.enabled = on
    }

    func chooseFolder(from origin: DownloadFolderChooser.Origin) { chooser.choose(from: origin) }

    /// Stops watching, deletes the saved authority and turns the switch off.
    func forgetFolder() {
        guard !environment.isHeadless else { return }
        chooser.cancelIslandChooser()
        model.stop()
        model.setUnavailable(false)
        preferences.forgetFolder()
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    /// Saves the folder's authority and starts watching it. When the authority cannot be saved, the
    /// section shows the unavailable state and nothing is saved or switched on.
    private func folderChosen(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            model.setUnavailable(true)
            return
        }
        model.stop()
        watched = nil
        model.setUnavailable(false)
        preferences.saveFolder(bookmark: bookmark, url: url)
    }

    // MARK: Watching, strip and notice

    /// Starting or stopping the model reports back through `onChange`; those nested calls are folded
    /// into another pass instead of starting a second watcher.
    private func sync() {
        guard !syncing else { resync = true; return }
        syncing = true
        defer { syncing = false }
        repeat {
            resync = false
            reconcile()
        } while resync
    }

    private func reconcile() {
        let visible = running && shown
        let needed = visible && isEnabled && setup == .ready
            && (pageVisible || preferences.showsActivity || preferences.showsNotice)
        if needed, let source = folderSource {
            if watched != source || !model.isWatching {
                watched = source
                model.start(source)
            }
        } else if model.isWatching || watched != nil {
            watched = nil
            model.stop()
        }
        if !visible || !isEnabled { chooser.cancelIslandChooser() }
        publishStrip(visible: visible)
        let shape = (setup, isEmptyFolder)
        if lastShape.map({ $0 != shape }) ?? true {
            lastShape = shape
            environment.invalidate()
        }
    }

    /// Republishes the strip only when liveness or the file name (which sizes the wing) changes; the
    /// percentage inside observes the model directly.
    private func publishStrip(visible: Bool) {
        let name = visible && preferences.showsActivity ? model.active?.name : nil
        guard publishedName != .some(name) else { return }
        publishedName = .some(name)
        guard let name else {
            environment.activities.set(nil, for: .downloads)
            return
        }
        let nameWidth = DownloadStripMetrics.nameWidth(name)
        environment.activities.set(IslandCompactStrip(
            kind: .downloads, wing: DownloadStripFit.defaultWing, minimumRoom: DownloadStripFit.minimumRoom, allowsFooter: true,
            left: AnyView(DownloadStripLeading(model: model)), right: AnyView(DownloadStripTrailing(model: model)),
            companionMark: AnyView(DownloadCompanionMark(model: model)),
            wingForRoom: { room, height in
                DownloadStripFit.wing(room: room, nameWidth: nameWidth,
                                      arrowWidth: DownloadStripMetrics.arrowWidth(stripHeight: height), stripHeight: height)
            }), for: .downloads)
    }

    private func announce(_ completion: DownloadCompletion) {
        guard running, shown, preferences.showsNotice else { return }
        let name = completion.url.lastPathComponent
        environment.notices.post(IslandNotice(
            kind: .downloadComplete,
            style: .text(symbol: "arrow.down.circle.fill", image: nil, title: "Download complete",
                         detail: DownloadNaming.middleTruncated(name, limit: 32)),
            label: "Download complete, \(name)"))
    }
}
