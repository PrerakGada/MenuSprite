import AppKit
import IslandKit
import SwiftUI

/// The mouse side of one shelf tile, in AppKit because SwiftUI's drag API cannot say how a drag
/// ended (needed to remove dragged items and to collapse the island) and cannot give each file its
/// own dragging item. The first click counts even when the window is not key; empty strip space
/// never moves the window.
struct ShelfTileInteraction: NSViewRepresentable {
    let tile: ShelfTile
    let controller: ShelfController
    let host: ShelfHost
    let image: NSImage?
    var hovering: Binding<Bool>

    func makeNSView(context: Context) -> ShelfTileHitView { ShelfTileHitView() }

    func updateNSView(_ view: ShelfTileHitView, context: Context) {
        view.tile = tile
        view.controller = controller
        view.host = host
        view.image = image
        view.hovering = hovering
    }
}

final class ShelfTileHitView: NSView, NSDraggingSource {
    var tile: ShelfTile?
    weak var controller: ShelfController?
    var host: ShelfHost = .island
    var image: NSImage?
    var hovering: Binding<Bool>?
    private var downEvent: NSEvent?
    private var dragging = false
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering?.wrappedValue = true }
    override func mouseExited(with event: NSEvent) { hovering?.wrappedValue = false }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let down = downEvent, let tile, let controller else { return }
        let start = down.locationInWindow, now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) >= 4 else { return }
        dragging = true
        let leaves = controller.dragItems(for: tile.id)
        guard !leaves.isEmpty else { return }
        let items = leaves.enumerated().compactMap { index, leaf -> NSDraggingItem? in
            let writer: NSPasteboardWriting
            switch leaf.content {
            case .file(let file): writer = file.url as NSURL
            case .link(let url): writer = url as NSURL
            case .text(let text): writer = text as NSString
            case .pile: return nil
            }
            let item = NSDraggingItem(pasteboardWriter: writer)
            let offset = CGFloat(min(index, 4)) * 4
            let frame = NSRect(x: bounds.midX - 24 + offset, y: bounds.midY - 20 - offset, width: 48, height: 40)
            item.setDraggingFrame(frame, contents: image ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil))
            return item
        }
        guard !items.isEmpty else { return }
        controller.dragBegan(tile.id, host: host)
        let session = beginDraggingSession(with: items, event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { downEvent = nil }
        guard !dragging, let tile, let controller else { return }
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            controller.toggleExpanded(tile.id)
        } else {
            controller.click(tile.id, extending: event.modifierFlags.contains(.shift))
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tile, let controller else { return nil }
        return ShelfTileMenu.make(for: tile.id, controller: controller, view: self, host: host)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "a" {
            controller?.selectAll()
        } else if flags.isEmpty, event.keyCode == 53, controller?.selection.isEmpty == false {
            controller?.clearSelection()
        } else {
            super.keyDown(with: event)
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        controller?.dragOperations(withinApp: context == .withinApplication) ?? .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        controller?.dragEnded(accepted: !operation.isEmpty)
    }
}

/// A tile's right-click menu: pin, open, open with, share, reveal, zip, remove.
@MainActor
enum ShelfTileMenu {
    static func make(for id: UUID, controller: ShelfController, view: NSView, host: ShelfHost) -> NSMenu {
        let ids = controller.targets(for: id)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let pinned = controller.isPinned(ids)
        menu.addItem(ShelfMenuItem(pinned ? "Unpin" : "Pin", symbol: pinned ? "pin.slash" : "pin") {
            controller.setPinned(ids, !pinned)
        })
        menu.addItem(.separator())
        let files = controller.hasFiles(ids)
        let links = controller.store.shelf.leaves(of: ids).contains { if case .link = $0.content { return true }; return false }
        if files || links {
            menu.addItem(ShelfMenuItem("Open", symbol: "arrow.up.forward.app") { controller.open(ids) })
        }
        if files {
            let apps = controller.appsOpeningAll(ids)
            if !apps.isEmpty {
                let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for app in apps {
                    let item = ShelfMenuItem(FileManager.default.displayName(atPath: app.path)) { controller.open(ids, with: app) }
                    let icon = NSWorkspace.shared.icon(forFile: app.path)
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                    submenu.addItem(item)
                }
                openWith.submenu = submenu
                menu.addItem(openWith)
            }
            menu.addItem(ShelfMenuItem("Share…", symbol: "square.and.arrow.up") { [weak view] in
                guard let view else { return }
                // After the menu has closed, so the picker is not dismissed with it.
                DispatchQueue.main.async { MainActor.assumeIsolated { controller.share(ids, from: view, host: host) } }
            })
            menu.addItem(ShelfMenuItem("Show in Finder", symbol: "folder") { controller.reveal(ids) })
            let zip = ShelfMenuItem("Create ZIP…", symbol: "doc.zipper") { [weak view] in
                DispatchQueue.main.async { MainActor.assumeIsolated { controller.createZip(ids, from: view, host: host) } }
            }
            zip.isEnabled = !controller.isZipping
            menu.addItem(zip)
            menu.addItem(.separator())
        }
        menu.addItem(ShelfMenuItem(ids.count > 1 ? "Remove \(ids.count) Items" : "Remove", symbol: "xmark") {
            controller.remove(ids)
        })
        return menu
    }
}

/// A menu item that runs a closure.
final class ShelfMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() {
        let handler = handler
        MainActor.assumeIsolated { handler() }
    }
}

/// Finds the AppKit view behind a SwiftUI control, to anchor pickers and dialogs to it.
final class ShelfAnchor {
    weak var view: NSView?
}

struct ShelfAnchorView: NSViewRepresentable {
    let anchor: ShelfAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}
