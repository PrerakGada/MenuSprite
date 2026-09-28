import AppKit
import IslandKit
import SwiftUI

/// Pieces shared by the island page and the floating pad, so both are the same document edited in place.
enum ScratchpadCopy {
    static let placeholder = "Type anything. It saves by itself."
    static let saveWarning = "Your notes could not be saved. Copy them elsewhere before quitting."
    static let loadFailed = "Your notes could not be opened. They were left unchanged."
    static let limit = "You can keep up to \(ScratchpadDocument.maximumPads) scratchpads"
}

/// The tabs: capsules in a sideways-scrolling strip. The selected one scrolls to the centre.
struct ScratchpadTabStrip: View {
    @ObservedObject var model: ScratchpadModel
    let document: ScratchpadDocument

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(document.pads) { pad in
                        ScratchpadTab(model: model, pad: pad, selected: pad.id == document.selectedID,
                                      closable: document.canClosePad)
                            .id(pad.id)
                    }
                }
            }
            .onAppear { proxy.scrollTo(document.selectedID, anchor: .center) }
            .onChange(of: document.selectedID) { _, id in
                withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(height: 22)
    }
}

private struct ScratchpadTab: View {
    @ObservedObject var model: ScratchpadModel
    let pad: ScratchpadPad
    let selected: Bool
    let closable: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            Text(pad.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.6))
            if closable && (selected || hovering) {
                Button { model.close(pad.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.7))
                .help("Close scratchpad")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, closable && (selected || hovering) ? 4 : 9)
        .frame(height: 22)
        .background(Capsule().fill(Color.white.opacity(selected ? 0.14 : 0.05)))
        .contentShape(Capsule())
        .onTapGesture { model.select(pad.id) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename scratchpad") { model.rename(pad.id) }
            Button("Close scratchpad", role: .destructive) { model.close(pad.id) }.disabled(!closable)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A 24-pt square symbol button in the island's style.
struct ScratchpadIconButton: View {
    let symbol: String
    let help: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.85))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(IslandButtonStyle(cornerRadius: 7))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The "…" menu: rename and close the selected pad, save it as a file, clear it, and (on the
/// island page) open the floating pad.
struct ScratchpadActionsMenu: View {
    @ObservedObject var model: ScratchpadModel
    let document: ScratchpadDocument
    var openFloating: (() -> Void)?

    var body: some View {
        Menu {
            Button("Rename scratchpad") { model.rename(document.selectedID) }
            Button("Close scratchpad", role: .destructive) { model.close(document.selectedID) }.disabled(!document.canClosePad)
            Divider()
            Button("Save as file…") { model.export() }.disabled(model.selectedIsEmpty || model.isDialogUp)
            Button("Clear", role: .destructive) { model.clear() }.disabled(model.selectedIsEmpty)
            if let openFloating {
                Divider()
                Button("Open scratchpad", action: openFloating)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }
}

/// The editor surface: the text view, the placeholder over an empty pad, and the Markdown preview
/// over the (hidden, still mounted) editor while previewing. In the Settings preview it is a
/// static picture of the text, so it can never take the keyboard.
struct ScratchpadEditorArea: View {
    @ObservedObject var model: ScratchpadModel
    let pad: ScratchpadPad
    var surface: Color = IslandStyle.surface
    var interactive = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            if interactive {
                ScratchpadEditor(text: pad.text, focusSerial: model.focusSerial, clearSerial: model.clearSerial,
                                 hidden: model.previewing, onChange: { model.setText($0) }, onClear: { model.didClear() })
                    .id(pad.id)
                    .opacity(model.previewing ? 0 : 1)
                    .allowsHitTesting(!model.previewing)
            } else if !model.previewing {
                Text(String(pad.text.prefix(2_000)))
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
            }
            if pad.text.isEmpty && !model.previewing {
                Text(ScratchpadCopy.placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .padding(.leading, 11)
                    .padding(.top, 6)
                    .allowsHitTesting(false)
            }
            if model.previewing {
                ScratchpadMarkdownView(text: pad.text)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(surface))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The notices under the toolbar: the save warning after a failed write, and export failures.
struct ScratchpadNotices: View {
    @ObservedObject var model: ScratchpadModel

    var body: some View {
        if model.saveWarning {
            line(ScratchpadCopy.saveWarning)
        }
        if let message = model.message {
            line(message)
        }
    }

    private func line(_ text: String) -> some View {
        Label {
            Text(text).lineLimit(2)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Color.white.opacity(0.6))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// ⌘T and ⌘W while a scratchpad surface is showing, only for events in that surface's window.
@MainActor
final class ScratchpadKeyRouter {
    private var monitor: Any?

    func install(owns: @escaping (NSWindow?) -> Bool, perform: @escaping (ScratchpadKeyCommand) -> Void) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard owns(event.window) else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
            guard let command = ScratchpadKeyCommand(characters: event.charactersIgnoringModifiers, commandOnly: flags == .command) else {
                return event
            }
            perform(command)
            return nil
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
