import AppKit
import Combine
import IslandKit
import SwiftUI

/// The shelf: files, images, links and text dropped on the island, held by reference (a path and a
/// bookmark) and handed back by dragging them out. Only image data with no file behind it and files
/// promised by Mail or browsers are copied, into owner-only private storage. The list is saved across
/// launches. With "Files" set to Separate window (or the section hidden) the same shelf opens in its
/// own small window instead. At rest this costs nothing in the island; with the separate window and
/// shake-to-open, one passive mouse monitor. No timers, no file watching.
@MainActor
final class FilesSection: IslandSection {
    let id = IslandSectionID.files
    let controller: ShelfController
    private unowned let environment: IslandEnvironment
    private let preferences: ShelfPreferences
    private let watcher = ShelfDragWatcher()
    private lazy var window = ShelfWindowController(controller: controller)
    private var observers: Set<AnyCancellable> = []
    private var running = false

    init(environment: IslandEnvironment) {
        self.environment = environment
        let preview = environment.isHeadless ? ShelfPreviewData.requested() : nil
        preferences = ShelfPreferences(defaults: environment.isHeadless ? nil : .standard)
        let store = ShelfStore(location: environment.isHeadless ? nil : .standard, preview: preview?.shelf)
        controller = ShelfController(store: store, preferences: preferences,
                                     thumbnails: ShelfThumbnails(offline: environment.isHeadless), environment: environment)
        if let preview {
            controller.status = preview.status
            controller.expanded = Set([preview.pileToExpand].compactMap { $0 })
            let tiles = controller.tiles.map(\.id)
            for id in preview.selection { controller.selection.click(id, extending: false, order: tiles) }
        }
        controller.routesToIsland = { [weak self] in self?.routesToIsland ?? false }
        controller.showWindow = { [weak self] in self?.window.show() }
        environment.fileDrop = { [weak self] urls in self?.canTakeDrops == true && self?.controller.accept(urls) == true }
        environment.pasteboardDrop = { [weak self] pasteboard in self?.canTakeDrops == true && self?.controller.accept(pasteboard) == true }
        environment.revealsDrag = { [weak self] pasteboard, window in self?.revealsDrag(pasteboard, fromWindow: window) ?? false }
    }

    var availability: IslandAvailability { .available }

    func page(_ context: IslandPageContext) -> AnyView {
        AnyView(ShelfPageView(controller: controller, host: .island, width: context.width, height: context.budget,
                              interactive: !context.isPreview))
    }

    func options() -> AnyView? {
        AnyView(ShelfOptionsView(settings: environment.settingsStore, preferences: preferences))
    }

    /// Files opens in the island: the island is on, the section is shown, and Files is not set to
    /// Separate window. Otherwise the shelf window is used.
    var routesToIsland: Bool {
        let settings = environment.settings
        return settings.enabled && settings.filesInIsland && settings.isVisible(.files)
    }

    /// Drops reach the shelf only while the island runs, Files is shown and no capture is being framed.
    private var canTakeDrops: Bool {
        running && environment.settings.isVisible(.files) && !environment.captureControlsActive
    }

    func islandDidStart() {
        guard !running else { return }
        running = true
        controller.store.load()
        environment.settingsStore.$value
            .map { [$0.filesInIsland, $0.isVisible(.files), $0.enabled] }
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncWatcher() } } }
            .store(in: &observers)
        preferences.$shakeToOpen.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncWatcher() } } }
            .store(in: &observers)
        syncWatcher()
    }

    func islandDidStop() {
        guard running else { return }
        running = false
        observers.removeAll()
        watcher.stop()
        window.hide()
        controller.stop()
    }

    func pageDidAppear() { controller.pageAppeared() }
    func pageDidDisappear() { controller.pageDisappeared() }

    /// For the shell's drop target: whether a drag in flight should reveal it. True when the drag
    /// pasteboard holds something the shelf takes and the drag did not start in an app on the
    /// "Never reveal for drags from" list. `window` is the dragged event's window number.
    func revealsDrag(_ pasteboard: NSPasteboard, fromWindow window: Int) -> Bool {
        guard ShelfPasteboard.hasDroppableType(pasteboard) else { return false }
        guard let bundle = ShelfDragWatcher.sourceApp(window: window) else { return true }
        return !preferences.exceptions.contains(bundle)
    }

    /// The shake monitor exists only with Files in a separate window and shake-to-open on. Never in renders.
    private func syncWatcher() {
        guard running, !environment.isHeadless else { return }
        let island = routesToIsland
        watcher.isExcluded = { [weak preferences] bundle in bundle.map { preferences?.exceptions.contains($0) == true } ?? false }
        watcher.onShake = { [weak self] in self?.window.show() }
        if !island && preferences.shakeToOpen { watcher.start() } else { watcher.stop() }
        if island { window.hide() }
    }
}
