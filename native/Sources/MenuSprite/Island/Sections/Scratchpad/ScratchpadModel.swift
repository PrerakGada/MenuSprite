import AppKit
import IslandKit

/// The scratchpad's document and its file. Loads only when the island page or the floating pad
/// opens (never at launch), applies "Clear on its own" then, saves 0.8 s after the last edit and at
/// once on every tab action or when a surface closes, and lets go of the text when nothing shows it
/// and everything is saved. Every save goes through `ScratchpadPersistence`, so nothing is written
/// before a successful load and a file that could not be read is never overwritten.
@MainActor
final class ScratchpadModel: ObservableObject {
    enum LoadState: Equatable { case idle, loading, ready, failed }

    @Published private(set) var document: ScratchpadDocument?
    @Published private(set) var state: LoadState = .idle
    /// A write failed; the notes are only in memory until a later write succeeds.
    @Published private(set) var saveWarning = false
    @Published var previewing = false
    @Published private(set) var copied = false
    /// A short line under the toolbar after an export failed.
    @Published private(set) var message: String?
    /// Bumped to ask the visible editor to take the caret (at the end of the text).
    @Published private(set) var focusSerial = 0
    /// Bumped to ask the visible editor to clear itself, so one ⌘Z restores everything.
    @Published private(set) var clearSerial = 0
    /// A rename, close or export dialog is up: the island and the pad stay open.
    @Published private(set) var isDialogUp = false

    let preferences: ScratchpadPreferences
    private let fileURL: URL?
    private var persistence = ScratchpadPersistence()
    private var saveTask: Task<Void, Never>?
    private var copiedTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var writing: ScratchpadDocument?
    private var surfaces = 0
    private let io = DispatchQueue(label: "in.prerakgada.MenuSprite.scratchpad", qos: .utility)

    /// Set by the section: hold the island open while a dialog is up, and hand the keyboard back after.
    var holdOpen: (Bool) -> Void = { _ in }
    var refocus: () -> Void = {}

    static var standardFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuSprite/Scratchpad/scratchpad.json")
    }

    /// `fileURL` nil means a render: the given document is shown and nothing touches the disk.
    init(preferences: ScratchpadPreferences, fileURL: URL?, preview: ScratchpadDocument? = nil) {
        self.preferences = preferences
        self.fileURL = fileURL
        if let preview {
            document = preview
            state = .ready
        }
    }

    /// Renders only: show a failed load or a failed write without touching the disk.
    func showPreviewState(_ preview: ScratchpadPreviewData.State) {
        guard fileURL == nil else { return }
        switch preview {
        case .failed: state = .failed
        case .warning: saveWarning = true
        case .notes, .formatted, .empty: break
        }
    }

    var selected: ScratchpadPad? { document?.selected }
    var selectedIsEmpty: Bool { selected?.text.isEmpty ?? true }

    // MARK: Surfaces

    /// The island page or the floating pad opened.
    func surfaceAppeared() {
        surfaces += 1
        switch state {
        case .idle, .failed: load()
        case .loading: break
        case .ready:
            applyRetention()
            focusSerial += 1
        }
    }

    /// A surface just got the keyboard: put the caret back at the end of the text.
    func requestFocus() { focusSerial += 1 }

    func surfaceDisappeared() {
        surfaces = max(0, surfaces - 1)
        previewing = false
        save()
    }

    /// The island turned off or the app is quitting: write now, on this thread, so nothing is lost.
    func flushNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let fileURL, let document, persistence.shouldWrite(document) else { return }
        let ok = io.sync { (try? IslandPrivateFile.write(ScratchpadPersistence.encode(document), to: fileURL)) != nil }
        persistence.wrote(document, success: ok)
        saveWarning = persistence.saveFailed
    }

    private func load() {
        guard let fileURL else { return }
        state = .loading
        io.async { [weak self] in
            let outcome = ScratchpadPersistence.outcome(of: IslandPrivateFile.read(fileURL))
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.loaded(outcome) } }
        }
    }

    private func loaded(_ outcome: ScratchpadPersistence.LoadOutcome) {
        guard let loaded = persistence.loaded(outcome) else {
            document = nil
            state = .failed
            return
        }
        document = loaded
        state = .ready
        applyRetention()
        focusSerial += 1
        releaseIfIdle()
    }

    private func applyRetention() {
        guard var document else { return }
        guard !document.applyRetention(preferences.retention, now: Date()).isEmpty else { return }
        self.document = document
        save()
    }

    // MARK: Editing

    /// Every edit of the selected pad: its text and edit time, then a save 0.8 s after the last edit.
    func setText(_ text: String) {
        guard var document else { return }
        document.setText(text, of: document.selectedID, at: Date())
        guard document != self.document else { return }
        self.document = document
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Writes the document if it changed; the completion says whether the notes are on disk.
    func save(completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        saveTask?.cancel()
        saveTask = nil
        guard let fileURL, let document, persistence.shouldWrite(document), document != writing else {
            completion?(!saveWarning)
            releaseIfIdle()
            return
        }
        writing = document
        io.async { [weak self] in
            let ok = (try? IslandPrivateFile.write(ScratchpadPersistence.encode(document), to: fileURL)) != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.writing == document { self.writing = nil }
                    self.persistence.wrote(document, success: ok)
                    self.saveWarning = self.persistence.saveFailed
                    completion?(ok)
                    self.releaseIfIdle()
                }
            }
        }
    }

    /// A tab action: applied, then saved at once; when that write fails the notes are put back as
    /// they were (unless something else changed meanwhile).
    private func commit(_ change: (inout ScratchpadDocument) -> Void) {
        guard let before = document else { return }
        var after = before
        change(&after)
        guard after != before else { return }
        document = after
        focusSerial += 1
        save { [weak self] ok in
            guard let self, !ok, self.document == after else { return }
            self.document = before
        }
    }

    // MARK: Tabs

    func newPad() {
        guard document?.canAddPad == true else { return }
        previewing = false
        commit { $0.addPad() }
    }

    func select(_ id: UUID) {
        guard var document, document.selectedID != id else { return }
        document.select(id)
        self.document = document
        previewing = false
        focusSerial += 1
        save()
    }

    /// Closes a pad, asking first when it has text. The last pad never closes.
    func close(_ id: UUID) {
        guard let document, document.canClosePad, let pad = document.pads.first(where: { $0.id == id }) else { return }
        if document.needsConfirmation(toClose: id) {
            let confirmed = withDialog {
                IslandToolDialogs.confirm(title: "Close scratchpad", message: "Delete “\(pad.name)” and everything in it?",
                                          action: "Close scratchpad")
            }
            guard confirmed else { return }
        }
        commit { $0.close(id) }
    }

    func rename(_ id: UUID) {
        guard let pad = document?.pads.first(where: { $0.id == id }) else { return }
        guard let name = withDialog({ IslandToolDialogs.askForName(title: "Rename scratchpad", current: pad.name) }) else { return }
        commit { $0.rename(id, to: name) }
    }

    // MARK: Content

    func togglePreview() {
        guard !selectedIsEmpty || previewing else { return }
        previewing.toggle()
        if !previewing { focusSerial += 1 }
    }

    /// Asks the editor to clear, so the change is one undoable edit; it then saves at once.
    func clear() {
        guard !selectedIsEmpty else { return }
        clearSerial += 1
    }

    /// The editor finished clearing.
    func didClear() {
        previewing = false
        save()
        focusSerial += 1
    }

    func copyAll() {
        guard let text = selected?.text, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { NSSound.beep(); return }
        copied = true
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }

    /// Saves the selected pad as a text file, as it is when Save is confirmed. One export at a time.
    func export() {
        guard !isDialogUp, let pad = selected, !pad.text.isEmpty else { return }
        isDialogUp = true
        holdOpen(true)
        IslandToolDialogs.save(suggestedName: ScratchpadDocument.exportName(for: pad.name, on: Date())) { [weak self] url in
            guard let self else { return }
            self.isDialogUp = false
            self.holdOpen(false)
            self.refocus()
            guard let url else { return }
            guard let text = self.document?.pads.first(where: { $0.id == pad.id })?.text else {
                self.show("The file could not be saved")
                return
            }
            self.io.async { [weak self] in
                let ok = (try? Data(text.utf8).write(to: url, options: .atomic)) != nil
                guard !ok else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.show("The file could not be saved") } }
            }
        }
    }

    private func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    private func withDialog<T>(_ body: () -> T) -> T {
        isDialogUp = true
        holdOpen(true)
        defer {
            isDialogUp = false
            holdOpen(false)
            refocus()
        }
        return body()
    }

    /// Nothing shows the notes and they are safely on disk: let go of the text.
    private func releaseIfIdle() {
        guard fileURL != nil, surfaces == 0, state == .ready, !isDialogUp, saveTask == nil, writing == nil,
              !saveWarning, let current = document, current == persistence.lastSaved else { return }
        document = nil
        state = .idle
        persistence = ScratchpadPersistence()
    }
}
