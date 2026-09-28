import AppKit
import SwiftUI

/// The history in its own floating window, for "Where Clipboard opens: Separate window", a hidden
/// Clipboard section, or the page's "Open in a window" button. Built on open, released on close;
/// Esc or a click outside closes it.
@MainActor
final class ClipboardWindow {
    private let window = FloatingToolWindow(title: "Clipboard", size: CGSize(width: 420, height: 480),
                                            minimum: CGSize(width: 320, height: 300), resizable: true)
    private let model: ClipboardHistoryModel
    private let preferences: ClipboardPreferences
    private let openSettings: () -> Void

    init(model: ClipboardHistoryModel, preferences: ClipboardPreferences, openSettings: @escaping () -> Void) {
        self.model = model
        self.preferences = preferences
        self.openSettings = openSettings
        window.didClose = { [weak model] in model?.surfaceDisappeared() }
    }

    var isVisible: Bool { window.isVisible }

    /// Focus it if it is up but another window has the keyboard; otherwise open or close it.
    func toggle() {
        if window.isVisible {
            if window.isKey { close() } else { window.focus() }
        } else {
            show()
        }
    }

    func show() {
        guard !window.isVisible else { window.focus(); return }
        model.surfaceAppeared()
        let host = window
        window.show(ClipboardWindowView(model: model, preferences: preferences, keyState: host.keyState,
                                        owns: { [weak host] in host?.owns($0) ?? false },
                                        close: { [weak host] in host?.close() }, openSettings: openSettings))
    }

    func close() { window.close() }
}

private struct ClipboardWindowView: View {
    @ObservedObject var model: ClipboardHistoryModel
    @ObservedObject var preferences: ClipboardPreferences
    @ObservedObject var keyState: FloatingToolKeyState
    let owns: (NSWindow?) -> Bool
    let close: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Clipboard", systemImage: "doc.on.clipboard").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
                }
                .buttonStyle(IslandButtonStyle(cornerRadius: 7))
                .help("Close")
            }
            .foregroundStyle(.white)
            ClipboardPageView(model: model, preferences: preferences,
                              surface: ClipboardSurface(isKey: keyState.isKey, owns: owns, collapse: close,
                                                        openWindow: nil, openSettings: { close(); openSettings() }))
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(FrostedBackground(opacity: 0.6))
    }
}
