import Combine
import IslandKit
import SwiftUI

/// Quick notes in tabs that save by themselves: the island's Scratchpad page, the floating pad for
/// "Separate window", the Scratchpad tile on the Controls page and an optional global shortcut. The
/// notes are read only when one of those opens; the document and its file rules live in
/// `ScratchpadModel`.
@MainActor
final class ScratchpadSection: IslandSection {
    let id = IslandSectionID.scratchpad
    let model: ScratchpadModel
    let preferences: ScratchpadPreferences
    private unowned let environment: IslandEnvironment
    private let control: IslandControlModel
    private let pad = FloatingToolWindow(title: "Scratchpad", size: CGSize(width: 380, height: 300),
                                         minimum: CGSize(width: 280, height: 220), resizable: true)
    private lazy var shortcut = IslandToolShortcut(name: "island.scratchpad") { [weak self] in self?.shortcutPressed() }
    private var shortcutObservation: AnyCancellable?
    /// How long the island takes to collapse before the floating pad opens in its place.
    private static let collapseDelay = 0.32

    init(environment: IslandEnvironment) {
        self.environment = environment
        if environment.isHeadless {
            let state = ScratchpadPreviewData.requested()
            preferences = ScratchpadPreferences(defaults: nil)
            model = ScratchpadModel(preferences: preferences, fileURL: nil, preview: ScratchpadPreviewData.document(for: state))
            model.previewing = state == .formatted
            model.showPreviewState(state)
        } else {
            preferences = ScratchpadPreferences()
            model = ScratchpadModel(preferences: preferences, fileURL: ScratchpadModel.standardFile)
        }
        control = IslandControlModel(.scratchpad) {}
        control.perform = { [weak self] in self?.tilePressed() }
        environment.register(control)
        model.holdOpen = { [weak environment] hold in environment?.actions.holdOpen(hold) }
        model.refocus = { [weak self] in self?.refocus() }
        pad.keepsOpen = { [weak self] in
            guard let self else { return false }
            return !self.preferences.closeOnClickOutside || self.model.isDialogUp
        }
        pad.didClose = { [weak self] in self?.model.surfaceDisappeared() }
    }

    var availability: IslandAvailability { .available }

    func page(_ context: IslandPageContext) -> AnyView {
        AnyView(ScratchpadPageView(model: model, context: context,
                                   openFloating: { [weak self] in self?.collapseThenOpenPad() },
                                   collapse: { [weak environment] in environment?.close() }))
    }

    func options() -> AnyView? {
        AnyView(ScratchpadOptionsView(preferences: preferences, settings: environment.settingsStore, shortcut: shortcut))
    }

    func islandDidStart() {
        guard !environment.isHeadless else { return }
        shortcut.activate(preferences.shortcut)
        shortcutObservation = preferences.$shortcut.dropFirst().sink { [weak self] value in self?.shortcut.apply(value) }
    }

    func islandDidStop() {
        shortcutObservation = nil
        shortcut.deactivate()
        pad.close()
        model.flushNow()
    }

    func pageDidAppear() { model.surfaceAppeared() }
    func pageDidDisappear() { model.surfaceDisappeared() }

    // MARK: Opening

    private var pageShowing: Bool { environment.isOpen && environment.destination == .section(.scratchpad) }

    /// The page when "Where Scratchpad opens" is the island and it is shown (without collapsing);
    /// otherwise the island collapses and the floating pad opens.
    private func tilePressed() {
        switch ScratchpadRouting.tile(environment.settings) {
        case .showPage: environment.open(.scratchpad)
        case .collapseThenFloatingPad: collapseThenOpenPad()
        }
    }

    private func shortcutPressed() {
        let action = ScratchpadRouting.shortcut(environment.settings, islandAccepts: environment.isRunning,
                                                pageShowing: pageShowing, islandIsKey: environment.isKey)
        switch action {
        case .openPage, .focusPage:
            environment.open(.scratchpad)
            if pageShowing { model.requestFocus() } else { toggleFloatingPad() }
        case .closeIsland:
            environment.close()
        case .floatingPad:
            toggleFloatingPad()
        }
    }

    /// Focus the pad if it is visible but another window has the keyboard; otherwise toggle it.
    private func toggleFloatingPad() {
        if pad.isVisible {
            if pad.isKey { pad.close() } else { pad.focus(); model.requestFocus() }
        } else {
            openPad()
        }
    }

    private func collapseThenOpenPad() {
        guard environment.isOpen else { openPad(); return }
        environment.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDelay) { [weak self] in
            MainActor.assumeIsolated { self?.openPad() }
        }
    }

    private func openPad() {
        guard !environment.isHeadless else { return }
        guard !pad.isVisible else { pad.focus(); return }
        model.surfaceAppeared()
        let window = pad
        pad.show(ScratchpadPadView(model: model, preferences: preferences, keyState: pad.keyState,
                                   owns: { [weak window] in window?.owns($0) ?? false },
                                   close: { [weak window] in window?.close() }))
    }

    /// After a dialog: the keyboard goes back to whichever surface is still showing, never reopening one.
    private func refocus() {
        if pageShowing {
            environment.open(.scratchpad)
            model.requestFocus()
        } else if pad.isVisible {
            pad.focus()
            model.requestFocus()
        }
    }
}
