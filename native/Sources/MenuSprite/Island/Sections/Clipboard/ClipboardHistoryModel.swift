import AppKit
import Combine
import IslandKit

/// Clipboard history: the entries, the search over them, their file, the pasteboard watcher
/// (`ClipboardHistoryModel+Capture`) and writing an entry back (`+Paste`). The history is read from
/// disk only when capture starts or a surface opens, and let go again when neither needs it.
@MainActor
final class ClipboardHistoryModel: ObservableObject {
    enum LoadState: Equatable { case idle, loading, ready, failed }

    let preferences: ClipboardPreferences
    let thumbnails = ClipboardThumbnails()
    /// Nil in renders: nothing touches the disk.
    let store: ClipboardDiskStore?
    let pasteboardName: NSPasteboard.Name

    @Published private(set) var entries: [ClipboardEntry] = []
    /// The visible list: the search and the pinned filter applied.
    @Published private(set) var results: [ClipboardEntry] = []
    @Published var query = "" { didSet { if query != oldValue { refilter(restart: true) } } }
    @Published var pinnedOnly = false { didSet { if pinnedOnly != oldValue { refilter(restart: true) } } }
    @Published var highlight = ClipboardHighlight()
    @Published private(set) var load: LoadState = .idle
    /// macOS's answer about reading other apps' copies; nil until first checked.
    @Published var access: ClipboardReadAccess?
    @Published var accessibilityTrusted = false
    /// The entry whose Copy button shows the tick (1.6 s).
    @Published var copiedID: UUID?
    /// A short line under the search row ("Copied. …", failures), cleared after a few seconds.
    @Published private(set) var message: String?
    @Published private(set) var saveFailed = false

    /// Set by the section: a new copy was kept (the "Copied" notice), and something the indicator
    /// depends on changed.
    var onCaptured: () -> Void = {}
    var dependenciesChanged: () -> Void = {}
    /// Set by the section: a paste could not be handed to its app, so the entry was only copied.
    /// The surface has already collapsed, so the island says so.
    var onPasteFallback: () -> Void = {}

    var history = ClipboardHistory()
    private var index = ClipboardSearchIndex()
    let isPreview: Bool
    private var surfaces = 0
    private var savePending = false
    private var messageTask: Task<Void, Never>?
    var copiedTask: Task<Void, Never>?
    private var observations: Set<AnyCancellable> = []

    // Capture state, used by the capture extension.
    var gate = ClipboardCaptureGate()
    var timer: Timer?
    var islandRunning = false
    var frontmostSincePoll: Set<String> = []
    var activationObserver: NSObjectProtocol?
    var accessObserver: NSObjectProtocol?

    // Paste state, used by the paste extension.
    var pasteTarget: NSRunningApplication?
    var targetObserver: NSObjectProtocol?
    var writing = false
    /// A paste waiting for its app to come to the front, and the short poll that checks (≤ 1 s).
    var handoff: ClipboardPasteHandoff?
    var handoffTimer: Timer?

    init(preferences: ClipboardPreferences, store: ClipboardDiskStore?, pasteboardName: NSPasteboard.Name = .general,
         preview: ClipboardPreviewData? = nil) {
        self.preferences = preferences
        self.store = store
        self.pasteboardName = pasteboardName
        isPreview = preview != nil
        if let preview {
            history = ClipboardHistory(entries: preview.entries)
            access = preview.access
            accessibilityTrusted = true
            load = preview.failed ? .failed : .ready
            publish()
            query = preview.query
        }
        preferences.$keepHistory.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.syncCapture()
            self?.dependenciesChanged()
        }.store(in: &observations)
        preferences.$ignoredApps.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.syncIgnoreObserver()
        }.store(in: &observations)
        preferences.$limit.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] limit in
            guard let self, self.load == .ready else { return }
            self.history.trim(limit: limit)
            self.changed()
        }.store(in: &observations)
    }

    var hasQuery: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: Surfaces

    /// The island page or the history window opened.
    func surfaceAppeared() {
        surfaces += 1
        guard !isPreview else { return }
        rememberFrontmost(NSWorkspace.shared.frontmostApplication)
        startTargetWatch()
        accessibilityTrusted = AXIsProcessTrusted()
        ensureLoaded()
        refreshAccess()
    }

    func surfaceDisappeared() {
        surfaces = max(0, surfaces - 1)
        guard surfaces == 0 else { return }
        stopTargetWatch()
        query = ""
        pinnedOnly = false
        highlight = ClipboardHighlight()
        releaseIfIdle()
    }

    // MARK: Loading and saving

    func ensureLoaded() {
        guard let store, load == .idle || load == .failed else { return }
        load = .loading
        store.load { [weak self] result in self?.loaded(result) }
    }

    private func loaded(_ result: ClipboardDiskStore.LoadResult) {
        switch result {
        case .loaded(let saved):
            history = ClipboardHistory(entries: saved)
            history.trim(limit: preferences.limit)
            load = .ready
        case .missing:
            history = ClipboardHistory()
            load = .ready
        case .failed:
            history = ClipboardHistory()
            load = .failed
        }
        publish()
        syncCapture()
    }

    /// The history changed: publish it and save once this run-loop turn ends.
    func changed() {
        publish()
        guard store != nil, !savePending else { return }
        savePending = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
    }

    private func saveNow() {
        savePending = false
        guard let store, load == .ready else { return }
        let snapshot = history.entries
        store.save(snapshot) { [weak self] result in
            guard let self else { return }
            switch result {
            case .saved(let kept):
                self.saveFailed = false
                if kept.count < snapshot.count {
                    let keptIDs = Set(kept.map(\.id))
                    for entry in snapshot where !keptIDs.contains(entry.id) { self.history.delete(entry.id) }
                    self.publish()
                }
            case .failed:
                self.saveFailed = true
            }
            self.releaseIfIdle()
        }
    }

    /// Nothing captures and nothing shows the history: let go of it (it is on disk).
    func releaseIfIdle() {
        guard !isPreview, timer == nil, surfaces == 0, !savePending, !saveFailed, load == .ready else { return }
        history = ClipboardHistory()
        index = ClipboardSearchIndex()
        entries = []
        results = []
        thumbnails.removeAll()
        load = .idle
    }

    private func publish() {
        entries = history.entries
        index.update(entries)
        refilter(restart: false)
    }

    private func refilter(restart: Bool) {
        results = index.results(query, pinnedOnly: pinnedOnly)
        let ids = results.map(\.id)
        if restart { highlight.restart(results: ids, hasQuery: hasQuery) } else { highlight.reconcile(results: ids, hasQuery: hasQuery) }
    }

    // MARK: Editing

    func togglePin(_ id: UUID) {
        guard let entry = history.entry(id) else { return }
        if entry.isPinned {
            history.unpin(id)
        } else if !history.pin(id, at: Date()) {
            NSSound.beep()
            show("This item is too large to pin.")
            return
        }
        changed()
    }

    func canMove(_ id: UUID, up: Bool) -> Bool { !hasQuery && history.canMove(id, up: up) }

    func move(_ id: UUID, up: Bool) {
        guard canMove(id, up: up) else { return }
        history.move(id, up: up)
        changed()
    }

    func delete(_ id: UUID) {
        history.delete(id)
        changed()
    }

    /// "Clear recent": every unpinned entry, no confirmation.
    func clearRecent() {
        history.clearRecent()
        copiedID = nil
        changed()
    }

    /// "Clear history" in Settings: everything, pinned included, and the files on disk. Also the way
    /// out of a history file that could not be read.
    func clearAll() {
        history.clearAll()
        thumbnails.removeAll()
        copiedID = nil
        publish()
        guard let store else { return }
        store.erase { [weak self] _ in
            guard let self else { return }
            if self.load == .failed { self.load = .idle }
            self.syncCapture()
            if self.surfaces > 0 { self.ensureLoaded() }
        }
    }

    func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}
