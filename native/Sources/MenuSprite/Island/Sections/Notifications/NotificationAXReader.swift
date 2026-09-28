import AppKit
import ApplicationServices
import IslandKit
import os

/// What the reader reports to the main actor.
enum NotificationReaderEvent: Sendable {
    /// Notification Center's process is not running.
    case waiting
    case attached(pid_t)
    case snapshot(NotificationReadOutcome)
}

enum NotificationNativeAction: Sendable { case press, close }

enum NotificationActionResult: Sendable, Equatable {
    case done
    /// The press was sent but failed; it may or may not have landed.
    case uncertain
    /// The banner is gone, changed, ambiguous or no longer offers the action.
    case unavailable
    case cancelled
}

/// Switches the main actor flips and the reader checks at every step, so a section switched off,
/// a lock or a withdrawn permission stops a read that is already under way.
final class NotificationReaderGate: Sendable {
    private struct State { var generation = 0; var running = false; var closeAllowed = false }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Starts a new attachment and returns its generation.
    func begin() -> Int { state.withLock { $0.generation += 1; $0.running = true; return $0.generation } }
    func end() { state.withLock { $0.generation += 1; $0.running = false } }
    func isCurrent(_ generation: Int) -> Bool { state.withLock { $0.running && $0.generation == generation } }
    /// The "Close the macOS banner" option is on and the island is closed. Checked right before acting.
    var closeAllowed: Bool { state.withLock { $0.closeAllowed } }
    func setCloseAllowed(_ allowed: Bool) { state.withLock { $0.closeAllowed = allowed } }
}

/// Carries the observer callback from the C world to the reader without main-actor isolation.
final class NotificationObserverTrampoline: Sendable {
    let fire: @Sendable () -> Void
    init(_ fire: @escaping @Sendable () -> Void) { self.fire = fire }
}

/// Watches Notification Center's Accessibility tree for banners as they appear on screen. No
/// polling: an `AXObserver` on the Notification Center process schedules one coalesced read 0.12 s
/// after its windows change. Every read and action runs on one utility queue, where all
/// `AXUIElement`s stay; each read is bounded (0.8 s, 384 elements, depth 10, 64 children) and a
/// read that fails any bound or any attribute is thrown away whole. Nothing is read from Notification
/// Center's database, only what is on screen, and only static texts and image labels.
final class NotificationAXReader: @unchecked Sendable {
    let gate = NotificationReaderGate()
    private let queue = DispatchQueue(label: "in.prerakgada.MenuSprite.island.notifications", qos: .utility)
    private let deliver: @Sendable (Int, NotificationReaderEvent) -> Void
    private let log = Logger(subsystem: "in.prerakgada.MenuSprite", category: "IslandNotifications")
    private static let watched = [kAXWindowCreatedNotification, kAXLayoutChangedNotification,
                                  kAXUIElementDestroyedNotification, kAXFocusedWindowChangedNotification]
    private static let messagingTimeout: Float = 0.1
    private static let rememberedTargets = 100

    // Confined to `queue`.
    private var session: Session?
    private var latest: [UInt64: AXUIElement] = [:]
    private var remembered: [(token: UInt64, element: AXUIElement)] = []
    private var nextToken: UInt64 = 1
    private var scanPending = false
    private var installed: (time: TimeInterval, apps: [NotificationAppRecord])?
    private var closeName: String?
    private var logged = Set<String>()

    private final class Session {
        let generation: Int
        let app: AXUIElement
        let observer: AXObserver
        let source: CFRunLoopSource
        let trampoline: Unmanaged<NotificationObserverTrampoline>
        init(generation: Int, app: AXUIElement, observer: AXObserver, source: CFRunLoopSource,
             trampoline: Unmanaged<NotificationObserverTrampoline>) {
            self.generation = generation; self.app = app; self.observer = observer; self.source = source
            self.trampoline = trampoline
        }
    }

    init(deliver: @escaping @Sendable (Int, NotificationReaderEvent) -> Void) { self.deliver = deliver }

    // MARK: Attaching

    /// Attaches to Notification Center's current process (replacing any earlier attachment) and
    /// takes the baseline read.
    func attach(generation: Int) {
        queue.async { [self] in
            detachOnQueue()
            guard gate.isCurrent(generation) else { return }
            guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: NotificationAX.bundleID)
                .first(where: { !$0.isTerminated }) else {
                deliver(generation, .waiting)
                return
            }
            let pid = process.processIdentifier
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
            var created: AXObserver?
            let status = AXObserverCreate(pid, { _, _, _, context in
                guard let context else { return }
                Unmanaged<NotificationObserverTrampoline>.fromOpaque(context).takeUnretainedValue().fire()
            }, &created)
            guard status == .success, let observer = created else {
                note("observer", "could not create an observer for Notification Center (AXError \(status.rawValue))")
                deliver(generation, .waiting)
                return
            }
            let trampoline = Unmanaged.passRetained(NotificationObserverTrampoline { [weak self] in
                self?.requestScan(generation: generation)
            })
            var registered = 0
            for name in Self.watched {
                let result = AXObserverAddNotification(observer, app, name as CFString, trampoline.toOpaque())
                if result == .success { registered += 1 } else { note("watch." + name, "\(name) not available (AXError \(result.rawValue))") }
            }
            guard registered > 0 else {
                DispatchQueue.main.async { trampoline.release() }
                deliver(generation, .waiting)
                return
            }
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            session = Session(generation: generation, app: app, observer: observer, source: source, trampoline: trampoline)
            deliver(generation, .attached(pid))
            scheduleScan(generation: generation)
        }
    }

    func detach() { queue.async { [self] in detachOnQueue() } }

    private func detachOnQueue() {
        latest.removeAll()
        remembered.removeAll()
        scanPending = false
        guard let session else { return }
        self.session = nil
        CFRunLoopRemoveSource(CFRunLoopGetMain(), session.source, .commonModes)
        for name in Self.watched { AXObserverRemoveNotification(session.observer, session.app, name as CFString) }
        // A callback may be running on the main thread right now; release its context after it.
        let trampoline = session.trampoline
        DispatchQueue.main.async { trampoline.release() }
    }

    // MARK: Reading

    /// From the observer callback (main thread): schedule one read, coalescing bursts.
    private func requestScan(generation: Int) {
        queue.async { [self] in scheduleScan(generation: generation) }
    }

    private func scheduleScan(generation: Int) {
        guard !scanPending, session?.generation == generation else { return }
        scanPending = true
        queue.asyncAfter(deadline: .now() + NotificationTiming.scanDelay) { [self] in
            scanPending = false
            guard let session, session.generation == generation, gate.isCurrent(generation) else { return }
            let outcome = read(session)
            guard gate.isCurrent(generation) else { return }
            deliver(generation, .snapshot(outcome))
        }
    }

    private func read(_ session: Session) -> NotificationReadOutcome {
        guard AXIsProcessTrusted() else { return .failed(.cancelled) }
        if let stop = focus(of: session.app).stop { return stop }
        var budget = NotificationReadBudget()
        do throws(NotificationReadFailure) {
            let items = try snapshot(session, budget: &budget)
            return .complete(items)
        } catch {
            if error != .cancelled { note("failed.\(error)", "read discarded: \(error) after \(budget.nodes) elements") }
            return .failed(error)
        }
    }

    private func focus(of app: AXUIElement) -> NotificationFocus {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) {
        case .success: return value == nil ? .none : .focused
        case .noValue, .attributeUnsupported: return .none
        default: return .unreadable
        }
    }

    /// One complete read: the tree, then each notification root's actions and description, then
    /// the source apps. Throws on anything incomplete.
    private func snapshot(_ session: Session, budget: inout NotificationReadBudget) throws(NotificationReadFailure) -> [NotificationSnapshotItem] {
        let generation = session.generation
        // macOS 27 lists the application element itself among Notification Center's windows while
        // no banner is up; reading it as a window would walk the app again.
        let listed = try elements(session.app, kAXWindowsAttribute)
        let windows = listed.filter { !CFEqual($0, session.app) }
        if windows.count < listed.count { note("self-window", "Notification Center lists its application element as a window; skipped") }
        try budget.check(windows: windows.count)
        var table: [AXUIElement] = []
        var nodes: [NotificationAXNode] = []
        for window in windows { nodes.append(try readNode(window, depth: 0, budget: &budget, table: &table, generation: generation)) }
        let report = NotificationParser.parse(windows: nodes)
        describe(report, nodes: nodes)

        var found: [(candidate: NotificationCandidate, element: AXUIElement, actions: [String], description: String?)] = []
        for candidate in report.candidates {
            guard gate.isCurrent(generation) else { throw .cancelled }
            try budget.checkTime()
            let element = table[candidate.handle]
            let actions = try actionNames(element)
            let description = candidate.fields.header == nil ? try attributedDescription(element) : nil
            found.append((candidate, element, actions, description))
        }

        let running = found.isEmpty ? [] : runningApps()
        var items: [NotificationSnapshotItem] = []
        var targets: [UInt64: AXUIElement] = [:]
        for entry in found {
            let token = token(for: entry.element)
            targets[token] = entry.element
            let source = NotificationSourceResolver.source(for: entry.candidate, description: entry.description,
                                                           running: running, installed: { self.installedApps() })
            items.append(NotificationSnapshotItem(fields: entry.candidate.fields, source: source,
                                                  nativeID: NotificationParser.nativeIdentity(entry.candidate.identifier),
                                                  element: token, canPress: entry.actions.contains(kAXPressAction),
                                                  closeAction: NotificationValidation.closeAction(in: entry.actions, localizedClose: localizedClose()),
                                                  isPersistent: entry.candidate.isPersistent))
        }
        guard gate.isCurrent(generation) else { throw .cancelled }
        latest = targets
        return items
    }

    private func readNode(_ element: AXUIElement, depth: Int, budget: inout NotificationReadBudget, table: inout [AXUIElement],
                          generation: Int) throws(NotificationReadFailure) -> NotificationAXNode {
        guard gate.isCurrent(generation) else { throw .cancelled }
        try budget.visit(depth: depth)
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        let values = try attributes(element, [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXChildrenAttribute])
        var node = NotificationAXNode(role: values[0] as? String, subrole: values[1] as? String,
                                      identifier: values[2] as? String, handle: table.count)
        table.append(element)
        // Typed text (inline reply) is never read, and nothing under it either.
        guard !node.isEditable else { return node }
        if node.role == NotificationAX.staticTextRole { node.text = try string(element, kAXValueAttribute) }
        if node.role == NotificationAX.imageRole {
            node.imageLabel = try string(element, kAXDescriptionAttribute).flatMap { $0.utf8.count <= NotificationAX.maxLabelBytes ? $0 : nil }
        }
        let children = values[3] as? [AXUIElement] ?? []
        try budget.check(children: children.count, depth: depth)
        for child in children {
            node.children.append(try readNode(child, depth: depth + 1, budget: &budget, table: &table, generation: generation))
        }
        return node
    }

    // MARK: Acting

    /// Presses or closes the native banner behind `key`, only after a fresh complete read finds it
    /// unchanged and unambiguous, and a separate read of that banner alone (with its own budget)
    /// confirms its text and the action. The action is performed at most once.
    func perform(_ action: NotificationNativeAction, on key: NotificationKey, generation: Int) async -> NotificationActionResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: performOnQueue(action, key: key, generation: generation)) }
        }
    }

    private func performOnQueue(_ action: NotificationNativeAction, key: NotificationKey, generation: Int) -> NotificationActionResult {
        guard let session, session.generation == generation, gate.isCurrent(generation) else { return .cancelled }
        let outcome = read(session)
        guard case .complete(let items) = outcome else { return outcome == .failed(.cancelled) ? .cancelled : .unavailable }
        deliver(generation, .snapshot(outcome))
        let item: NotificationSnapshotItem?
        switch action {
        case .press: item = NotificationValidation.pressable(key, in: items)
        case .close: item = NotificationValidation.match(key, in: items).flatMap { NotificationValidation.closable($0) == nil ? nil : $0 }
        }
        guard let item, let element = latest[item.element] else { return .unavailable }

        var budget = NotificationReadBudget()
        var table: [AXUIElement] = []
        guard let root = try? readNode(element, depth: 0, budget: &budget, table: &table, generation: generation),
              (try? NotificationParser.fields(of: root).get()) == key.fields,
              let actions = try? actionNames(element) else { return gate.isCurrent(generation) ? .unavailable : .cancelled }
        guard gate.isCurrent(generation), AXIsProcessTrusted() else { return .cancelled }
        switch action {
        case .press:
            guard actions.contains(kAXPressAction) else { return .unavailable }
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success ? .done : .uncertain
        case .close:
            guard let name = NotificationValidation.closeAction(in: actions, localizedClose: localizedClose()) else { return .unavailable }
            guard gate.closeAllowed else { return .cancelled }
            return AXUIElementPerformAction(element, name as CFString) == .success ? .done : .uncertain
        }
    }

    // MARK: Attributes

    /// Several attributes in one round trip. Missing or unsupported values are nil; any other
    /// error fails the read.
    private func attributes(_ element: AXUIElement, _ names: [String]) throws(NotificationReadFailure) -> [AnyObject?] {
        var raw: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        guard status == .success, let values = raw as? [AnyObject], values.count == names.count else {
            throw .unreadable("attributes (AXError \(status.rawValue))")
        }
        var result: [AnyObject?] = []
        for (index, value) in values.enumerated() {
            if value is NSNull { result.append(nil); continue }
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError {
                var error = AXError.success
                AXValueGetValue(value as! AXValue, .axError, &error)
                guard error == .noValue || error == .attributeUnsupported else { throw .unreadable("\(names[index]) (AXError \(error.rawValue))") }
                result.append(nil)
                continue
            }
            result.append(value)
        }
        return result
    }

    private func string(_ element: AXUIElement, _ name: String) throws(NotificationReadFailure) -> String? {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, name as CFString, &value) {
        case .success: return value as? String
        case .noValue, .attributeUnsupported: return nil
        case let error: throw .unreadable("\(name) (AXError \(error.rawValue))")
        }
    }

    private func elements(_ element: AXUIElement, _ name: String) throws(NotificationReadFailure) -> [AXUIElement] {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, name as CFString, &value) {
        case .success: return value as? [AXUIElement] ?? []
        case .noValue, .attributeUnsupported: return []
        case let error: throw .unreadable("\(name) (AXError \(error.rawValue))")
        }
    }

    private func actionNames(_ element: AXUIElement) throws(NotificationReadFailure) -> [String] {
        var names: CFArray?
        switch AXUIElementCopyActionNames(element, &names) {
        case .success: return names as? [String] ?? []
        case .noValue, .actionUnsupported, .attributeUnsupported: return []
        case let error: throw .unreadable("actions (AXError \(error.rawValue))")
        }
    }

    /// "<app>, <title>, <subtitle>, <body>", used only when the banner prints no app name.
    private func attributedDescription(_ element: AXUIElement) throws(NotificationReadFailure) -> String? {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, "AXAttributedDescription" as CFString, &value) {
        case .success:
            if let attributed = value as? NSAttributedString { return attributed.string }
            return value as? String
        case .noValue, .attributeUnsupported: return nil
        case let error: throw .unreadable("AXAttributedDescription (AXError \(error.rawValue))")
        }
    }

    // MARK: Identity and sources

    /// A stable token per Accessibility element, so "the same element" survives across reads.
    private func token(for element: AXUIElement) -> UInt64 {
        if let hit = latest.first(where: { CFEqual($0.value, element) }) { return hit.key }
        if let hit = remembered.first(where: { CFEqual($0.element, element) }) { return hit.token }
        let token = nextToken
        nextToken += 1
        remembered.append((token, element))
        if remembered.count > Self.rememberedTargets { remembered.removeFirst(remembered.count - Self.rememberedTargets) }
        return token
    }

    private func runningApps() -> [NotificationAppRecord] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier, let name = app.localizedName else { return nil }
            return NotificationAppRecord(name: name, bundleID: bundleID, path: app.bundleURL?.path)
        }
    }

    /// Installed apps, walked at most every ten minutes and only when a running app did not settle
    /// a name.
    private func installedApps() -> [NotificationAppRecord] {
        let now = ProcessInfo.processInfo.systemUptime
        if let installed, now - installed.time < NotificationTiming.installedAppsRefresh { return installed.apps }
        let apps = NotificationInstalledApps.scan()
        installed = (now, apps)
        return apps
    }

    /// "Close" in Notification Center's own language; its custom close action carries that name.
    private func localizedClose() -> String {
        if let closeName { return closeName }
        let bundle = Bundle(path: "/System/Library/CoreServices/NotificationCenter.app")
        let name = bundle?.localizedString(forKey: "Close", value: "Close", table: "Localizable") ?? "Close"
        closeName = name.isEmpty ? "Close" : name
        return closeName ?? "Close"
    }

    // MARK: Diagnostics

    /// Logs, once per distinct shape, what the parser could not recognise, so a changed macOS can be
    /// diagnosed from Console. Never logs message text: only roles, subroles and identifiers.
    private func describe(_ report: NotificationParseReport, nodes: [NotificationAXNode]) {
        if !report.unknownSubroles.isEmpty { note("subroles.\(report.unknownSubroles.sorted())", "unrecognised notification subroles \(report.unknownSubroles.sorted())") }
        if !report.unknownTextIdentifiers.isEmpty { note("ids.\(report.unknownTextIdentifiers.sorted())", "unrecognised text identifiers \(report.unknownTextIdentifiers.sorted())") }
        if !report.rejected.isEmpty { note("rejected.\(report.rejected.map(\.rawValue))", "banners not mirrored: \(report.rejected.map(\.rawValue))") }
        guard report.candidates.isEmpty, !report.rejected.isEmpty || !report.unknownSubroles.isEmpty else { return }
        var shape: [String] = []
        func walk(_ node: NotificationAXNode, _ depth: Int) {
            guard shape.count < 60 else { return }
            let parts = [node.role ?? "?", node.subrole.map { "/" + $0 } ?? "", node.identifier.map { "#" + $0 } ?? ""]
            shape.append(String(repeating: " ", count: depth) + parts.joined())
            node.children.forEach { walk($0, depth + 1) }
        }
        nodes.forEach { walk($0, 0) }
        note("shape.\(shape.joined(separator: "|").hashValue)", "tree shape: " + shape.joined(separator: " ; "))
    }

    private func note(_ key: String, _ message: String) {
        guard logged.count < 64, logged.insert(key).inserted else { return }
        log.notice("\(message, privacy: .public)")
    }
}

/// Apps in the usual folders (one level of subfolders too, for Utilities and Setapp), by the names
/// Finder and the app itself use.
enum NotificationInstalledApps {
    static func scan() -> [NotificationAppRecord] {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser.path
        let roots = ["/Applications", "/System/Applications", "/System/Library/CoreServices", home + "/Applications"]
        var records: [NotificationAppRecord] = []
        func add(_ path: String) {
            guard let bundle = Bundle(path: path), let bundleID = bundle.bundleIdentifier else { return }
            var names = Set<String>()
            var display = manager.displayName(atPath: path)
            if display.hasSuffix(".app") { display = String(display.dropLast(4)) }
            names.insert(display)
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let name = (bundle.localizedInfoDictionary?[key] ?? bundle.infoDictionary?[key]) as? String, !name.isEmpty { names.insert(name) }
            }
            records += names.map { NotificationAppRecord(name: $0, bundleID: bundleID, path: path) }
        }
        for root in roots {
            guard let entries = try? manager.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where !entry.hasPrefix(".") {
                let path = root + "/" + entry
                if entry.hasSuffix(".app") { add(path); continue }
                guard root != "/System/Library/CoreServices", let inner = try? manager.contentsOfDirectory(atPath: path) else { continue }
                for app in inner where app.hasSuffix(".app") { add(path + "/" + app) }
            }
        }
        return records
    }
}
