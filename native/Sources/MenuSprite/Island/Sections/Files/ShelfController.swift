import AppKit
import Combine
import IslandKit
import UniformTypeIdentifiers

/// Where a shelf view is shown. Drags from the separate window never hold the island open.
enum ShelfHost {
    case island, window
}

/// The line under the strip: a ZIP in progress, its result, or why something could not happen.
enum ShelfStatus: Equatable {
    case zipping(completed: Int, total: Int, cancelling: Bool)
    case saved([URL])
    case cancelled
    case message(String)
}

/// The shelf's working state and every action on it, shared by the island's Files page and the
/// separate shelf window: selection and pile expansion (transient), drops in, drags out, the tile
/// menu, sharing and Create ZIP. The saved list itself lives in `ShelfStore`.
@MainActor
final class ShelfController: ObservableObject {
    let store: ShelfStore
    let preferences: ShelfPreferences
    let thumbnails: ShelfThumbnails
    let environment: IslandEnvironment
    @Published var selection = ShelfSelection()
    @Published var expanded: Set<UUID> = []
    @Published var status: ShelfStatus?

    /// Whether Files opens in the island right now (set by the section).
    var routesToIsland: () -> Bool = { false }
    /// Shows the separate shelf window (set by the section).
    var showWindow: () -> Void = {}

    private var incoming: [ShelfIncomingDrop] = []
    private var drag: ActiveDrag?
    /// Bumped whenever the Files page leaves the screen, so a drag that outlives the island it came
    /// from can never close the island that replaced it.
    private var pageGeneration = 0
    private var job: ShelfArchiveJob?
    /// The island page and the shelf window currently on screen.
    private var surfaces = 0
    private var observers: Set<AnyCancellable> = []

    private struct ActiveDrag {
        var ids: Set<UUID>
        var host: ShelfHost
        var generation: Int
    }

    init(store: ShelfStore, preferences: ShelfPreferences, thumbnails: ShelfThumbnails, environment: IslandEnvironment) {
        self.store = store
        self.preferences = preferences
        self.thumbnails = thumbnails
        self.environment = environment
        // Views observe the controller; the list they draw lives in the store.
        store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observers)
        store.$shelf.dropFirst().sink { [weak self] shelf in
            guard let self else { return }
            selection.prune(to: shelf.tiles(expanded: expanded).map(\.id))
            expanded.formIntersection(Set(shelf.tiles(expanded: expanded).filter(\.item.isPile).map(\.id)))
        }.store(in: &observers)
    }

    var tiles: [ShelfTile] { store.shelf.tiles(expanded: expanded) }
    var isZipping: Bool { if case .zipping = status { return true }; return false }

    // MARK: Lifecycle

    func pageAppeared() {
        surfaces += 1
        store.load()
        if thumbnails.offline { thumbnails.preload(store.shelf.items.flatMap(\.leaves).compactMap { $0.file?.path }) }
    }

    func pageDisappeared() {
        pageGeneration += 1
        surfaces = max(0, surfaces - 1)
        guard surfaces == 0 else { return }
        thumbnails.purge()
        selection.clear()
        expanded = []
        if case .zipping = status {} else { status = nil }
    }

    /// The island stopped: stop the archiver at once, drop deliveries still arriving, save and let go.
    func stop() {
        surfaces = 1
        pageDisappeared()
        job?.stopNow()
        job = nil
        status = nil
        incoming.forEach { $0.cancel() }
        incoming = []
        store.unload()
    }

    // MARK: Drops in

    /// A drop on the island or the shelf window. Returns whether it was accepted; late parts (image
    /// data, promised files) join the shelf when they arrive, in drop order.
    func accept(_ pasteboard: NSPasteboard) -> Bool {
        store.load()
        let left = Shelf.capacity - store.shelf.leafCount
        let result = ShelfIncomingDrop.start(pasteboard, location: store.location, capacityLeft: left) { [weak self] contents, failures in
            self?.deliver(contents, failures: failures)
        }
        if result.full { status = .message("The shelf is full. Remove something first.") }
        if let drop = result.drop { incoming.append(drop) }
        return result.accepted
    }

    /// Files handed over by URL only.
    func accept(_ urls: [URL]) -> Bool {
        var seen = Set<String>()
        let files = urls.filter { $0.isFileURL && seen.insert($0.standardizedFileURL.path).inserted }
        guard !files.isEmpty else { return false }
        store.load()
        guard store.shelf.canAccept(files.count) else {
            status = .message("The shelf is full. Remove something first.")
            return false
        }
        deliver(files.map { ShelfPasteboard.file($0) }, failures: 0)
        return true
    }

    private func deliver(_ contents: [ShelfContent], failures: Int) {
        incoming.removeAll(where: \.finished)
        store.whenLoaded { [weak self] in
            guard let self else { return }
            switch store.add(contents) {
            case .full: status = .message("The shelf is full. Remove something first.")
            case .empty where failures > 0, .added where failures > 0:
                status = .message(failures == 1 ? "Couldn't add an attachment." : "Couldn't add \(failures) attachments.")
            case .added, .empty:
                if case .message = status { status = nil }
            }
        }
    }

    // MARK: Selection

    /// The tiles an action applies to: the whole selection when the tile is part of it.
    func targets(for id: UUID) -> Set<UUID> { selection.contains(id) ? selection.selected : [id] }

    func click(_ id: UUID, extending: Bool) {
        selection.click(id, extending: extending, order: tiles.map(\.id))
    }

    func toggleExpanded(_ id: UUID) {
        guard store.shelf.item(id)?.isPile == true else { return }
        if expanded.remove(id) == nil { expanded.insert(id) }
    }

    func selectAll() { selection.selectAll(tiles.map(\.id)) }
    func clearSelection() { selection.clear() }

    // MARK: Actions

    func remove(_ ids: Set<UUID>) {
        store.mutate { $0.remove(ids) }
    }

    func removeSelected() {
        remove(selection.selected)
        selection.clear()
    }

    func clearAll() {
        store.mutate { $0.clearAll() }
        selection.clear()
    }

    func setPinned(_ ids: Set<UUID>, _ pinned: Bool) { store.mutate { $0.setPinned(ids, pinned) } }

    func isPinned(_ ids: Set<UUID>) -> Bool { ids.allSatisfy { store.shelf.item($0)?.pinned == true } }

    /// File leaves that exist right now (moved files followed, gone ones removed).
    func fileURLs(_ ids: Set<UUID>) -> [URL] {
        let hadFiles = hasFiles(ids)
        let urls = store.usableLeaves(of: ids).compactMap { $0.file?.url }
        if hadFiles, urls.isEmpty { status = .message("The file no longer exists.") }
        return urls
    }

    func hasFiles(_ ids: Set<UUID>) -> Bool { store.shelf.leaves(of: ids).contains { $0.file != nil } }

    /// What Share and Open act on: the selection, or everything when nothing is selected.
    var actionTargets: Set<UUID> { selection.isEmpty ? Set(store.shelf.items.map(\.id)) : selection.selected }

    func open(_ ids: Set<UUID>) {
        for leaf in store.usableLeaves(of: ids) {
            switch leaf.content {
            case .file(let file): NSWorkspace.shared.open(file.url)
            case .link(let url): NSWorkspace.shared.open(url)
            default: break
            }
        }
    }

    func open(_ ids: Set<UUID>, with app: URL) {
        let urls = fileURLs(ids)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Apps that can open every one of the files, by name, at most 40.
    func appsOpeningAll(_ ids: Set<UUID>) -> [URL] {
        let urls = store.shelf.leaves(of: ids).compactMap { $0.file?.url }
        guard let first = urls.first else { return [] }
        var common = Set(NSWorkspace.shared.urlsForApplications(toOpen: first))
        for url in urls.dropFirst() { common.formIntersection(NSWorkspace.shared.urlsForApplications(toOpen: url)) }
        return common.sorted { FileManager.default.displayName(atPath: $0.path).localizedStandardCompare(FileManager.default.displayName(atPath: $1.path)) == .orderedAscending }
            .prefix(40).map { $0 }
    }

    func reveal(_ ids: Set<UUID>) {
        let urls = fileURLs(ids)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    /// The system share picker (AirDrop, Mail, Messages…) beside `view`, for the files among the
    /// tiles. The island stays open while it is up.
    func share(_ ids: Set<UUID>, from view: NSView, host: ShelfHost) {
        let urls = fileURLs(ids)
        guard !urls.isEmpty else { return }
        ShelfSharing.show(urls, from: view, hold: host == .island ? environment.actions.holdOpen : nil)
    }

    // MARK: Drags out

    /// Starts a drag of the tile (or the selection it belongs to). Missing files never join; if
    /// nothing is left the drag does not start.
    func dragItems(for id: UUID) -> [ShelfItem] {
        let ids = targets(for: id)
        let leaves = store.usableLeaves(of: ids)
        if leaves.isEmpty { status = .message("The file no longer exists.") }
        return leaves
    }

    func dragBegan(_ id: UUID, host: ShelfHost) {
        if let drag, drag.host == .island { environment.actions.holdOpen(false) }
        drag = ActiveDrag(ids: targets(for: id), host: host, generation: pageGeneration)
        if host == .island { environment.actions.holdOpen(true) }
    }

    func dragOperations(withinApp: Bool) -> NSDragOperation {
        let pinned = drag.map { store.shelf.containsPinned($0.ids) } ?? true
        let allowed = ShelfDragRules.operations(withinApp: withinApp, removeAfterDrop: preferences.removeAfterDrop, containsPinned: pinned)
        var operations: NSDragOperation = []
        if allowed.contains(.copy) { operations.insert(.copy) }
        if allowed.contains(.move) { operations.insert(.move) }
        return operations
    }

    func dragEnded(accepted: Bool) {
        guard let drag else { return }
        self.drag = nil
        if ShelfDragRules.removesAfterDrop(accepted: accepted, removeAfterDrop: preferences.removeAfterDrop) {
            store.mutate { $0.removeAfterDrag(drag.ids) }
        }
        guard drag.host == .island else { return }
        environment.actions.holdOpen(false)
        let sameIsland = drag.generation == pageGeneration && environment.isOpen && environment.destination == .section(.files)
        if ShelfDragRules.collapsesAfterDrop(accepted: accepted, merged: false, closeAfterDrop: preferences.closeAfterDrop,
                                             pinned: environment.isPinned, sameIsland: sameIsland) {
            environment.close()
        }
    }

    // MARK: Create ZIP

    /// Each chosen file becomes its own ZIP: one file asks where to save it, several ask for a
    /// folder. The dialog opens above whatever shows the shelf, and the island stays open meanwhile.
    func createZip(_ ids: Set<UUID>, from view: NSView?, host: ShelfHost) {
        guard !isZipping else { return }
        let inputs = fileURLs(ids)
        guard !inputs.isEmpty else { return }
        let hint = "Each selected item is saved as a separate ZIP. Originals stay unchanged."
        let panel: NSSavePanel
        if inputs.count == 1 {
            panel = NSSavePanel()
            panel.allowedContentTypes = [.zip]
            let folder = inputs[0].deletingLastPathComponent()
            panel.nameFieldStringValue = ShelfArchiveNaming.unique(ShelfArchiveNaming.name(for: inputs[0])) {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
        } else {
            let chooser = NSOpenPanel()
            chooser.canChooseFiles = false
            chooser.canChooseDirectories = true
            chooser.canCreateDirectories = true
            chooser.allowsMultipleSelection = false
            chooser.prompt = "Save ZIPs"
            panel = chooser
        }
        panel.directoryURL = inputs[0].deletingLastPathComponent()
        panel.message = hint
        let window = view?.window
        ShelfDialogs.run(panel, above: window, hold: host == .island ? environment.actions.holdOpen : nil,
                         refocus: { [weak self] in self?.environment.isOpen == true && host == .island }) { [weak self] chosen in
            guard let self, let chosen else { return }
            let destinations = inputs.count == 1 ? [chosen]
                : ShelfArchiveNaming.destinations(for: inputs, in: chosen) { FileManager.default.fileExists(atPath: $0.path) }
            startZip(inputs, destinations: destinations, host: host)
        }
    }

    private func startZip(_ inputs: [URL], destinations: [URL], host: ShelfHost) {
        if let refusal = ShelfArchiveCheck.refusal(inputs: inputs, destinations: destinations) {
            status = .message(refusal.message)
            return
        }
        let job = ShelfArchiveJob(inputs: inputs, destinations: destinations)
        self.job = job
        status = .zipping(completed: 0, total: inputs.count, cancelling: false)
        job.start(progress: { @Sendable [weak self] completed, total in
            Task { @MainActor in
                guard let self, self.job === job, case .zipping(_, _, let cancelling) = self.status else { return }
                self.status = .zipping(completed: completed, total: total, cancelling: cancelling)
            }
        }, completion: { @Sendable [weak self] outcome in
            Task { @MainActor in self?.zipFinished(outcome, job: job, host: host) }
        })
    }

    private func zipFinished(_ outcome: ShelfArchiveJob.Outcome, job finished: ShelfArchiveJob, host: ShelfHost) {
        guard job === finished else { return }
        job = nil
        let produced: [URL]
        switch outcome {
        case .finished(let urls):
            produced = urls
            status = .saved(urls)
        case .cancelled(let urls):
            produced = urls
            status = .cancelled
        case .failed(let message, let urls):
            produced = urls
            status = .message(message)
        }
        guard !produced.isEmpty else { return }
        store.whenLoaded { [weak self] in
            guard let self else { return }
            store.add(produced.map { ShelfPasteboard.file($0) })
            if host == .island, routesToIsland() { environment.open(.files) } else if host == .window { showWindow() }
        }
    }

    func cancelZip() {
        guard let job, case .zipping(let completed, let total, false) = status else { return }
        status = .zipping(completed: completed, total: total, cancelling: true)
        job.cancel()
    }

    func showSaved() {
        guard case .saved(let urls) = status else { return }
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(existing) }
    }
}

/// Save panels and folder choosers opened from the shelf: their own window, one level above the
/// island (never a sheet, which would reshape the borderless island), not hidden when the app
/// deactivates. Keyboard focus goes back to the island afterwards only if it is still open.
@MainActor
enum ShelfDialogs {
    static func run(_ panel: NSSavePanel, above window: NSWindow?, hold: ((Bool) -> Void)?, refocus: @escaping () -> Bool,
                    completion: @escaping @MainActor (URL?) -> Void) {
        hold?(true)
        panel.hidesOnDeactivate = false
        NSApp.activate()
        panel.begin { response in
            MainActor.assumeIsolated {
                let url = response == .OK ? panel.url : nil
                if let window, refocus() { window.makeKey() }
                hold?(false)
                completion(url)
            }
        }
        panel.level = NSWindow.Level(rawValue: (window?.level ?? .statusBar).rawValue + 1)
        panel.makeKeyAndOrderFront(nil)
    }
}

/// The system share picker, kept alive until it closes, holding the island open meanwhile.
@MainActor
final class ShelfSharing: NSObject, NSSharingServicePickerDelegate {
    private static var current: ShelfSharing?
    private var hold: ((Bool) -> Void)?

    static func show(_ items: [Any], from view: NSView, hold: ((Bool) -> Void)?) {
        current?.finish()
        let sharing = ShelfSharing()
        sharing.hold = hold
        current = sharing
        hold?(true)
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = sharing
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        Task { @MainActor in self.finish() }
    }

    private func finish() {
        hold?(false)
        hold = nil
        if Self.current === self { Self.current = nil }
    }
}
