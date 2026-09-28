import Combine
import IslandKit
import SwiftUI

/// Clipboard history in the island: the searchable Clipboard page, the history window for
/// "Separate window", the "Copied" notice and an optional global shortcut. History is off until the
/// person turns it on; until then, and while macOS would ask before MenuSprite reads other apps'
/// copies, nothing watches the pasteboard. The history itself lives in `ClipboardHistoryModel`.
@MainActor
final class ClipboardSection: IslandSection {
    let id = IslandSectionID.clipboard
    let model: ClipboardHistoryModel
    let preferences: ClipboardPreferences
    private unowned let environment: IslandEnvironment
    private lazy var window = ClipboardWindow(model: model, preferences: preferences) { [weak self] in
        self?.environment.showSettings(.clipboard)
    }
    private lazy var shortcut = IslandToolShortcut(name: "island.clipboard") { [weak self] in self?.shortcutPressed() }
    private var shortcutObservation: AnyCancellable?
    /// How long the island takes to collapse before the history window opens in its place.
    private static let collapseDelay = 0.32

    init(environment: IslandEnvironment) {
        self.environment = environment
        if environment.isHeadless {
            let preview = ClipboardPreviewData.requested()
            preferences = ClipboardPreferences(defaults: nil)
            preferences.keepHistory = preview.keepHistory
            model = ClipboardHistoryModel(preferences: preferences, store: nil, preview: preview)
        } else {
            preferences = ClipboardPreferences()
            model = ClipboardHistoryModel(preferences: preferences, store: ClipboardDiskStore(folder: ClipboardDiskStore.standardFolder))
        }
        environment.register(indicator: .clipboard) { [weak self] in self?.indicatorAvailability ?? .notBuilt }
        model.onCaptured = { [weak self] in self?.postNotice() }
        model.onPasteFallback = { [weak self] in self?.postPasteFallback() }
        model.dependenciesChanged = { [weak environment] in environment?.invalidate() }
    }

    var availability: IslandAvailability { .available }

    func page(_ context: IslandPageContext) -> AnyView {
        AnyView(ClipboardIslandPage(environment: environment, model: model, preferences: preferences, context: context,
                                    openWindow: { [weak self] in self?.collapseThenOpenWindow() }))
    }

    func options() -> AnyView? {
        AnyView(ClipboardOptionsView(model: model, preferences: preferences, settings: environment.settingsStore, shortcut: shortcut))
    }

    func islandDidStart() {
        guard !environment.isHeadless else { return }
        model.islandRunning = true
        model.syncCapture()
        shortcut.activate(preferences.shortcut)
        shortcutObservation = preferences.$shortcut.dropFirst().sink { [weak self] value in self?.shortcut.apply(value) }
    }

    func islandDidStop() {
        model.islandRunning = false
        model.syncCapture()
        shortcutObservation = nil
        shortcut.deactivate()
        window.close()
    }

    func pageDidAppear() { model.surfaceAppeared() }
    func pageDidDisappear() { model.surfaceDisappeared() }

    // MARK: Indicator

    /// "Notify when something is copied" needs history on, macOS letting MenuSprite read copies, and
    /// the section shown, so a hidden section never leaks the notice.
    private var indicatorAvailability: IslandAvailability {
        let blocker = ClipboardIndicatorBlocker.check(historyOn: preferences.keepHistory,
                                                      readingAllowed: model.access?.allowsAutomaticReads ?? true,
                                                      sectionVisible: environment.settings.isVisible(.clipboard))
        let fix: @MainActor () -> Void = { [weak environment] in environment?.actions.openSettings(.clipboard) }
        switch blocker {
        case nil: return .available
        case .historyOff: return .unavailable("Enable “Keep clipboard history” in its settings.", fixTitle: "Open", fix: fix)
        case .pasteboardAccess: return .unavailable("Allow MenuSprite in Paste from Other Apps.", fixTitle: "Open", fix: fix)
        case .sectionHidden: return .unavailable("Show “Clipboard” on the Content tab.", fixTitle: "Show", fix: fix)
        }
    }

    /// "Copied" · "Clipboard" for 2.5 s. The copied content is never shown.
    private func postNotice() {
        guard environment.wants(.clipboard) else { return }
        environment.notices.post(IslandNotice(kind: .clipboard,
                                              style: .text(symbol: "doc.on.clipboard", image: nil, title: "Copied", detail: "Clipboard"),
                                              label: "Copied, Clipboard"))
    }

    /// A paste could not reach its app (it never came to the front in time, or quit): the entry is
    /// on the pasteboard, and the collapsed island says to press ⌘V. A reply to the person's own
    /// action, so it does not wait on "Notify when something is copied"; it never shows the content.
    private func postPasteFallback() {
        environment.notices.post(IslandNotice(kind: .clipboard,
                                              style: .text(symbol: "doc.on.clipboard", image: nil, title: "Copied", detail: "Paste with ⌘V"),
                                              label: "Copied, paste with Command V"))
    }

    // MARK: Opening

    private var pageShowing: Bool { environment.isOpen && environment.destination == .section(.clipboard) }

    /// Toggles the island page when that is where Clipboard opens; otherwise the history window.
    private func shortcutPressed() {
        switch ClipboardRouting.shortcut(environment.settings, islandAccepts: environment.isRunning, pageShowing: pageShowing) {
        case .openPage:
            environment.open(.clipboard)
            if !pageShowing { window.toggle() }
        case .closeIsland:
            environment.close()
        case .toggleWindow:
            window.toggle()
        }
    }

    private func collapseThenOpenWindow() {
        environment.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDelay) { [weak self] in
            MainActor.assumeIsolated { self?.window.show() }
        }
    }
}

/// The page inside the island: keyboard badges follow the island's key state; a paste collapses it.
private struct ClipboardIslandPage: View {
    @ObservedObject var environment: IslandEnvironment
    let model: ClipboardHistoryModel
    let preferences: ClipboardPreferences
    let context: IslandPageContext
    let openWindow: () -> Void

    var body: some View {
        ClipboardPageView(model: model, preferences: preferences,
                          surface: ClipboardSurface(isKey: environment.isKey && !context.isPreview, isPreview: context.isPreview,
                                                    owns: { $0 is IslandPanel },
                                                    collapse: { [weak environment] in environment?.close() },
                                                    openWindow: openWindow,
                                                    openSettings: { [weak environment] in environment?.actions.openSettings(.clipboard) }))
            .frame(width: context.width, height: context.budget, alignment: .top)
    }
}
