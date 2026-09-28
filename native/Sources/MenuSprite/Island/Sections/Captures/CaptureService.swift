import AppKit
import IslandKit
@preconcurrency import ScreenCaptureKit

/// A captured still on its way to the disk and the pasteboard. CGImage is immutable, so handing it
/// to a background task is safe.
private struct CapturedStill: @unchecked Sendable {
    let image: CGImage
    let scale: CGFloat
}

/// What the background work produced for one screenshot.
private struct PreparedScreenshot: @unchecked Sendable {
    let png: Data
    let thumbnail: Data?
    let preview: CGImage?
    let saved: URL?
    let saveFailed: Bool
    let transfer: URL?
    let tiff: Data?
}

/// A screenshot read back from the history for Restore.
private struct RestoredScreenshot: @unchecked Sendable {
    let png: Data
    let preview: CGImage
    let points: CGSize
}

/// The capture feature's owner: every entry point (tiles, shortcuts, the page) comes here. It checks
/// Screen Recording access (asking only from something the person did), freezes the displays, runs
/// one chooser at a time, turns the choice into a screenshot or a recording, and feeds the history
/// and the preview. Nothing runs between captures.
@MainActor
final class CaptureService: ObservableObject {
    @Published private(set) var hasAccess: Bool
    @Published private(set) var isChoosing = false

    let options: CaptureOptions
    let library: CaptureLibrary
    let preview: CapturePreviewController
    let recording = CaptureRecordingController()
    private unowned let environment: IslandEnvironment
    private var chooser: CaptureChooser?
    private var starting = false
    private var session = 0
    private var lastRegion: CaptureRegion?
    private var previousApp: NSRunningApplication?
    private var pasteboardCount = 0

    init(environment: IslandEnvironment, options: CaptureOptions, library: CaptureLibrary, hasAccess: Bool) {
        self.environment = environment
        self.options = options
        self.library = library
        self.hasAccess = hasAccess
        preview = CapturePreviewController(environment: environment, options: options, library: library)
        recording.saved = { [weak self] url in self?.recordingSaved(url) }
    }

    /// The chooser's controls go to the island when "Captures" opens there, the island is up and the
    /// Recent captures section is shown; otherwise they float.
    var controlsInIsland: Bool {
        let settings = environment.settings
        return settings.enabled && settings.capturesInIsland && environment.isRunning
            && environment.visibleSections.contains(.captures) && CaptureOwnWindows.islandScreen != nil
    }

    /// Reads Screen Recording access without asking.
    func refreshAccess() {
        guard !environment.isHeadless else { return }
        hasAccess = CapturePermission.isGranted
    }

    /// The page's Allow button: the system request, or System Settings once macOS no longer asks.
    func requestAccess() {
        guard !environment.isHeadless else { return }
        hasAccess = CapturePermission.request(headless: false)
        if !hasAccess { CapturePermission.openSettings() }
    }

    // MARK: Entry points

    /// Tile, shortcut or page button: the island collapses first, then the chooser opens once it has
    /// settled, so the island is never in the frozen picture. A second request while one runs is refused.
    func begin(_ tool: CaptureTool) {
        guard !environment.isHeadless else { return }
        guard chooser == nil, !starting, !(tool == .recording && recording.isActive) else {
            NSSound.beep()
            return
        }
        starting = true
        collapseThenAct { [weak self] in await self?.openChooser(tool) }
    }

    /// The Screen recording tile and shortcut: record, cancel a countdown, or stop and save.
    func toggleRecording() {
        switch recording.state {
        case .idle, .message: begin(.recording)
        case .countdown: recording.stopOrCancel()
        case .recording: collapseThenAct { [weak self] in self?.recording.stopOrCancel() }
        case .finishing: break
        }
    }

    /// The island stopped: close the chooser and previews; a recording stops and is kept.
    func stop() {
        chooser?.cancel()
        preview.stop()
        recording.teardown()
    }

    // MARK: History actions

    func restore(_ entry: RecentCapture) {
        guard let url = library.imageURL(for: entry) else { return }
        Task {
            let loaded = await Task.detached { () -> RestoredScreenshot? in
                guard let data = try? Data(contentsOf: url), let full = CaptureFiles.image(from: data),
                      let small = CaptureFiles.downscaled(full, pixels: CapturePreviewLayout.imagePixelLimit) else { return nil }
                return RestoredScreenshot(png: data, preview: small, points: CaptureFiles.pointSize(of: data, image: full))
            }.value
            guard let loaded else { NSSound.beep(); return }
            let item = CapturePreviewItem(entry: entry, image: NSImage(cgImage: loaded.preview, size: loaded.points), png: loaded.png,
                                          status: entry.fileURL.map { "In \($0.deletingLastPathComponent().lastPathComponent)" } ?? "")
            preview.restore(item)
        }
    }

    /// Opens a recording in its default app; a file that has gone leaves the history with a beep.
    func open(_ entry: RecentCapture) {
        guard let url = entry.fileURL, FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            library.remove(entry)
            return
        }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ entry: RecentCapture) {
        guard let url = entry.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copy(_ entry: RecentCapture) {
        if entry.kind == .recording {
            if let url = entry.fileURL { CapturePasteboard.copyFile(url) }
            return
        }
        guard let source = library.imageURL(for: entry) else { return }
        let name = entry.displayName
        Task {
            let prepared = await Task.detached { () -> (URL, Data, Data?)? in
                guard let png = try? Data(contentsOf: source), let url = try? CaptureFiles.transferCopy(png, named: name) else { return nil }
                return (url, png, CaptureFiles.tiff(png))
            }.value
            guard let prepared else { NSSound.beep(); return }
            CapturePasteboard.copyImage(file: prepared.0, png: prepared.1, tiff: prepared.2)
        }
    }

    /// A drag out of the list: a recording's own file, or a named copy of a screenshot.
    func dragProvider(for entry: RecentCapture) -> NSItemProvider {
        if entry.kind == .recording { return entry.fileURL.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
        guard let source = library.imageURL(for: entry),
              let url = try? CaptureFiles.transferCopy(of: source, named: entry.displayName) else { return NSItemProvider() }
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }

    // MARK: Chooser

    /// The island collapses first; the action runs once its closing animation has settled, so the
    /// island is never in the capture.
    private func collapseThenAct(_ action: @escaping @MainActor () async -> Void) {
        environment.actions.closeThen { Task { await action() } }
    }

    private func openChooser(_ tool: CaptureTool) async {
        defer { starting = false }
        hasAccess = CapturePermission.request(headless: environment.isHeadless)
        guard hasAccess else {
            if environment.isRunning, environment.visibleSections.contains(.captures) { environment.open(.captures) }
            else { CapturePermission.openSettings() }
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        pasteboardCount = NSPasteboard.general.changeCount
        let inIsland = controlsInIsland
        let excluded = CaptureOwnWindows.excluded(includeIsland: environment.settings.showInCaptures && !inIsland)
        do {
            let snapshot = try await CaptureSnapshot.take()
            var displays: [FrozenDisplay] = []
            for screen in NSScreen.screens {
                guard let display = snapshot.display(screen.captureDisplayID) else { continue }
                let image = try await CaptureShooter.display(snapshot.filter(display: display, excluding: excluded),
                                                             size: screen.frame.size, scale: screen.backingScaleFactor)
                displays.append(FrozenDisplay(displayID: display.displayID, frame: screen.frame, scale: screen.backingScaleFactor, image: image))
            }
            guard !displays.isEmpty else { NSSound.beep(); return }
            // The island may have stopped while the displays were being photographed.
            guard environment.isRunning else { return }
            session += 1
            let chooser = CaptureChooser(tool: tool, session: session, inIsland: inIsland, islandScreen: CaptureOwnWindows.islandScreen,
                                         settings: environment.settings, options: options, snapshot: snapshot, displays: displays,
                                         excluded: excluded, lastRegion: lastRegion) { [weak self] choice in
                self?.chooserFinished(choice)
            }
            self.chooser = chooser
            isChoosing = true
            environment.captureControlsActive = inIsland
            chooser.present()
        } catch {
            hasAccess = CapturePermission.isGranted
            NSSound.beep()
        }
    }

    private func chooserFinished(_ choice: CaptureChoice?) {
        chooser = nil
        isChoosing = false
        environment.captureControlsActive = false
        previousApp?.activate(options: [])
        previousApp = nil
        guard let choice else { return }
        if case .area(let rect) = choice.target { lastRegion = CaptureRegion(displayID: choice.display.displayID, rect: rect) }
        switch choice.tool {
        case .screenshot:
            Task { await takeScreenshot(choice) }
        case .recording:
            recording.begin(choice, options: options, includeIsland: environment.settings.showInCaptures)
        }
    }

    // MARK: Screenshot

    private func takeScreenshot(_ choice: CaptureChoice) async {
        let display = choice.display
        let still: CapturedStill
        switch choice.target {
        case .area(let rect):
            let scale = CGFloat(display.image.width) / display.frame.width
            guard let cropped = display.image.cropping(to: CaptureCoordinates.pixels(rect, scale: scale)) else { NSSound.beep(); return }
            still = CapturedStill(image: cropped, scale: scale)
        case .display:
            still = CapturedStill(image: display.image, scale: CGFloat(display.image.width) / display.frame.width)
        case .window(let info):
            guard let window = choice.snapshot.window(info.id),
                  let image = try? await CaptureShooter.window(window, scale: display.scale) else { NSSound.beep(); return }
            still = CapturedStill(image: image, scale: display.scale)
        }
        let screen = NSScreen.screens.first { $0.captureDisplayID == display.displayID }
        await deliver(still, screen: screen)
    }

    /// Encodes, saves and copies as the person chose, records the capture in the history, then shows
    /// the preview. A copy is skipped when something else reached the pasteboard meanwhile.
    private func deliver(_ still: CapturedStill, screen: NSScreen?) async {
        let date = Date()
        let action = options.afterAction
        let folder = options.resolvedSaveFolder
        let prepared = await Task.detached { () -> PreparedScreenshot? in
            guard let png = CaptureFiles.png(still.image, scale: still.scale) else { return nil }
            var saved: URL?
            var saveFailed = false
            if action.saves {
                do { saved = try CaptureFiles.save(png, date: date, in: folder) } catch { saveFailed = true }
            }
            let name = saved?.lastPathComponent ?? CaptureNaming.fileName(.screenshot, date: date)
            let transfer = action.copies ? try? CaptureFiles.transferCopy(png, named: name) : nil
            return PreparedScreenshot(png: png, thumbnail: CaptureFiles.thumbnail(still.image),
                                      preview: CaptureFiles.downscaled(still.image, pixels: CapturePreviewLayout.imagePixelLimit),
                                      saved: saved, saveFailed: saveFailed, transfer: transfer,
                                      tiff: action.copies ? CaptureFiles.tiff(png) : nil)
        }.value
        guard let prepared else { NSSound.beep(); return }

        let id = UUID()
        var files = [RecentCapturesStore.imageName(for: id): prepared.png]
        if let thumbnail = prepared.thumbnail { files[RecentCapturesStore.thumbnailName(for: id)] = thumbnail }
        let entry = RecentCapture(id: id, kind: .screenshot, date: date, fileURL: prepared.saved,
                                  imageName: RecentCapturesStore.imageName(for: id),
                                  thumbnailName: prepared.thumbnail == nil ? nil : RecentCapturesStore.thumbnailName(for: id),
                                  imageBytes: Int64(prepared.png.count), pixelWidth: still.image.width, pixelHeight: still.image.height)

        var copied = false
        if let transfer = prepared.transfer, NSPasteboard.general.changeCount == pasteboardCount {
            CapturePasteboard.copyImage(file: transfer, png: prepared.png, tiff: prepared.tiff)
            copied = true
        }
        await library.add(entry, files: files)

        if prepared.saveFailed { NSSound.beep() }
        let succeeded = action.isAutomatic && (!action.saves || prepared.saved != nil) && (!action.copies || copied)
        guard options.showsPreview, let image = prepared.preview else { return }
        let status: String
        switch (prepared.saved, copied) {
        case (.some, true): status = "Saved and copied"
        case (.some, false): status = "Saved to \(folder.lastPathComponent)"
        case (nil, true): status = "Copied"
        case (nil, false): status = prepared.saveFailed ? "Could not save to \(folder.lastPathComponent)" : ""
        }
        let points = CGSize(width: CGFloat(still.image.width) / still.scale, height: CGFloat(still.image.height) / still.scale)
        let item = CapturePreviewItem(entry: entry, image: NSImage(cgImage: image, size: points), png: prepared.png, status: status)
        preview.present(item, automaticActionSucceeded: succeeded, screen: screen)
    }

    private func recordingSaved(_ url: URL) {
        Task {
            let thumbnail = await CaptureFiles.firstFrame(of: url)
            let id = UUID()
            var files: [String: Data] = [:]
            if let thumbnail { files[RecentCapturesStore.thumbnailName(for: id)] = thumbnail }
            let entry = RecentCapture(id: id, kind: .recording, date: Date(), fileURL: url,
                                      thumbnailName: thumbnail == nil ? nil : RecentCapturesStore.thumbnailName(for: id))
            await library.add(entry, files: files)
        }
    }

}
