import AppKit

/// The pages of MenuSprite's one window. Every full page the menu bar reaches opens here, on its tab.
enum AppPage: String, CaseIterable {
    case sprites, power, island, work, access

    static var available: [AppPage] { allCases.filter { $0 != .work || !BuildFeatures.publicPreview } }

    /// The toolbar label, short enough to sit under its icon.
    var label: String {
        switch self {
        case .sprites: "Sprites"
        case .power: "Controls"
        case .island: "Island"
        case .work: "Work"
        case .access: "Access"
        }
    }

    /// The window title while the page is showing.
    var title: String {
        switch self {
        case .sprites: "Monitoring & Sprites"
        case .power: BuildFeatures.powerPageTitle
        case .island: "Dynamic Island"
        case .work: "Work & Clients"
        case .access: "Permissions & Access"
        }
    }

    var symbol: String {
        switch self {
        case .sprites: "slider.horizontal.3"
        case .power: "bolt.badge.clock"
        case .island: "capsule.fill"
        case .work: "briefcase"
        case .access: "lock.shield"
        }
    }

    fileprivate var item: NSToolbarItem.Identifier { NSToolbarItem.Identifier("MenuSprite.page.\(rawValue)") }
}

/// MenuSprite's one window: a toolbar of pages, one showing at a time. A page is built when it is chosen
/// and released when another is chosen or the window closes, so only the visible page holds its store
/// open. While the window is open MenuSprite is an ordinary app (Dock icon, ⌘-Tab, its own Stage
/// Manager stage); when it closes, MenuSprite goes back to living in the menu bar alone.
@MainActor
final class AppWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    struct Pages {
        /// Builds the page's view and opens whatever it reads.
        var make: (AppPage) -> NSView
        /// Closes what `make` opened; the view is already out of the window.
        var closed: (AppPage) -> Void
        /// Whether the page can be seen: false while the window is minimized or fully covered.
        var visibility: (AppPage, Bool) -> Void = { _, _ in }
    }

    private static let autosaveName = "MenuSpriteWindow"
    private let pages: Pages
    private(set) var window: NSWindow?
    /// The chosen page; it survives the window closing, so reopening lands where it was left.
    private(set) var page: AppPage = .sprites
    /// The page whose view is in the window, nil while the window is closed.
    private(set) var showing: AppPage?

    init(pages: Pages) { self.pages = pages }

    var isVisible: Bool { window?.isVisible == true }

    /// The window while `page` is the one in it, for validation runs and ⌘W.
    func window(showing page: AppPage) -> NSWindow? { showing == page ? window : nil }

    /// Opens the window on `page`, or switches the open window to it, and brings MenuSprite forward.
    func show(_ page: AppPage) {
        let window = self.window ?? makeWindow()
        select(page)
        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.close() }

    private func select(_ page: AppPage) {
        self.page = page
        guard let window else { return }
        window.toolbar?.selectedItemIdentifier = page.item
        window.title = page.title
        guard showing != page else { return }
        if let showing {
            window.contentView = nil
            pages.closed(showing)
        }
        window.contentView = pages.make(page)
        showing = page
        window.makeFirstResponder(nil)
        pages.visibility(page, window.occlusionState.contains(.visible) && !window.isMiniaturized)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 810),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        let toolbar = NSToolbar(identifier: "MenuSpriteWindow")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        if !window.setFrameUsingName(Self.autosaveName) { window.center() }
        window.setFrameAutosaveName(Self.autosaveName)
        self.window = window
        return window
    }

    @objc private func choose(_ sender: NSToolbarItem) {
        guard let page = AppPage.allCases.first(where: { $0.item == sender.itemIdentifier }) else { return }
        select(page)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window else { return }
        window.contentView = nil
        if let showing { pages.closed(showing) }
        showing = nil
        window.delegate = nil
        self.window = nil
        // The feedback window keeps MenuSprite an ordinary app while it is still open.
        if !FeedbackWindowController.shared.isOpen { NSApp.setActivationPolicy(.accessory) }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { reportVisibility() }
    func windowDidMiniaturize(_ notification: Notification) { reportVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { reportVisibility() }

    private func reportVisibility() {
        guard let window, let showing else { return }
        pages.visibility(showing, window.occlusionState.contains(.visible) && !window.isMiniaturized)
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { AppPage.available.map(\.item) }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { AppPage.available.map(\.item) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { AppPage.available.map(\.item) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let page = AppPage.allCases.first(where: { $0.item == itemIdentifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = page.label
        item.toolTip = page.title
        item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title)
        item.target = self
        item.action = #selector(choose(_:))
        return item
    }
}
