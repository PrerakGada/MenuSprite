import AppKit
import ApplicationServices
import IOKit

/// The private window-server calls the island relies on, each resolved at runtime and failing open:
/// if a symbol is missing the island still works, it just slides with the desktop or never hides for
/// full screen.
enum IslandWindowServer {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpaceList = @convention(c) (Int32, CFArray) -> Void
    private typealias WindowsSpaces = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias ManagedSpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static let connection: Int32? = symbol("CGSMainConnectionID", as: MainConnection.self)?()

    /// A Space of the island's own, above the desktops, so swiping between desktops or into a full-screen
    /// app does not slide it away. Flag 1 matters: other flags make Finder draw desktop icons in it.
    @MainActor
    final class OverlaySpace {
        private(set) var id: UInt64 = 0
        private var windows: [Int] = []

        init?() {
            guard let connection = IslandWindowServer.connection,
                  let create = IslandWindowServer.symbol("CGSSpaceCreate", as: SpaceCreate.self),
                  let show = IslandWindowServer.symbol("CGSShowSpaces", as: SpaceList.self) else { return nil }
            id = create(connection, 1, nil)
            guard id != 0 else { return nil }
            show(connection, [NSNumber(value: id)] as CFArray)
        }

        /// Must run before the window is first ordered in; joining a window already on screen leaves it
        /// on its desktop as well.
        func add(_ window: NSWindow) {
            guard let connection = IslandWindowServer.connection, window.windowNumber > 0,
                  let add = IslandWindowServer.symbol("CGSAddWindowsToSpaces", as: WindowsSpaces.self) else { return }
            add(connection, [NSNumber(value: window.windowNumber)] as CFArray, [NSNumber(value: id)] as CFArray)
            windows.append(window.windowNumber)
        }

        /// Windows leave the Space before it is destroyed: a window whose only Space is destroyed never shows again.
        func destroy() {
            guard let connection = IslandWindowServer.connection, id != 0 else { return }
            if let remove = IslandWindowServer.symbol("CGSRemoveWindowsFromSpaces", as: WindowsSpaces.self), !windows.isEmpty {
                remove(connection, windows.map { NSNumber(value: $0) } as CFArray, [NSNumber(value: id)] as CFArray)
            }
            if let hide = IslandWindowServer.symbol("CGSHideSpaces", as: SpaceList.self) {
                hide(connection, [NSNumber(value: id)] as CFArray)
            }
            if let destroy = IslandWindowServer.symbol("CGSSpaceDestroy", as: (@convention(c) (Int32, UInt64) -> Void).self) {
                destroy(connection, id)
            }
            windows = []
            id = 0
        }
    }

    /// Whether the given display currently shows a native full-screen Space. Unknown topology reads as
    /// "not full screen" so the island stays reachable.
    static func isFullScreen(displayID: CGDirectDisplayID) -> Bool {
        guard let connection, let copy = symbol("CGSCopyManagedDisplaySpaces", as: ManagedSpaces.self),
              let displays = copy(connection)?.takeRetainedValue() as? [[String: Any]] else { return false }
        let uuid = CGDisplayCreateUUIDFromDisplayID(displayID).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
        let separate = NSScreen.screensHaveSeparateSpaces
        for display in displays {
            let identifier = display["Display Identifier"] as? String
            if separate, let uuid, identifier != uuid { continue }
            guard let current = display["Current Space"] as? [String: Any] else { continue }
            if (current["type"] as? Int) == 4 { return true }
        }
        return false
    }
}

enum IslandHardware {
    /// Whether this Mac has a lid at all (the clamshell state property exists), computed once.
    static let hasLid: Bool = {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { if root != 0 { IOObjectRelease(root) } }
        guard root != 0 else { return false }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) != nil
    }()

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// Mission Control and App Exposé, observed through the Dock's own Accessibility notifications rather
/// than by polling the window list (which costs ~6 ms a read on this Mac). Without Accessibility the
/// island simply stays visible in Mission Control.
@MainActor
final class IslandMissionControlWatch {
    private var observer: AXObserver?
    private var dock: AXUIElement?
    private let changed: (Bool) -> Void
    private static let showing = ["AXExposeShowAllWindows", "AXExposeShowFrontWindows"]
    private static let ending = ["AXExposeExit", "AXExposeShowDesktop"]

    init(changed: @escaping (Bool) -> Void) { self.changed = changed }

    func start() {
        guard observer == nil, AXIsProcessTrusted(),
              let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let pid = dockApp.processIdentifier
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, context in
            guard let context else { return }
            let watch = Unmanaged<IslandMissionControlWatch>.fromOpaque(context).takeUnretainedValue()
            let name = notification as String
            DispatchQueue.main.async { MainActor.assumeIsolated { watch.received(name) } }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let element = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.showing + Self.ending {
            AXObserverAddNotification(created, element, name as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        dock = element
    }

    func stop() {
        guard let observer else { return }
        if let dock { for name in Self.showing + Self.ending { AXObserverRemoveNotification(observer, dock, name as CFString) } }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
        dock = nil
    }

    private func received(_ name: String) {
        changed(Self.showing.contains(name))
    }
}
