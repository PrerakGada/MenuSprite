import AppKit
import Combine
import IslandKit
import SwiftUI

/// Runs the Dynamic Island: decides what it shows, owns its window, and applies every opening,
/// closing, hover, click, gesture and display rule. Features start with the master switch; the window
/// exists only while the session is presentable and a display is chosen.
@MainActor
final class IslandController: NSObject {
    let environment: IslandEnvironment
    let presentation = IslandPresentation()
    private var settings: IslandSettings { environment.settings }

    // Window.
    private var panel: IslandPanel?
    private var host: IslandHostView?
    private var stage: IslandStageView?
    private var overlay: IslandWindowServer.OverlaySpace?
    private var screenID: CGDirectDisplayID?
    private var barHeights: [String: CGFloat] = [:]

    // State.
    private var observing = false
    private var featuresRunning = false
    private var sessionActive = true
    private var screensAwake = true
    private var fullScreen = false
    private var concealed = false
    private var peeking = false
    private var openedByHover = false
    private var clickedSinceOpen = false
    private var hoverSuppressed = false
    private var pointerInside = false
    private var chooserVisible = false
    private var revealed = false
    private var holds = 0
    private var menuTracking = 0
    private var visiblePage: IslandDestination?
    private var lastPage: IslandSectionID?
    private var edgePressed = false
    /// A file drag is under way: over the island (`dragOver`) or anywhere (`dragAnywhere`, for the
    /// "Show a drop target while dragging" reveal).
    private var dragOver = false
    private var dragAnywhere = false
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var dragMonitors: [Any] = []
    private var dragBaselined = false
    private var dragWatchdog: Task<Void, Never>?
    private var gesture = IslandGestureRecognizer()
    private var refreshPending = false
    /// Actions waiting for the island's closing animation to settle.
    private var afterClose: [@MainActor () -> Void] = []

    private var hoverTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var floatingTask: Task<Void, Never>?
    private var screenTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var centerObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var outsideMonitors: [Any] = []
    private var edgeMonitors: [Any] = []
    private var hiddenMonitors: [Any] = []
    private lazy var missionControl = IslandMissionControlWatch { [weak self] showing in self?.missionControlChanged(showing) }

    private static let lastPageKey = "MenuSprite.Island.LastPage"
    private static let closeDelay = 0.18
    private static let peekCloseDelay = 0.12

    init(environment: IslandEnvironment) {
        self.environment = environment
        lastPage = UserDefaults.standard.string(forKey: Self.lastPageKey).flatMap(IslandSectionID.init(rawValue:))
        super.init()
        environment.actions = IslandActions(
            open: { [weak self] destination in self?.open(destination, explicit: true) },
            close: { [weak self] in self?.close() },
            togglePin: { [weak self] in self?.togglePin() },
            invalidate: { [weak self] in self?.scheduleRefresh() },
            openSettings: { [weak self] section in self?.openSettings(section) },
            openAppPanel: { [weak self] in self?.openAppPanel() },
            holdOpen: { [weak self] hold in self?.hold(hold) },
            closeThen: { [weak self] action in
                guard let self, self.isOpen || self.peeking else { action(); return }
                self.afterClose.append(action)
                self.close()
            })
        environment.notices.canShow = { [weak self] in self?.showsSystemFeedback ?? false }
        environment.notices.indicatorEnabled = { [weak environment] in environment?.wants($0) ?? false }
    }

    // MARK: Public

    var isOpen: Bool { presentation.surface == .open }
    var isRunning: Bool { panel != nil }

    /// Installs observers and applies the saved settings. Call once at launch.
    func start() {
        guard !observing else { return }
        observing = true
        environment.settingsStore.$value
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.sync() } } }
            .store(in: &cancellables)
        environment.activities.$strips.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        environment.activities.$choice.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        environment.notices.$current.map { $0?.id }.removeDuplicates().sink { [weak self] _ in
            self?.presentation.noticeExpanded = false
            self?.scheduleRefresh()
        }.store(in: &cancellables)
        environment.notices.$current.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        environment.$revision.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        environment.$captureControlsActive.removeDuplicates().sink { [weak self] active in
            guard let self, active else { return }
            self.hoverTask?.cancel()
            self.peeking = false
            self.chooserVisible = false
            self.scheduleRefresh()
        }.store(in: &cancellables)
        installSystemObservers()
        sync()
    }

    /// Tears everything down at quit.
    func stop() {
        removeSystemObservers()
        cancellables.removeAll()
        observing = false
        teardownWindow()
        stopFeatures()
    }

    /// Opens a page. `nil` means "no page named": the reopening rule decides.
    func open(_ destination: IslandDestination?, explicit: Bool) {
        guard let panel, acceptsUserInteraction else { return }
        closeTask?.cancel()
        hoverTask?.cancel()
        let wasOpen = isOpen
        var target = destination ?? (wasOpen ? presentation.destination : reopenDestination())
        // A mirrored banner on the island points the opening at Notifications, and is retired so it
        // cannot reappear after collapsing; the inbox keeps the message.
        if let notice = environment.notices.current, notice.kind == .notification {
            if destination == nil, !wasOpen, environment.visibleSections.contains(.notifications) { target = .section(.notifications) }
            environment.notices.dismiss()
        }
        if !wasOpen {
            openedByHover = !explicit
            clickedSinceOpen = false
        } else if explicit {
            openedByHover = false
        }
        peeking = false
        chooserVisible = false
        if case .section(let id) = target { lastPage = id; UserDefaults.standard.set(id.rawValue, forKey: Self.lastPageKey) }
        if target == .explore { presentation.exploreQuery = "" }
        let changed = !wasOpen || presentation.destination != target
        presentation.destination = target
        presentation.surface = .open
        if explicit {
            panel.allowsKey = true
            panel.makeKey()
        }
        if changed { haptic() }
        installOutsideMonitors()
        removeEdgeMonitors()
        refresh(animated: true)
    }

    func close() {
        guard isOpen || peeking else { return }
        closeTask?.cancel()
        hoverTask?.cancel()
        peeking = false
        environment.isPinned = false
        openedByHover = false
        // Closing under a still pointer must not immediately re-open it by hover.
        if isPointerInside() { hoverSuppressed = true }
        presentation.surface = .rest
        presentation.floatingVisible = false
        panel?.allowsKey = false
        if panel?.isKeyWindow == true { panel?.resignKey() }
        removeOutsideMonitors()
        if panel != nil { installEdgeMonitors() }
        refresh(animated: true)
    }

    func toggle(_ destination: IslandDestination?) {
        if isOpen, destination == nil || destination == presentation.destination { close() }
        else { open(destination, explicit: true) }
    }

    /// Whether clicking MenuSprite's own menu-bar icon should open the app panel in the island.
    var routesAppPanel: Bool { settings.enabled && settings.appPanelInIsland && acceptsUserInteraction && environment.appPanel != nil }

    /// Whether the menu-bar icon should hide: the option is on, the island is up, and nothing hides it.
    var hidesMenuBarIcon: Bool { settings.hideMenuBarIcon && settings.enabled && panel != nil && !fullScreen }

    var menuBarIconChanged: (() -> Void)?

    // MARK: Sync

    private var previewing = false
    private var acceptsUserInteraction: Bool { (panel != nil || previewing) && sessionActive && screensAwake && !concealed }
    private var showsSystemFeedback: Bool {
        acceptsUserInteraction && !fullScreen && settings.opening != .hidden && !environment.captureControlsActive
    }

    private func sync() {
        if settings.enabled != featuresRunning {
            if settings.enabled { startFeatures() } else { stopFeatures() }
        }
        let screen = selectedScreen()
        let wantsWindow = settings.enabled && sessionActive && screensAwake && screen != nil
        if wantsWindow, let screen {
            let id = IslandHardware.displayID(of: screen)
            if panel == nil || id != screenID || stageSizeChanged(for: screen) {
                teardownWindow()
                createWindow(on: screen)
            } else {
                updateMetrics(for: screen)
            }
        } else {
            teardownWindow()
        }
        applyPanelSettings()
        syncFullScreenWatch()
        syncMissionControl()
        syncHiddenMonitors()
        syncDragMonitors()
        refresh(animated: false)
        menuBarIconChanged?()
    }

    private func startFeatures() {
        featuresRunning = true
        environment.isRunning = true
        for feature in environment.features { feature.islandDidStart() }
    }

    private func stopFeatures() {
        guard featuresRunning else { return }
        featuresRunning = false
        environment.isRunning = false
        setVisiblePage(nil)
        for feature in environment.features { feature.islandDidStop() }
        environment.notices.dismiss()
    }

    private func applyPanelSettings() {
        guard let panel else { return }
        panel.sharingType = settings.showInCaptures ? .readOnly : .none
    }

    // MARK: Displays

    private func selectedScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let infos = screens.map { screen in
            IslandScreenInfo(id: IslandHardware.displayID(of: screen),
                             isBuiltIn: CGDisplayIsBuiltin(IslandHardware.displayID(of: screen)) != 0,
                             isNotched: screen.safeAreaInsets.top > 0,
                             isPrimary: screen.frame.origin == .zero)
        }
        guard let id = IslandDisplaySelection.select(infos, choice: settings.display, hasLid: IslandHardware.hasLid) else { return nil }
        return screens.first { IslandHardware.displayID(of: $0) == id }
    }

    private func metrics(for screen: NSScreen) -> IslandDisplayMetrics {
        let key = "\(IslandHardware.displayID(of: screen))-\(Int(screen.frame.width))x\(Int(screen.frame.height))@\(screen.backingScaleFactor)"
        let gap = screen.frame.maxY - screen.visibleFrame.maxY
        let bar = IslandBarHeight.resolve(measuredGap: gap, remembered: barHeights[key], systemThickness: NSStatusBar.system.thickness)
        if IslandBarHeight.valid.contains(gap) { barHeights[key] = gap }
        return IslandDisplayMetrics.make(frame: screen.frame, auxiliaryLeft: screen.auxiliaryTopLeftArea,
                                         auxiliaryRight: screen.auxiliaryTopRightArea, safeAreaTop: screen.safeAreaInsets.top,
                                         barHeight: bar, scale: screen.backingScaleFactor)
    }

    private func stageSizeChanged(for screen: NSScreen) -> Bool {
        stage.map { $0.frame.size != screen.frame.size } ?? true
    }

    private func updateMetrics(for screen: NSScreen) {
        presentation.display = metrics(for: screen)
        environment.stripHeight = presentation.display?.cutout.height ?? 32
        environment.stripIsPhysical = presentation.display?.cutout.isPhysical ?? true
    }

    // MARK: Window

    private func createWindow(on screen: NSScreen) {
        createWindow(display: metrics(for: screen), screenID: IslandHardware.displayID(of: screen), overlaySpace: true)
    }

    /// The window for a display. The window check builds it on a display parked off-screen, with no
    /// overlay Space, to capture the real mask and layers without showing anything.
    private func createWindow(display: IslandDisplayMetrics, screenID: CGDirectDisplayID, overlaySpace: Bool) {
        self.screenID = screenID
        presentation.display = display
        environment.stripHeight = display.cutout.height
        environment.stripIsPhysical = display.cutout.isPhysical
        presentation.stage = display.frame.size
        let stage = IslandStageView(size: display.frame.size)
        let commands = makeCommands()
        let content = IslandHostingView(rootView: IslandRootView(presentation: presentation, environment: environment,
                                                                 activities: environment.activities, notices: environment.notices,
                                                                 commands: commands))
        content.sizingOptions = []
        let floating = IslandHostingView(rootView: IslandFloatingView(presentation: presentation, environment: environment,
                                                                      settings: environment.settingsStore, commands: commands))
        floating.sizingOptions = []
        // The floating layer spans the whole stage; it may only take clicks on the button circles.
        floating.hitArea = { [weak self] point in
            guard let self, self.presentation.floatingVisible, let placement = self.floatingPlacement else { return false }
            return placement.slot(at: CGPoint(x: point.x - self.islandRect.minX, y: point.y)) != nil
        }
        stage.install(content: content, floating: floating)
        stage.setOrigin { [weak presentation] size in presentation?.origin(for: size) ?? .zero }
        stage.activation.pressed = { [weak self] in self?.activationPressed() }
        stage.activation.released = { [weak self] in self?.activationReleased() }
        let host = IslandHostView(stage: stage)
        host.takesMouse = { [weak self] point in self?.takesMouse(point) ?? false }
        host.trackingChanged = { [weak self] _ in self?.pointerMoved() }
        host.acceptDrags(of: ShelfPasteboard.dropTypes)
        host.accepts = { [weak self] pasteboard in
            guard let self, self.environment.pasteboardDrop != nil || self.environment.fileDrop != nil else { return false }
            return ShelfPasteboard.hasDroppableType(pasteboard)
        }
        host.dragEntered = { [weak self] in
            guard let self, !self.isOpen, self.environment.pasteboardDrop != nil || self.environment.fileDrop != nil,
                  self.acceptsUserInteraction else { return false }
            self.dragOver = true
            self.presentation.dropHovering = true
            self.refresh(animated: true)
            return true
        }
        host.dragExited = { [weak self] in
            guard let self else { return }
            self.dragOver = false
            self.presentation.dropHovering = false
            self.refresh(animated: true)
        }
        host.dropped = { [weak self] pasteboard in
            guard let self else { return false }
            self.dragOver = false
            self.dragAnywhere = false
            self.presentation.dropHovering = false
            let accepted: Bool
            if let accept = self.environment.pasteboardDrop {
                accepted = accept(pasteboard)
            } else if let accept = self.environment.fileDrop {
                let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
                accepted = !urls.isEmpty && accept(urls)
            } else { accepted = false }
            self.refresh(animated: true)
            if accepted { self.open(.section(.files), explicit: false) }
            return accepted
        }
        let panel = IslandPanel()
        panel.contentView = host
        panel.scrollHandler = { [weak self] event in self?.scroll(event) ?? false }
        panel.keyHandler = { [weak self] event in self?.key(event) ?? false }
        self.stage = stage
        self.host = host
        self.panel = panel
        let size = closedTarget().size
        presentation.size = size
        panel.setFrame(windowFrame(for: size, open: false), display: false)
        host.positionStage()
        stage.animate(IslandMotionPlan.plan(from: size, to: size), outline: outlineColor) {}
        // The window joins its own Space before it is first ordered in.
        if overlaySpace {
            overlay = IslandWindowServer.OverlaySpace()
            overlay?.add(panel)
        }
        panel.orderFrontRegardless()
        applyPanelSettings()
        installEdgeMonitors()
        updateHitAreas()
        environment.isOpen = false
    }

    private func runAfterClose() {
        let actions = afterClose
        afterClose = []
        actions.forEach { $0() }
    }

    private func teardownWindow() {
        defer { runAfterClose() }
        guard let panel else { return }
        setVisiblePage(nil)
        removeOutsideMonitors()
        removeEdgeMonitors()
        removeHiddenMonitors()
        for monitor in dragMonitors { NSEvent.removeMonitor(monitor) }
        dragMonitors = []
        hoverTask?.cancel(); closeTask?.cancel(); floatingTask?.cancel()
        panel.orderOut(nil)
        overlay?.destroy()
        overlay = nil
        panel.contentView = nil
        panel.scrollHandler = nil
        panel.keyHandler = nil
        self.panel = nil
        host = nil
        stage = nil
        screenID = nil
        presentation.surface = .rest
        presentation.floatingVisible = false
        environment.isOpen = false
        environment.isPinned = false
        peeking = false
        chooserVisible = false
    }

    /// The window: the island's envelope plus room for hover growth, floating-button gutters and a
    /// bottom inset, with whole, equal margins so the settled island never shifts a pixel.
    private func windowFrame(for envelope: CGSize, open: Bool) -> NSRect {
        guard let display = presentation.display else { return .zero }
        let floating = environment.liveFloating
        let sides = open && (!floating.buttons(on: .left).isEmpty || !floating.buttons(on: .right).isEmpty)
        let bottom = open && !floating.buttons(on: .bottom).isEmpty
        let wanted = envelope.width + 2 * (sides ? IslandGeometry.gutter : 14)
        let margin = max(0, floor((display.frame.width - wanted) / 2))
        var height = envelope.height + (bottom ? IslandGeometry.gutter : 10)
        if open, sides { height = max(height, envelope.height + 12, 3 * IslandFloatingPlacement.spacing + 60) }
        height = min(display.frame.height, ceil(height))
        return NSRect(x: display.frame.minX + margin, y: display.frame.maxY - height,
                      width: display.frame.width - 2 * margin, height: height)
    }

    // MARK: Presentation

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshPending = false
                self?.refresh(animated: true)
            }
        }
    }

    private struct Target {
        var surface: IslandPresentation.Surface
        var size: CGSize
        var restWing: CGFloat = 0
        var activityWing: CGFloat = 0
        var noticeWing: CGFloat = 0
    }

    private var sideRoom: CGFloat? {
        guard let display = presentation.display else { return nil }
        // Show over the menus: the room an empty menu bar would give. Measuring real menus is not built;
        // with the option off, a physical notch keeps its wings off and a simulated one rests bare.
        return settings.coversMenus ? IslandGeometry.emptyBarRoom(display) : nil
    }

    private func closedTarget() -> Target {
        guard let display = presentation.display else { return Target(surface: .rest, size: .zero) }
        let camera = CGSize(width: display.cutout.width, height: display.cutout.height)
        if fullScreen {
            return display.cutout.isPhysical ? Target(surface: .rest, size: camera) : Target(surface: .hidden, size: CGSize(width: camera.width, height: 0))
        }
        if settings.opening == .hidden && !revealed {
            return Target(surface: .hidden, size: CGSize(width: camera.width, height: 0))
        }
        if (dragOver || dragAnywhere), environment.pasteboardDrop != nil || environment.fileDrop != nil, acceptsUserInteraction {
            let peek = IslandGeometry.peek(display)
            return Target(surface: .dropTarget, size: CGSize(width: peek.width, height: display.cutout.height + 10 + 66))
        }
        if let notice = environment.notices.current, showsSystemFeedback {
            if presentation.noticeExpanded, notice.expanded != nil {
                let openWidth = IslandGeometry.openWidth(display, settings: settings)
                let width = min(max(400, display.cutout.width + 200), openWidth)
                let height = min(display.frame.height - 48, display.cutout.height + 10 + notice.expandedHeight + 16)
                return Target(surface: .notice, size: CGSize(width: width, height: height))
            }
            let wing = noticeWing(notice, display: display)
            return Target(surface: .notice, size: IslandGeometry.strip(display, wing: wing), noticeWing: wing)
        }
        if peeking { return Target(surface: .peek, size: IslandGeometry.peek(display)) }
        let live = environment.activities.live
        if chooserVisible, live.count >= 2, let strip = activityTarget(display) {
            let size = ActivityChooserView.layout(live: IslandActivityKind.allCases.filter(live.contains),
                                                  combos: live.contains(.timer), stripWidth: strip.size.width,
                                                  stripHeight: strip.size.height, maxWidth: IslandGeometry.maxStripWidth(display))
            return Target(surface: .chooser, size: size, activityWing: strip.activityWing)
        }
        if let activity = activityTarget(display) { return emphasised(activity, display: display) }
        var rest = Target(surface: .rest, size: camera)
        if environment.rests[settings.atRest]?.wings() != nil {
            let wing = IslandGeometry.restingWing(room: sideRoom)
            rest.restWing = wing
            rest.size = wing > 0 ? IslandGeometry.strip(display, wing: wing) : camera
        } else if !display.cutout.isPhysical, !settings.coversMenus {
            return Target(surface: .hidden, size: CGSize(width: camera.width, height: 0))
        }
        return emphasised(rest, display: display)
    }

    private func activityTarget(_ display: IslandDisplayMetrics) -> Target? {
        guard let resolved = environment.activities.resolved else { return nil }
        let strip = resolved.primary
        let room = sideRoom ?? 0
        let wing = strip.wingForRoom?(room, display.cutout.height) ?? (room >= strip.minimumRoom ? min(strip.wing, room) : 0)
        return Target(surface: .activity, size: IslandGeometry.strip(display, wing: wing), activityWing: wing)
    }

    /// The closed island grows a little under the pointer.
    private func emphasised(_ target: Target, display: IslandDisplayMetrics) -> Target {
        guard pointerInside, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return target }
        var copy = target
        copy.size = IslandGeometry.hoverEmphasis(target.size, display: display, room: sideRoom,
                                                  currentWing: max(target.restWing, target.activityWing))
        return copy
    }

    private func noticeWing(_ notice: IslandNotice, display: IslandDisplayMetrics) -> CGFloat {
        switch notice.style {
        case .level: return IslandNoticeWings.level
        case .custom(let wing, _, _): return min(wing, IslandGeometry.maxStripWidth(display) / 2)
        case .text(let symbol, let image, let title, let detail, let gap, let maxWing, _, let meter):
            // The 26 pt the rule adds to the title covers its symbol and gap.
            _ = (symbol, image)
            let right = meter != nil ? 64 : IslandTextMetrics.width(detail)
            return IslandNoticeWings.text(titleWidth: IslandTextMetrics.width(title), detailWidth: right,
                                          cameraGap: gap, maximum: maxWing)
        }
    }

    private func openTarget() -> (Target, IslandOpenLayout, IslandPageContext)? {
        guard let display = presentation.display else { return nil }
        let destination = presentation.destination
        let vertical: Bool
        switch destination {
        case .section(let id): vertical = environment.sections[id]?.isVertical ?? false
        case .explore, .appPanel: vertical = true
        }
        let bottom = !environment.liveFloating.buttons(on: .bottom).isEmpty
        let fullRow = destination.section.flatMap { environment.sections[$0]?.wantsFullHeaderRow } ?? false
        let probe = IslandGeometry.openLayout(display, settings: settings, page: .fill, vertical: vertical,
                                              forceFullHeaderRow: fullRow, hasBottomButtons: bottom)
        let context = IslandPageContext(width: probe.contentWidth, budget: probe.budget, isPreview: false, environment: environment)
        let request: IslandPageHeight
        switch destination {
        case .section(let id): request = environment.sections[id]?.pageHeight(context) ?? .fill
        case .explore:
            let count = IslandNavigation.search(presentation.exploreQuery, in: environment.visibleSections).count
            let paging = IslandExplorePaging(count: count, contentWidth: probe.contentWidth, height: probe.budget)
            let rows = CGFloat(min(paging.rows, paging.visibleRows))
            request = .fixed(count == 0 ? 140 : rows * IslandExplorePaging.tileHeight + (rows - 1) * IslandExplorePaging.spacing)
        case .appPanel: request = .fill
        }
        let layout = IslandGeometry.openLayout(display, settings: settings, page: request, vertical: vertical,
                                               forceFullHeaderRow: fullRow, hasBottomButtons: bottom)
        let finalContext = IslandPageContext(width: layout.contentWidth, budget: layout.budget, isPreview: false, environment: environment)
        return (Target(surface: .open, size: CGSize(width: layout.width, height: layout.height)), layout, finalContext)
    }

    /// Recomputes what the island shows and animates to it.
    private func refresh(animated: Bool) {
        guard let stage, let panel else { return }
        // A destination that stopped being visible falls back to the first visible page.
        if isOpen, case .section(let id) = presentation.destination, !environment.visibleSections.contains(id) {
            presentation.destination = .section(environment.visibleSections.first ?? .controls)
        }
        var target: Target
        if isOpen, let open = openTarget() {
            target = open.0
            presentation.openLayout = open.1
            presentation.pageContext = open.2
            setVisiblePage(presentation.destination)
        } else {
            target = closedTarget()
            presentation.openLayout = nil
            setVisiblePage(nil)
        }
        let from = stage.presentedSize(fallback: presentation.size)
        apply(target)
        environment.isOpen = isOpen
        environment.destination = isOpen ? presentation.destination : nil
        environment.isKey = panel.isKeyWindow
        updateActivationArea()
        guard animated || from != target.size else {
            updateHitAreas()
            return
        }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let plan = animated ? IslandMotionPlan.plan(from: from, to: target.size, reduceMotion: reduce)
                            : IslandMotionPlan.plan(from: target.size, to: target.size)
        let envelope = CGSize(width: max(plan.envelope.width, from.width) + 2 * IslandMotionPlan.overshootLimit,
                              height: max(plan.envelope.height, from.height) + IslandMotionPlan.overshootLimit)
        let reserve = windowFrame(for: envelope, open: isOpen)
        if !panel.frame.contains(reserve) {
            panel.setFrame(panel.frame.union(reserve), display: false)
            host?.positionStage()
        }
        floatingTask?.cancel()
        if isOpen {
            let arrival = plan.arrival
            floatingTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(arrival))
                guard !Task.isCancelled else { return }
                self?.presentation.floatingVisible = true
                self?.updateHitAreas()
            }
        } else {
            presentation.floatingVisible = false
        }
        let open = isOpen
        stage.animate(plan, outline: outlineColor) { [weak self] in
            guard let self, let panel = self.panel else { return }
            // Settled: shrink the window to what the island now needs.
            let settled = self.windowFrame(for: self.presentation.size, open: open)
            if panel.frame != settled {
                panel.setFrame(settled, display: false)
                self.host?.positionStage()
            }
            self.updateHitAreas()
            if !open { self.runAfterClose() }
        }
        updateHitAreas()
    }

    private func apply(_ target: Target) {
        presentation.restWing = target.restWing
        presentation.activityWing = target.activityWing
        presentation.noticeWing = target.noticeWing
        if presentation.surface != target.surface { presentation.surface = target.surface }
        presentation.size = target.size
    }

    /// For the window check: the real panel on a display parked far off-screen, features off.
    func harnessWindow(display: IslandDisplayMetrics) -> NSWindow? {
        previewing = true
        createWindow(display: display, screenID: 0, overlaySpace: false)
        return panel
    }

    /// For the render harness: lays the presentation out for one state without any window.
    func preview(display: IslandDisplayMetrics, open destination: IslandDestination?, hovering: Bool = false) {
        presentation.display = display
        presentation.stage = display.frame.size
        previewing = true
        defer { previewing = false }
        pointerInside = hovering
        if let destination {
            presentation.destination = destination
            presentation.surface = .open
            guard let open = openTarget() else { return }
            presentation.openLayout = open.1
            presentation.pageContext = open.2
            apply(open.0)
            presentation.floatingVisible = true
        } else {
            presentation.surface = .rest
            presentation.openLayout = nil
            presentation.floatingVisible = false
            apply(closedTarget())
        }
        pointerInside = false
    }

    private var outlineColor: NSColor? {
        guard settings.outline, !fullScreen, presentation.surface != .hidden else { return nil }
        if presentation.surface == .activity, environment.activities.resolved?.primary.kind == .timer { return .systemOrange }
        return NSColor.white.withAlphaComponent(0.65)
    }

    // MARK: Hit testing and hover

    /// The island's rectangle in stage coordinates.
    private var islandRect: CGRect { CGRect(origin: presentation.origin, size: presentation.size) }

    private var floatingPlacement: IslandFloatingPlacement? {
        guard isOpen, let layout = presentation.openLayout, let display = presentation.display else { return nil }
        return IslandFloatingPlacement.make(layout: environment.liveFloating, island: presentation.size, headerTop: layout.headerTop,
                                            headerHeight: layout.headerHeight, barHeight: display.barHeight)
    }

    private func takesMouse(_ point: CGPoint) -> Bool {
        guard presentation.surface != .hidden else { return false }
        let local = CGPoint(x: point.x - islandRect.minX, y: point.y)
        if IslandSilhouette(width: islandRect.width, height: islandRect.height).contains(local) { return true }
        if presentation.floatingVisible, let placement = floatingPlacement, placement.slot(at: local) != nil { return true }
        return false
    }

    private func updateHitAreas() {
        guard let host else { return }
        var rect = islandRect
        if presentation.surface == .hidden, let display = presentation.display {
            rect = CGRect(x: presentation.origin(for: CGSize(width: display.cutout.width, height: 0)).x, y: 0,
                          width: display.cutout.width, height: display.cutout.height)
        }
        if let placement = floatingPlacement {
            for corridor in placement.corridors { rect = rect.union(corridor.offsetBy(dx: islandRect.minX, dy: 0)) }
        }
        host.updateTracking(rect)
    }

    /// The transparent activation button: the whole closed island, the camera width for compact
    /// activities (wings keep their own buttons), the camera itself when open with a split header,
    /// nothing for notices.
    private func updateActivationArea() {
        guard let stage, let display = presentation.display else { return }
        let camera = display.cutout
        let island = islandRect
        let cameraRect = CGRect(x: island.midX - camera.width / 2, y: 0, width: camera.width, height: camera.height)
        var frame: CGRect?
        switch presentation.surface {
        case .rest: frame = island
        case .activity, .chooser: frame = cameraRect
        case .peek: frame = CGRect(x: island.minX, y: 0, width: island.width, height: camera.height + 10)
        case .open:
            if let layout = presentation.openLayout {
                if layout.headerBesideCamera { frame = cameraRect }
                else if camera.isPhysical { frame = CGRect(x: island.minX, y: 0, width: island.width, height: camera.height + 10) }
            }
        case .notice, .hidden, .dropTarget: frame = nil
        }
        stage.activation.isHidden = frame == nil
        if let frame { stage.activation.frame = frame }
        stage.activation.setAccessibilityLabel(isOpen ? "Collapse" : "Open Dynamic Island")
    }

    /// Screen-coordinate island rectangle plus corridors, for re-checking the pointer on every event.
    private func isPointerInside() -> Bool {
        guard let panel, let stage else { return false }
        let point = stage.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        if presentation.surface == .hidden, let display = presentation.display {
            let x = presentation.origin(for: CGSize(width: display.cutout.width, height: 0)).x
            return CGRect(x: x, y: 0, width: display.cutout.width, height: display.cutout.height).contains(point)
        }
        if islandRect.insetBy(dx: 0, dy: -1).contains(point) { return true }
        if let placement = floatingPlacement {
            let local = CGPoint(x: point.x - islandRect.minX, y: point.y)
            return placement.corridorContains(local)
        }
        return false
    }

    private func pointerMoved() {
        let inside = isPointerInside()
        guard inside != pointerInside else { return }
        pointerInside = inside
        presentation.hovering = inside
        if inside { pointerEntered() } else { pointerLeft() }
    }

    private func pointerEntered() {
        closeTask?.cancel()
        // The capture controls sit over the island while an area is picked; it stays closed and quiet.
        if environment.captureControlsActive { return }
        if presentation.surface == .notice, let notice = environment.notices.current, notice.expanded != nil {
            // A banner under the pointer is held; resting on it opens the full message in place.
            environment.notices.hold()
            if settings.opening != .click, !hoverSuppressed { scheduleNoticeExpansion(notice.id) }
            return
        }
        guard !hoverSuppressed, acceptsUserInteraction else { scheduleRefresh(); return }
        if !isOpen, !peeking {
            if environment.activities.live.count >= 2, !fullScreen {
                chooserVisible = true
                refresh(animated: true)
                return
            }
            if settings.opening.usesHover { scheduleHoverOpen() }
        }
        refresh(animated: true)
    }

    private func pointerLeft() {
        hoverTask?.cancel()
        if presentation.surface == .notice {
            if presentation.noticeExpanded {
                closeTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.closeDelay))
                    guard !Task.isCancelled, let self, !self.pointerInside else { return }
                    self.presentation.noticeExpanded = false
                    self.environment.notices.dismiss()
                }
            } else {
                environment.notices.resume()
            }
        }
        hoverSuppressed = false
        if chooserVisible { chooserVisible = false }
        if isOpen, openedByHover, !clickedSinceOpen, !isHeld {
            closeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.closeDelay))
                guard !Task.isCancelled, let self, !self.pointerInside else { return }
                self.close()
                if self.settings.opening == .hidden { self.revealed = false; self.refresh(animated: true) }
            }
        } else if peeking {
            closeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.peekCloseDelay))
                guard !Task.isCancelled, let self, !self.pointerInside else { return }
                self.peeking = false
                self.refresh(animated: true)
            }
        } else if settings.opening == .hidden, revealed, !isOpen {
            revealed = false
        }
        refresh(animated: true)
    }

    private func scheduleHoverOpen() {
        hoverTask?.cancel()
        let delay = settings.hoverDelay
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            // Everything is checked again at the deadline.
            guard self.pointerInside, !self.hoverSuppressed, !self.isOpen, !self.peeking, !self.isHeld,
                  self.acceptsUserInteraction, self.settings.opening.usesHover, self.isPointerInside() else { return }
            if self.settings.opening == .preview, self.environment.activities.resolved == nil {
                self.peeking = true
                self.presentation.destination = self.reopenDestination()
                self.haptic()
                self.installOutsideMonitors()
                self.refresh(animated: true)
            } else {
                if self.settings.opening == .hidden { self.revealed = true }
                self.open(nil, explicit: false)
            }
        }
    }

    private func scheduleNoticeExpansion(_ id: UUID) {
        hoverTask?.cancel()
        let delay = settings.hoverDelay
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.pointerInside, self.environment.notices.current?.id == id else { return }
            self.presentation.noticeExpanded = true
            self.haptic()
            self.refresh(animated: true)
        }
    }

    private var isHeld: Bool { environment.isPinned || holds > 0 || menuTracking > 0 || PanelInteraction.isSuspended }

    private func hold(_ on: Bool) {
        holds = max(0, holds + (on ? 1 : -1))
    }

    private func activationPressed() {
        hoverTask?.cancel()
        hoverSuppressed = true
    }

    private func activationReleased() {
        guard !environment.captureControlsActive else { return }
        if isOpen { close() } else { open(nil, explicit: true) }
    }

    private func reopenDestination() -> IslandDestination {
        let activity = environment.activities.resolved?.primary.kind.section
        return IslandNavigation.reopenDestination(settings: settings, visible: environment.visibleSections,
                                                  lastPage: lastPage, activity: activity)
    }

    private func togglePin() {
        environment.isPinned.toggle()
        if environment.isPinned { openedByHover = false }
    }

    private func openSettings(_ section: IslandSectionID?) {
        close()
        environment.showSettings(section)
    }

    private func openAppPanel() {
        if routesAppPanel { toggle(.appPanel) } else { close(); environment.showHubTab(.system) }
    }

    private func haptic() {
        guard settings.haptics, settings.enabled, panel != nil else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    private func setVisiblePage(_ destination: IslandDestination?) {
        guard destination != visiblePage else { return }
        switch visiblePage {
        case .section(let id): environment.sections[id]?.pageDidDisappear()
        case .appPanel: environment.appPanelVisibility(false)
        default: break
        }
        visiblePage = destination
        switch destination {
        case .section(let id): environment.sections[id]?.pageDidAppear()
        case .appPanel: environment.appPanelVisibility(true)
        default: break
        }
    }

    // MARK: Commands from the views

    private func makeCommands() -> IslandCommands {
        IslandCommands(
            open: { [weak self] destination in self?.open(destination, explicit: true) },
            close: { [weak self] in self?.close() },
            togglePin: { [weak self] in self?.togglePin() },
            openSettings: { [weak self] in
                guard let self else { return }
                self.openSettings(self.presentation.destination.section)
            },
            choose: { [weak self] kind in
                guard let self else { return }
                self.environment.activities.choice.choose(kind, live: self.environment.activities.live)
                self.hoverTask?.cancel()
            },
            combine: { [weak self] kind in
                guard let self else { return }
                let activities = self.environment.activities
                activities.choice.combine(kind, live: activities.live, timerRunning: activities.timerRunning)
            },
            noticeClicked: { [weak self] in
                guard let self, let notice = self.environment.notices.current else { return }
                self.environment.notices.dismiss()
                if let action = notice.action { action() } else {
                    self.open(.section(notice.destination ?? notice.kind.section), explicit: true)
                }
            },
            headerHover: { [weak self] hovering in self?.presentation.headerHover = hovering },
            floating: { [weak self] action in self?.perform(action) })
    }

    private func perform(_ action: IslandFloatingAction) {
        switch action {
        case .explore: open(presentation.destination == .explore ? .section(lastPage ?? .controls) : .explore, explicit: true)
        case .settings: openSettings(presentation.destination.section)
        case .pin: togglePin()
        case .section(let id): open(.section(id), explicit: true)
        case .control(let id): environment.controls[id]?.perform()
        }
    }

    // MARK: Keyboard and gestures

    private func key(_ event: NSEvent) -> Bool {
        guard isOpen, event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 {
            if presentation.destination == .explore { open(.section(lastPage ?? .controls), explicit: true) } else { close() }
            return true
        }
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command, characters == "k" {
            open(presentation.destination == .explore ? .section(lastPage ?? .controls) : .explore, explicit: true)
            return true
        }
        if flags == [.command, .option], let letter = characters.first,
           let section = IslandNavigation.section(forShortcut: letter, visible: environment.visibleSections) {
            open(.section(section), explicit: true)
            return true
        }
        if event.keyCode == 48, flags.contains(.control) {
            let forward = !flags.contains(.shift)
            if let next = IslandNavigation.cycle(from: presentation.destination.section, visible: environment.visibleSections, forward: forward) {
                open(.section(next), explicit: true)
            }
            return true
        }
        if event.isReloadShortcut {
            environment.monitoring.refresh()
            return true
        }
        return false
    }

    private func scroll(_ event: NSEvent) -> Bool {
        guard settings.gestures, acceptsUserInteraction else { return false }
        let phase: IslandScrollSample.Phase
        if event.phase.contains(.began) { phase = .began }
        else if event.phase.contains(.mayBegin) { phase = .mayBegin }
        else if event.phase.contains(.ended) { phase = .ended }
        else if event.phase.contains(.cancelled) { phase = .cancelled }
        else if event.phase.contains(.changed) || event.phase.contains(.stationary) { phase = .changed }
        else { phase = .none }
        let sample = IslandScrollSample(deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY),
                                        precise: event.hasPreciseScrollingDeltas, inverted: event.isDirectionInvertedFromDevice,
                                        phase: phase, momentum: event.momentumPhase != [], timestamp: event.timestamp,
                                        modifiers: !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty)
        let action = gesture.handle(sample) { [weak self] in self?.gestureOrigin(event) ?? .none }
        switch action {
        case .open: open(nil, explicit: true); return true
        case .close: close(); return true
        case .nextTrack: return environment.musicSkip?(true) ?? false
        case .previousTrack: return environment.musicSkip?(false) ?? false
        case nil: return false
        }
    }

    /// Where a scroll started decides which gestures it may make: controls and text keep their input,
    /// scroll views keep vertical scrolling, the header and closed island allow opening/closing, music
    /// surfaces allow track swipes.
    private func gestureOrigin(_ event: NSEvent) -> IslandGestureOrigin {
        guard let host, let stage else { return .none }
        let point = stage.convert(event.locationInWindow, from: nil)
        var view = host.hitTest(host.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
        var overControl = false, overScroll = false
        while let current = view {
            if current is NSScrollView { overScroll = true }
            if (current is NSControl && !(current is IslandActivationView)) || current is NSTextView { overControl = true }
            view = current.superview
        }
        let music = (presentation.surface == .activity && environment.activities.resolved?.primary.kind == .music)
            || (isOpen && presentation.destination == .section(.music))
        let inHeader: Bool = {
            guard let layout = presentation.openLayout else { return false }
            return point.y <= layout.headerTop + layout.headerHeight
        }()
        let vertical = !overControl && (!isOpen || inHeader || (music && !overScroll))
        let horizontal = !overControl && !overScroll && !inHeader && music
        return IslandGestureOrigin(vertical: vertical, horizontal: horizontal, islandOpen: isOpen)
    }

    // MARK: Monitors

    private func installOutsideMonitors() {
        guard outsideMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.outsideClick() }
        }) { outsideMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.window === self.panel { self.clickedSinceOpen = true } else { self.outsideClick() }
            }
            return event
        }) { outsideMonitors.append(local) }
    }

    private func removeOutsideMonitors() {
        for monitor in outsideMonitors { NSEvent.removeMonitor(monitor) }
        outsideMonitors = []
    }

    private func outsideClick() {
        guard isOpen || peeking, !isHeld, !isPointerInside() else { return }
        // Someone typing on the Accessibility Keyboard clicks for every key.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.AccessibilityVisualsAgent" { return }
        close()
    }

    /// The menu bar owns the screen's top pixel row even above the island, so a click there never reaches
    /// the window. Watch presses there over the closed island and open on release.
    private func installEdgeMonitors() {
        guard edgeMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        let handler: (NSEvent) -> Void = { [weak self] event in
            let location = NSEvent.mouseLocation
            let type = event.type
            MainActor.assumeIsolated { self?.edgeEvent(type, at: location) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { edgeMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in handler(event); return event }) {
            edgeMonitors.append(local)
        }
    }

    private func removeEdgeMonitors() {
        for monitor in edgeMonitors { NSEvent.removeMonitor(monitor) }
        edgeMonitors = []
        edgePressed = false
    }

    private func edgeEvent(_ type: NSEvent.EventType, at location: NSPoint) {
        guard let display = presentation.display, !isOpen, presentation.surface != .notice, presentation.surface != .hidden || settings.opening == .hidden else {
            edgePressed = false; return
        }
        let camera = display.cutout
        let area = CGRect(x: display.frame.midX - max(camera.width, presentation.size.width) / 2, y: display.frame.maxY - max(camera.height, presentation.size.height),
                          width: max(camera.width, presentation.size.width), height: max(camera.height, presentation.size.height) + 1)
        switch type {
        case .leftMouseDown:
            edgePressed = area.contains(location) && location.y >= display.frame.maxY - 1
            if edgePressed { hoverTask?.cancel(); hoverSuppressed = true }
        case .leftMouseDragged:
            edgePressed = false
        case .leftMouseUp:
            if edgePressed, area.contains(location) { edgePressed = false; open(nil, explicit: true) }
            edgePressed = false
        default: break
        }
    }

    /// Hidden until hover: nothing is on screen, so pointer movement is watched instead.
    private func syncHiddenMonitors() {
        let wanted = panel != nil && settings.opening == .hidden
        if wanted, hiddenMonitors.isEmpty {
            let handler: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.pointerMoved() } }
            if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: handler) { hiddenMonitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in handler(event); return event }) {
                hiddenMonitors.append(local)
            }
        } else if !wanted {
            removeHiddenMonitors()
        }
    }

    /// "Show a drop target while dragging": a file drag starting anywhere reveals the drop target, so
    /// there is somewhere to drag to. Costs one callback per drag event, only while a drag is under way.
    private func syncDragMonitors() {
        let wanted = panel != nil && settings.dragReveal && environment.revealsDrag != nil
            && environment.visibleSections.contains(.files) && settings.filesInIsland
        if wanted, dragMonitors.isEmpty {
            if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp], handler: { [weak self] event in
                let type = event.type
                let window = event.windowNumber
                MainActor.assumeIsolated { self?.globalDrag(type, window: window) }
            }) { dragMonitors.append(global) }
        } else if !wanted {
            for monitor in dragMonitors { NSEvent.removeMonitor(monitor) }
            dragMonitors = []
            dragWatchdog?.cancel()
        }
    }

    /// The drag pasteboard's change count is baselined at mouse-down, so moving a window (which also
    /// drags) never counts; a changed pasteboard with droppable content during the drag is a real drag.
    private func globalDrag(_ type: NSEvent.EventType, window: Int) {
        let pasteboard = NSPasteboard(name: .drag)
        switch type {
        case .leftMouseDown:
            dragChangeCount = pasteboard.changeCount
            dragBaselined = true
        case .leftMouseUp:
            endGlobalDrag()
        default:
            if !dragBaselined { dragChangeCount = pasteboard.changeCount; dragBaselined = true; return }
            guard !dragAnywhere, !isOpen, pasteboard.changeCount != dragChangeCount else { return }
            dragChangeCount = pasteboard.changeCount
            guard environment.revealsDrag?(pasteboard, window) == true else { return }
            dragAnywhere = true
            refresh(animated: true)
            // Mouse-ups can be swallowed by the drag session; watch the button itself.
            dragWatchdog?.cancel()
            dragWatchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(150))
                    if !CGEventSource.buttonState(.combinedSessionState, button: .left) { self?.endGlobalDrag(); return }
                }
            }
        }
    }

    private func endGlobalDrag() {
        dragBaselined = false
        dragWatchdog?.cancel()
        guard dragAnywhere else { return }
        dragAnywhere = false
        // Give a drop on the island time to land before the target withdraws.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh(animated: true) }
    }

    private func removeHiddenMonitors() {
        for monitor in hiddenMonitors { NSEvent.removeMonitor(monitor) }
        hiddenMonitors = []
    }

    // MARK: System observers

    private func installSystemObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let add: (Notification.Name, @escaping @MainActor () -> Void) -> Void = { [weak self] name, body in
            guard let self else { return }
            self.workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { body() }
            })
        }
        add(NSWorkspace.willSleepNotification) { [weak self] in self?.sessionChanged(active: false) }
        add(NSWorkspace.didWakeNotification) { [weak self] in self?.sessionChanged(active: true) }
        add(NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.sessionChanged(active: false) }
        add(NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.sessionChanged(active: true) }
        add(NSWorkspace.screensDidSleepNotification) { [weak self] in self?.screensAwake = false; self?.sync() }
        add(NSWorkspace.screensDidWakeNotification) { [weak self] in self?.screensAwake = true; self?.sync() }
        add(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in self?.checkFullScreen() }
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            let bundle = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.applicationActivated(pid: pid, bundle: bundle) }
        })
        let center = NotificationCenter.default
        centerObservers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        centerObservers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking += 1 }
        })
        centerObservers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.menuTracking = max(0, self.menuTracking - 1) } }
        })
        let distributed = DistributedNotificationCenter.default()
        for (name, active) in [("com.apple.screenIsLocked", false), ("com.apple.screenIsUnlocked", true)] {
            distributedObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sessionChanged(active: active) }
            })
        }
    }

    private func removeSystemObservers() {
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in centerObservers { NotificationCenter.default.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        workspaceObservers = []; centerObservers = []; distributedObservers = []
        missionControl.stop()
    }

    private func sessionChanged(active: Bool) {
        guard sessionActive != active else { return }
        sessionActive = active
        if !active { close() }
        sync()
    }

    /// Display changes arrive in bursts; one refresh 0.1 s after the last.
    private func screensChanged() {
        screenTask?.cancel()
        screenTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.sync()
        }
    }

    private func applicationActivated(pid: pid_t?, bundle: String?) {
        checkFullScreen()
        guard isOpen || peeking else { return }
        if pid == ProcessInfo.processInfo.processIdentifier { return }
        if bundle == "com.apple.AccessibilityVisualsAgent" { return }
        if panel?.isKeyWindow == true { panel?.resignKey() }
        if isHeld { return }
        // Reaching a hover-opened island can activate the app beneath it; keep it while the pointer stays.
        if openedByHover, !clickedSinceOpen, isPointerInside() { return }
        close()
    }

    private func syncFullScreenWatch() {
        if !settings.hideInFullScreen, fullScreen { fullScreen = false }
        checkFullScreen()
    }

    private func checkFullScreen() {
        guard settings.hideInFullScreen, let screenID else { if fullScreen { fullScreen = false; scheduleRefresh() }; return }
        let now = IslandWindowServer.isFullScreen(displayID: screenID)
        guard now != fullScreen else { return }
        fullScreen = now
        if now { close(); environment.notices.dismiss() }
        menuBarIconChanged?()
        scheduleRefresh()
    }

    private func syncMissionControl() {
        if panel != nil { missionControl.start() } else { missionControl.stop() }
    }

    private func missionControlChanged(_ showing: Bool) {
        guard let panel, showing != concealed else { return }
        concealed = showing
        if showing { hoverTask?.cancel() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = showing ? 0 : 1
        }
        panel.ignoresMouseEvents = showing
    }
}
