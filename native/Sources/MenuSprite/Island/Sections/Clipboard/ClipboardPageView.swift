import AppKit
import Carbon.HIToolbox
import IslandKit
import SwiftUI

/// Where the history is showing: the island page or its own window. The page reads everything else
/// from the model.
struct ClipboardSurface {
    /// Whether this surface holds the keyboard (⌘1–⌘9 badges show only then).
    var isKey: Bool
    var isPreview = false
    /// Whether a key event belongs to this surface's window.
    var owns: (NSWindow?) -> Bool
    /// Hide this surface before a paste, so ⌘V lands in the app behind it.
    var collapse: () -> Void
    /// The island's "Open window" button; nil in the window itself.
    var openWindow: (() -> Void)?
    var openSettings: () -> Void
}

/// The history as a searchable list of cards, used by the island page and the history window.
struct ClipboardPageView: View {
    @ObservedObject var model: ClipboardHistoryModel
    @ObservedObject var preferences: ClipboardPreferences
    let surface: ClipboardSurface
    @FocusState private var searchFocused: Bool
    @State private var keys = ClipboardKeyRouter()

    var body: some View {
        VStack(spacing: 8) {
            searchRow
            if let message = model.message {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(IslandStyle.secondaryText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            guard !surface.isPreview else { return }
            keys.install(owns: surface.owns, model: model, collapse: surface.collapse)
            if surface.isKey { searchFocused = true }
        }
        .onDisappear { keys.remove() }
        .onChange(of: surface.isKey) { _, isKey in if isKey && !surface.isPreview { searchFocused = true } }
        .onChange(of: searchFocused) { _, focused in keys.searchFocused = focused }
    }

    // MARK: Search row

    private var searchRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IslandStyle.secondaryText)
            TextField("Search copied text", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .focused($searchFocused)
                .disabled(surface.isPreview)
            rowButton(model.pinnedOnly ? "pin.fill" : "pin", help: model.pinnedOnly ? "Show everything" : "Show pinned only",
                      selected: model.pinnedOnly) { model.pinnedOnly.toggle() }
            rowButton("trash", help: "Clear recent", enabled: model.history.hasRecent) { model.clearRecent() }
            if let openWindow = surface.openWindow {
                rowButton("arrow.up.forward.app", help: "Open in a window", action: openWindow)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(IslandStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.white.opacity(searchFocused ? 0.34 : 0), lineWidth: 1)
            .animation(.easeOut(duration: 0.15), value: searchFocused))
    }

    private func rowButton(_ symbol: String, help: String, selected: Bool = false, enabled: Bool = true,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(Circle().fill(selected ? Color.white : Color.clear))
        }
        .buttonStyle(IslandButtonStyle(cornerRadius: 14))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Body

    @ViewBuilder private var content: some View {
        let blocked = preferences.keepHistory && model.access.map { !$0.allowsAutomaticReads } == true
        if model.load == .failed {
            ClipboardStateView(symbol: "exclamationmark.triangle", title: "Your clipboard history could not be opened.",
                               detail: "It was left unchanged. Clear it in Clipboard settings to start again.") {
                Button("Clipboard Settings", action: surface.openSettings)
            }
        } else if !preferences.keepHistory && model.entries.isEmpty {
            ClipboardStateView(symbol: "doc.on.clipboard", title: "Turn on history to keep what you copy.",
                               detail: "It stays on this Mac, in a private file.") {
                Button("Keep clipboard history") { preferences.keepHistory = true }
            }
        } else if blocked, model.entries.isEmpty, let access = model.access {
            ClipboardAccessView(model: model, access: access, compact: false)
        } else {
            if blocked, let access = model.access {
                ClipboardAccessView(model: model, access: access, compact: true)
            }
            if model.results.isEmpty {
                ClipboardStateView(symbol: model.pinnedOnly ? "pin" : "doc.on.clipboard",
                                   title: model.hasQuery || model.pinnedOnly ? "No results" : "Nothing saved yet",
                                   detail: nil) { EmptyView() }
            } else {
                list
            }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { position, entry in
                        ClipboardCard(model: model, entry: entry, position: position,
                                      showsBadge: surface.isKey && position < 9,
                                      highlighted: model.highlight.id == entry.id,
                                      collapse: surface.collapse)
                            .id(entry.id)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .onChange(of: model.highlight) { _, highlight in
                guard let id = highlight.id else { return }
                withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.15)) {
                    proxy.scrollTo(id)
                }
            }
        }
    }
}

/// An empty, off or failed state: a symbol, a line, an optional detail and an optional button.
struct ClipboardStateView<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(IslandStyle.tertiaryText)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(IslandStyle.secondaryText)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(IslandStyle.tertiaryText)
            }
            actions
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// macOS asks before apps read other apps' copies. Until MenuSprite is set to Allow in Privacy &
/// Security › Paste from Other Apps, nothing is read; this says so and offers the way through.
struct ClipboardAccessView: View {
    @ObservedObject var model: ClipboardHistoryModel
    let access: ClipboardReadAccess
    /// One line above the list, when saved entries are still there to use.
    let compact: Bool

    private var detail: String {
        switch access {
        case .notAsked: "Press Ask macOS and choose Allow, or allow MenuSprite in Privacy & Security › Paste from Other Apps."
        case .asks: "MenuSprite is set to Ask in Privacy & Security › Paste from Other Apps. Set it to Allow to keep history."
        case .denied: "MenuSprite is set to Deny in Privacy & Security › Paste from Other Apps. Set it to Allow to keep history."
        case .allowed: ""
        }
    }

    var body: some View {
        if compact {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised").font(.system(size: 11, weight: .medium))
                Text("Not saving: macOS asks before reading copies.").font(.system(size: 11)).lineLimit(1)
                Spacer(minLength: 4)
                buttons
            }
            .foregroundStyle(IslandStyle.secondaryText)
            .frame(height: 24)
        } else {
            ClipboardStateView(symbol: "hand.raised", title: "macOS is guarding your clipboard", detail: detail) { buttons }
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 6) {
            if access == .notAsked {
                Button("Ask macOS") { model.askSystem() }
            }
            Button("Open System Settings") { ClipboardHistoryModel.openPasteSettings() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

/// The page's keys, for events in its own window only: ⌘1–⌘9 by physical key activate that place
/// in the visible list; ↑ ↓ Return and Enter move and activate the highlight while the search field
/// has the keyboard (never while an input method is composing).
@MainActor
final class ClipboardKeyRouter {
    var searchFocused = false
    private var monitor: Any?

    func install(owns: @escaping (NSWindow?) -> Bool, model: ClipboardHistoryModel, collapse: @escaping () -> Void) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak model] event in
            guard let self, let model, owns(event.window) else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
            if let position = ClipboardQuickKeys.index(keyCode: event.keyCode, commandOnly: flags == .command) {
                if model.results.indices.contains(position) { model.activate(model.results[position], collapse: collapse) } else { NSSound.beep() }
                return nil
            }
            let composing = (event.window?.firstResponder as? NSTextView)?.hasMarkedText() == true
            guard flags.isEmpty, self.searchFocused, !composing else { return event }
            let ids = model.results.map(\.id)
            switch Int(event.keyCode) {
            case kVK_UpArrow, kVK_DownArrow:
                model.highlight.move(down: Int(event.keyCode) == kVK_DownArrow, results: ids)
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                guard let id = model.highlight.id, let entry = model.results.first(where: { $0.id == id }) else { return event }
                model.activate(entry, collapse: collapse)
                return nil
            default:
                return event
            }
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
