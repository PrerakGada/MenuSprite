import AppKit
import IslandKit
import SwiftUI

/// The island's Scratchpad page: a toolbar of tabs and actions, the save warning when a write
/// failed, and the editor filling the rest of the budget.
struct ScratchpadPageView: View {
    @ObservedObject var model: ScratchpadModel
    let context: IslandPageContext
    let openFloating: () -> Void
    let collapse: () -> Void
    @State private var keys = ScratchpadKeyRouter()

    var body: some View {
        content
            .frame(width: context.width, height: context.budget, alignment: .top)
            .onAppear {
                guard !context.isPreview else { return }
                keys.install(owns: { $0 is IslandPanel }) { command in perform(command) }
            }
            .onDisappear { keys.remove() }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .failed:
            IslandUnavailableView(symbol: "exclamationmark.triangle", message: ScratchpadCopy.loadFailed)
        case .idle, .loading:
            if context.isPreview {
                ScratchpadPreviewPage(width: context.width)
            } else {
                Color.clear
            }
        case .ready:
            if let document = model.document {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        ScratchpadTabStrip(model: model, document: document)
                        toolbar(document)
                    }
                    .frame(height: 24)
                    ScratchpadNotices(model: model)
                    ScratchpadEditorArea(model: model, pad: document.selected, interactive: !context.isPreview)
                }
            }
        }
    }

    private func toolbar(_ document: ScratchpadDocument) -> some View {
        HStack(spacing: 2) {
            ScratchpadIconButton(symbol: "plus", help: document.canAddPad ? "New scratchpad" : ScratchpadCopy.limit,
                                 enabled: document.canAddPad) { model.newPad() }
            ScratchpadIconButton(symbol: model.previewing ? "pencil" : "eye",
                                 help: model.previewing ? "Edit text" : "Show formatting",
                                 enabled: !model.selectedIsEmpty || model.previewing) { model.togglePreview() }
            ScratchpadIconButton(symbol: model.copied ? "checkmark" : "doc.on.doc", help: model.copied ? "Copied" : "Copy all",
                                 enabled: !model.selectedIsEmpty) { model.copyAll() }
            ScratchpadActionsMenu(model: model, document: document, openFloating: openFloating)
        }
    }

    private func perform(_ command: ScratchpadKeyCommand) {
        guard let document = model.document else { return }
        switch command {
        case .newPad: model.newPad()
        case .closePad:
            if document.canClosePad { model.close(document.selectedID) } else { collapse() }
        }
    }
}

/// The floating pad: drag handle, tabs, +, "…", keep-open pin and × on top; the editor; preview,
/// copy all, save as file and clear along the bottom. Resizable, over a frosted background whose
/// opacity follows "Pad background".
struct ScratchpadPadView: View {
    @ObservedObject var model: ScratchpadModel
    @ObservedObject var preferences: ScratchpadPreferences
    @ObservedObject var keyState: FloatingToolKeyState
    let owns: (NSWindow?) -> Bool
    let close: () -> Void
    @State private var keys = ScratchpadKeyRouter()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.state {
            case .failed:
                header(nil)
                IslandUnavailableView(symbol: "exclamationmark.triangle", message: ScratchpadCopy.loadFailed)
            case .idle, .loading:
                header(nil)
                Spacer()
            case .ready:
                if let document = model.document {
                    header(document)
                    ScratchpadNotices(model: model)
                    ScratchpadEditorArea(model: model, pad: document.selected, surface: Color.white.opacity(0.05))
                    footer
                }
            }
        }
        .padding(10)
        .frame(minWidth: 280, maxWidth: .infinity, minHeight: 220, maxHeight: .infinity, alignment: .top)
        .background(FrostedBackground(opacity: preferences.background))
        .onAppear {
            keys.install(owns: owns) { command in
                guard let document = model.document else { return }
                switch command {
                case .newPad: model.newPad()
                case .closePad: if document.canClosePad { model.close(document.selectedID) } else { close() }
                }
            }
        }
        .onDisappear { keys.remove() }
        .onChange(of: keyState.isKey) { _, isKey in
            if isKey { model.requestFocus() }
        }
    }

    private func header(_ document: ScratchpadDocument?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(IslandStyle.tertiaryText)
                .frame(width: 16, height: 24)
                .help("Drag to move")
            if let document {
                ScratchpadTabStrip(model: model, document: document)
                ScratchpadIconButton(symbol: "plus", help: document.canAddPad ? "New scratchpad" : ScratchpadCopy.limit,
                                     enabled: document.canAddPad) { model.newPad() }
                ScratchpadActionsMenu(model: model, document: document)
            } else {
                Spacer()
            }
            ScratchpadIconButton(symbol: preferences.closeOnClickOutside ? "pin" : "pin.fill",
                                 help: preferences.closeOnClickOutside ? "Keep open" : "Close when I click outside") {
                preferences.closeOnClickOutside.toggle()
            }
            ScratchpadIconButton(symbol: "xmark", help: "Close", action: close)
        }
        .frame(height: 24)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            ScratchpadIconButton(symbol: model.previewing ? "pencil" : "eye",
                                 help: model.previewing ? "Edit text" : "Show formatting",
                                 enabled: !model.selectedIsEmpty || model.previewing) { model.togglePreview() }
            ScratchpadIconButton(symbol: model.copied ? "checkmark" : "doc.on.doc", help: model.copied ? "Copied" : "Copy all",
                                 enabled: !model.selectedIsEmpty) { model.copyAll() }
            ScratchpadIconButton(symbol: "square.and.arrow.down", help: "Save as file",
                                 enabled: !model.selectedIsEmpty && !model.isDialogUp) { model.export() }
            Spacer()
            ScratchpadIconButton(symbol: "trash", help: "Clear", enabled: !model.selectedIsEmpty) { model.clear() }
        }
        .frame(height: 26)
    }
}

/// What the Settings preview shows before the notes were ever opened: the page's shape with an
/// empty pad, without reading anything.
private struct ScratchpadPreviewPage: View {
    let width: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Scratchpad 1")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                Spacer()
            }
            .frame(height: 24)
            Text(ScratchpadCopy.placeholder)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.35))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(IslandStyle.surface))
        }
        .foregroundStyle(.white)
        .frame(width: width)
    }
}
