import AppKit
import IslandKit
import SwiftUI

/// A screenshot shown in the quick preview. The full PNG lives only while a preview holds it.
struct CapturePreviewItem {
    var entry: RecentCapture
    /// At most 1200 px on its long side, sized in points.
    let image: NSImage
    let png: Data
    var status: String
}

/// The quick preview after a screenshot: inside the island's Recent captures page when the Captures
/// indicator routes it there, otherwise a small floating window in the bottom-right corner. It closes
/// by itself (12 s, or 3 s after an automatic save or copy); the pointer resting on it pauses that.
/// While hosted it holds the island open and takes the preview keys.
@MainActor
final class CapturePreviewController: ObservableObject {
    @Published private(set) var item: CapturePreviewItem?
    @Published private(set) var isHosted = false

    private unowned let environment: IslandEnvironment
    private let options: CaptureOptions
    private let library: CaptureLibrary
    private var countdown: CapturePreviewCountdown?
    private var timer: Task<Void, Never>?
    private var floating: CaptureFloatingPreviewPanel?
    private var keyMonitor: Any?
    private var holdingIsland = false
    private var pageVisible = false
    /// A preview that opened the island closes it again; one restored from the page falls back to the list.
    private var collapsesIsland = false

    init(environment: IslandEnvironment, options: CaptureOptions, library: CaptureLibrary) {
        self.environment = environment
        self.options = options
        self.library = library
    }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    /// Shows a fresh capture: in the island when it can present there, else floating on `screen`.
    func present(_ item: CapturePreviewItem, automaticActionSucceeded: Bool, screen: NSScreen?) {
        end(collapse: false)
        self.item = item
        countdown = CapturePreviewCountdown(duration: CapturePreviewCountdown.duration(automaticActionSucceeded: automaticActionSucceeded),
                                            now: Self.now)
        if environment.isRunning, environment.wants(.captures), environment.visibleSections.contains(.captures) {
            isHosted = true
            collapsesIsland = true
            environment.open(.captures)
            if environment.isOpen, environment.destination == .section(.captures) {
                startHosting()
            } else {
                isHosted = false
            }
        }
        if !isHosted { showFloating(on: screen) }
        scheduleTimer()
    }

    /// Restore from the list: the preview replaces the list on the visible page, without re-running
    /// the automatic save or copy.
    func restore(_ item: CapturePreviewItem) {
        end(collapse: false)
        self.item = item
        countdown = CapturePreviewCountdown(duration: CapturePreviewCountdown.standard, now: Self.now)
        if pageVisible {
            isHosted = true
            collapsesIsland = false
            startHosting()
        } else {
            showFloating(on: NSScreen.underPointer)
        }
        scheduleTimer()
    }

    func hover(_ inside: Bool) {
        guard countdown != nil else { return }
        countdown?.hover(inside, now: Self.now)
        scheduleTimer()
    }

    func pageDidAppear() { pageVisible = true }

    /// The page went away under a hosted preview (the island closed or moved on): it ends there.
    func pageDidDisappear() {
        pageVisible = false
        if isHosted { end(collapse: false) }
    }

    /// Ends any preview now, as the island stops.
    func stop() {
        pageVisible = false
        end(collapse: false)
    }

    // MARK: Actions

    func perform(_ action: CapturePreviewAction) {
        guard let item else { return }
        switch action {
        case .copy:
            copy(item)
        case .save:
            if let url = item.entry.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { save(item) }
        case .discard:
            if let url = item.entry.fileURL {
                NSWorkspace.shared.recycle([url])
                var entry = item.entry
                entry.fileURL = nil
                Task { await library.add(entry, files: [:]) }
            }
            end(collapse: true)
        case .edit:
            if let url = item.entry.fileURL ?? (try? CaptureFiles.transferCopy(item.png, named: item.entry.displayName)) {
                NSWorkspace.shared.open(url)
            }
            end(collapse: true)
        case .close:
            end(collapse: true)
        }
    }

    /// A file for dragging the capture out: a named copy, so the drop carries the capture's name.
    func dragProvider() -> NSItemProvider {
        guard let item, let url = try? CaptureFiles.transferCopy(item.png, named: item.entry.displayName) else { return NSItemProvider() }
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }

    private func copy(_ item: CapturePreviewItem) {
        let png = item.png
        let name = item.entry.displayName
        Task {
            let prepared = await Task.detached { () -> (URL, Data?)? in
                guard let url = try? CaptureFiles.transferCopy(png, named: name) else { return nil }
                return (url, CaptureFiles.tiff(png))
            }.value
            guard let prepared else { NSSound.beep(); return }
            CapturePasteboard.copyImage(file: prepared.0, png: png, tiff: prepared.1)
            update(status: "Copied")
        }
    }

    private func save(_ item: CapturePreviewItem) {
        let png = item.png
        let date = item.entry.date
        let folder = options.resolvedSaveFolder
        Task {
            let url = await Task.detached { try? CaptureFiles.save(png, date: date, in: folder) }.value
            guard let url else { NSSound.beep(); return }
            guard var current = self.item, current.entry.id == item.entry.id else { return }
            current.entry.fileURL = url
            current.status = "Saved to \(folder.lastPathComponent)"
            self.item = current
            await library.add(current.entry, files: [:])
        }
    }

    private func update(status: String) {
        item?.status = status
    }

    // MARK: Presentation

    private func startHosting() {
        if !holdingIsland {
            environment.actions.holdOpen(true)
            holdingIsland = true
        }
        installKeyMonitor()
        environment.invalidate()
    }

    private func showFloating(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let panel = CaptureFloatingPreviewPanel(controller: self, screen: screen)
        panel.orderFrontRegardless()
        floating = panel
    }

    private func end(collapse: Bool) {
        timer?.cancel()
        timer = nil
        countdown = nil
        removeKeyMonitor()
        floating?.retire()
        floating = nil
        let wasHosted = isHosted
        item = nil
        isHosted = false
        if holdingIsland {
            environment.actions.holdOpen(false)
            holdingIsland = false
        }
        guard wasHosted else { return }
        environment.invalidate()
        if collapse, collapsesIsland, pageVisible, !environment.isPinned { environment.close() }
    }

    private func scheduleTimer() {
        timer?.cancel()
        guard let deadline = countdown?.deadline else { timer = nil; return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline - Self.now)))
            guard !Task.isCancelled, let self, self.countdown?.isExpired(now: Self.now) == true else { return }
            self.end(collapse: true)
        }
    }

    // MARK: Keys

    /// The island is non-activating, so its keys reach this monitor only while it is the key window.
    private func installKeyMonitor() {
        guard keyMonitor == nil, !environment.isHeadless else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleHostedKey(event) else { return event }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleHostedKey(_ event: NSEvent) -> Bool {
        guard let window = event.window, window is IslandPanel else { return false }
        var context = CapturePreviewKeys.Context()
        context.pageVisible = pageVisible && environment.destination == .section(.captures)
        context.islandExpanded = environment.isOpen
        context.chooserActive = environment.captureControlsActive
        context.previewCurrent = isHosted && item != nil
        context.textFieldHasFocus = window.firstResponder is NSText
        context.sheetAttached = window.attachedSheet != nil
        guard context.accepts, let action = CapturePreviewKeys.action(for: CaptureKeyPress(event)) else { return false }
        perform(action)
        return true
    }

    /// The floating preview keeps its keys whatever the island is doing.
    func handleFloatingKey(_ event: NSEvent) -> Bool {
        guard item != nil, !isHosted, let action = CapturePreviewKeys.action(for: CaptureKeyPress(event)) else { return false }
        perform(action)
        return true
    }
}

extension CaptureKeyPress {
    init(_ event: NSEvent) {
        let flags = event.modifierFlags
        self.init(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "", command: flags.contains(.command),
                  control: flags.contains(.control), option: flags.contains(.option), shift: flags.contains(.shift))
    }
}

/// The preview's actions in the island's header, icon-only so they fit beside the camera.
struct CapturePreviewActions: View {
    @ObservedObject var controller: CapturePreviewController

    var body: some View {
        if controller.isHosted, let item = controller.item {
            HStack(spacing: 2) {
                action("trash", "Delete", .discard)
                if item.entry.fileURL == nil { action("square.and.arrow.down", "Save", .save) }
                else { action("folder", "Show in Finder", .save) }
                action("doc.on.doc", "Copy", .copy)
            }
            .onHover { controller.hover($0) }
        }
    }

    private func action(_ symbol: String, _ label: String, _ action: CapturePreviewAction) -> some View {
        Button { controller.perform(action) } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 24, height: 24)
        }
        .buttonStyle(IslandButtonStyle(cornerRadius: 7))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The hosted preview: the capture fitted to the page, its name and what happened to it. Click opens
/// it for editing; drag takes the file out.
struct CapturePreviewPage: View {
    @ObservedObject var controller: CapturePreviewController
    let item: CapturePreviewItem
    let context: IslandPageContext

    var body: some View {
        let size = CapturePreviewLayout.imageSize(item.image.size, width: context.width, budget: context.budget)
        VStack(spacing: CapturePreviewLayout.captionSpacing) {
            Image(nsImage: item.image)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
                .onTapGesture { controller.perform(.edit) }
                .onDrag { controller.dragProvider() }
                .help("Click to edit, or drag it out")
            HStack(spacing: 8) {
                Text(item.entry.displayName).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(item.status).foregroundStyle(IslandStyle.secondaryText).lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .frame(width: max(size.width, min(context.width, 260)), height: CapturePreviewLayout.captionHeight)
        }
        .frame(width: context.width, alignment: .top)
        .padding(.top, CapturePreviewLayout.scrollInset)
        .contentShape(Rectangle())
        .onHover { controller.hover($0) }
    }
}

/// The floating preview: 350 × 210 pt in the corner of the screen, above ordinary windows, never
/// taking the keyboard until clicked.
@MainActor
final class CaptureFloatingPreviewPanel: CaptureUtilityPanel {
    private weak var controller: CapturePreviewController?

    init(controller: CapturePreviewController, screen: NSScreen) {
        self.controller = controller
        let size = CapturePreviewLayout.floatingSize
        let origin = CapturePreviewLayout.floatingOrigin(visibleFrame: screen.visibleFrame)
        super.init(frame: CGRect(origin: origin, size: size), level: .statusBar)
        allowsKey = true
        contentView = CaptureHostingView(rootView: CaptureFloatingPreviewView(controller: controller))
        setFrame(CGRect(origin: origin, size: size), display: false)
    }

    override func keyDown(with event: NSEvent) {
        if controller?.handleFloatingKey(event) != true { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        controller?.handleFloatingKey(event) == true || super.performKeyEquivalent(with: event)
    }
}

struct CaptureFloatingPreviewView: View {
    @ObservedObject var controller: CapturePreviewController
    /// Shows the action bar without hovering (for renders).
    var revealsActions = false
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.92))
            if let item = controller.item {
                Image(nsImage: item.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
                    .onTapGesture { controller.perform(.edit) }
                    .onDrag { controller.dragProvider() }
                HStack(spacing: 2) {
                    Text(item.status.isEmpty ? "Screenshot" : item.status)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .padding(.leading, 8)
                    Spacer(minLength: 4)
                    button("trash", "Delete", .discard)
                    button(item.entry.fileURL == nil ? "square.and.arrow.down" : "folder",
                           item.entry.fileURL == nil ? "Save" : "Show in Finder", .save)
                    button("doc.on.doc", "Copy", .copy)
                    button("xmark", "Close", .close)
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.75)))
                .padding(8)
                .opacity(hovering || revealsActions ? 1 : 0)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
        .foregroundStyle(.white)
        .onHover { inside in
            hovering = inside
            controller.hover(inside)
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private func button(_ symbol: String, _ label: String, _ action: CapturePreviewAction) -> some View {
        Button { controller.perform(action) } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 26, height: 26)
        }
        .buttonStyle(IslandButtonStyle(cornerRadius: 7))
        .help(label)
        .accessibilityLabel(label)
    }
}
