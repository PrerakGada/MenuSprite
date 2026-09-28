import AppKit
import Combine
import IslandKit
import SwiftUI

/// Files in a separate window, for when "Files" is set to Separate window or the Files section is
/// hidden: a small dark card near the top right of the screen with the pointer, holding the same
/// strip as the island page. It takes drops itself, closes with ×, Esc, or by itself five seconds
/// after it is left empty. The window exists only while it is shown.
@MainActor
final class ShelfWindowController {
    private let controller: ShelfController
    private var panel: ShelfWindowPanel?
    private var emptyTimer: Task<Void, Never>?
    private var emptiness: AnyCancellable?
    static let size = CGSize(width: 400, height: 244)

    init(controller: ShelfController) { self.controller = controller }

    var isVisible: Bool { panel != nil }

    func show() {
        if let panel { panel.orderFrontRegardless(); return }
        let panel = ShelfWindowPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.setAccessibilitySubrole(.unknown)
        panel.onEscape = { [weak self] in self?.hide() }
        let drop = ShelfDropView(frame: NSRect(origin: .zero, size: Self.size))
        drop.accept = { [weak controller] pasteboard in controller?.accept(pasteboard) ?? false }
        drop.hovering = { [weak self] inside in if inside { self?.emptyTimer?.cancel() } else { self?.watchEmpty() } }
        let content = NSHostingView(rootView: ShelfWindowView(controller: controller, close: { [weak self] in self?.hide() }))
        content.frame = drop.bounds
        content.autoresizingMask = [.width, .height]
        drop.addSubview(content)
        panel.contentView = drop
        panel.setFrameOrigin(Self.origin(for: Self.size))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.13
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        controller.pageAppeared()
        emptiness = controller.store.$shelf.map(\.isEmpty).removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.watchEmpty() } }
        }
    }

    func hide() {
        guard let panel else { return }
        emptyTimer?.cancel()
        emptiness = nil
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        controller.pageDisappeared()
    }

    func toggle() { if isVisible { hide() } else { show() } }

    /// An empty window closes itself after five seconds, unless something is being dragged over it.
    private func watchEmpty() {
        emptyTimer?.cancel()
        guard panel != nil, controller.store.isLoaded, controller.store.shelf.isEmpty else { return }
        emptyTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.controller.store.shelf.isEmpty else { return }
            self.hide()
        }
    }

    /// Top right of the screen with the pointer, just under the menu bar.
    private static func origin(for size: CGSize) -> NSPoint {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 8)
    }
}

final class ShelfWindowPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Takes drops for the shelf window. Drags that start in MenuSprite itself (its own tiles) are refused.
final class ShelfDropView: NSView {
    var accept: (NSPasteboard) -> Bool = { _ in false }
    var hovering: (Bool) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(ShelfPasteboard.dropTypes)
    }

    required init?(coder: NSCoder) { nil }

    private func operation(_ info: NSDraggingInfo) -> NSDragOperation {
        info.draggingSource == nil && ShelfPasteboard.hasDroppableType(info.draggingPasteboard) ? .copy : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hovering(true)
        return operation(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) { hovering(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hovering(false)
        guard !operation(sender).isEmpty else { return false }
        return accept(sender.draggingPasteboard)
    }
}

private struct ShelfWindowView: View {
    @ObservedObject var controller: ShelfController
    @ObservedObject var store: ShelfStore
    let close: () -> Void

    init(controller: ShelfController, close: @escaping () -> Void) {
        self.controller = controller
        self.store = controller.store
        self.close = close
    }

    var body: some View {
        let size = ShelfWindowController.size
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: IslandSectionID.files.symbol).foregroundStyle(IslandStyle.secondaryText)
                Text("Files").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                if store.shelf.leafCount > 0 {
                    Text(store.shelf.leafCount == 1 ? "1 item" : "\(store.shelf.leafCount) items")
                        .font(.system(size: 11)).foregroundStyle(IslandStyle.tertiaryText)
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(IslandStyle.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close")
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            ShelfPageView(controller: controller, host: .window, width: size.width - 28, height: size.height - 28 - 34)
        }
        .padding(14)
        .frame(width: size.width, height: size.height)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}
