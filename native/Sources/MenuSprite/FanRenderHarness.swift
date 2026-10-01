import AppKit
import PowerControl
import SwiftUI

/// Fan controls without a window, a setting or a single helper request.
///
///     MenuSprite --fan-render <dir>          board PNGs: automatic, 90%, custom 72%, light and dark
///     MenuSprite --fans                      prints each fan as the SMC reports it (no root needed)
///     MenuSprite --fan-set <auto|1–100> [s]  asks the installed helper to hold the fans for s seconds
///                                            (default 15), printing their speed, then hands them back.
///                                            The helper serves one app at a time: quit MenuSprite first.
@MainActor
enum FanRenderHarness {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        if arguments.contains("--fans") { printFans(); exit(0) }
        if let index = arguments.firstIndex(of: "--fan-set"), arguments.indices.contains(index + 1) { hold(arguments, index); exit(0) }
        guard let index = arguments.firstIndex(of: "--fan-render"), arguments.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1])
        NSApplication.shared.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        PowerStore.offline = true
        let suite = "MenuSprite.FanRender.\(UUID().uuidString)"
        let store = PowerStore(preferences: UserDefaults(suiteName: suite)!)
        for (name, target) in [("automatic", FanTarget.automatic), ("held-90", .percent(90)), ("custom-72", .percent(72))] {
            store.previewFans(target, held: true)
            for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                let view = FanControlView(power: store).frame(width: 328).padding(16).background(Color(nsColor: .windowBackgroundColor))
                let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 360, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: appearance)
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
                window.contentView = nil
            }
        }
        UserDefaults.standard.removePersistentDomain(forName: suite)
        print("Fan render written to \(directory.path)")
        exit(0)
    }

    private static func printFans() {
        let fans = BatteryHardware().fans()
        if fans.isEmpty { print("No fans reported") }
        for fan in fans {
            print("fan \(fan.index + 1): \(Int(fan.rpm)) rpm · target \(fan.target.map { String(Int($0)) } ?? "?") · \(Int(fan.minimum))–\(Int(fan.maximum)) · \(fan.manual ? "manual" : "automatic") · \(fan.controllable ? "writable" : "read-only")")
        }
    }

    private static func hold(_ arguments: [String], _ index: Int) {
        let value = arguments[index + 1]
        let target: FanTarget = value == "auto" ? .automatic : .percent(Int(value) ?? -1)
        guard FanPolicy.valid(target) else { print("Use auto or 1–100"); return }
        let seconds = arguments.indices.contains(index + 2) ? Double(arguments[index + 2]) ?? 15 : 15
        let connection = NSXPCConnection(machServiceName: PowerIdentity.service, options: .privileged)
        connection.setCodeSigningRequirement(PowerIdentity.helperRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: PowerHelperProtocol.self)
        connection.resume()
        func ask(_ target: FanTarget) {
            let done = DispatchSemaphore(value: 0)
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in print("error: \(error.localizedDescription)"); done.signal() } as? PowerHelperProtocol
            guard let data = try? JSONEncoder().encode(PowerRequest(.fans, fans: target)) else { return }
            proxy?.perform(data) { @Sendable reply in
                let snapshot = try? JSONDecoder().decode(PowerSnapshot.self, from: reply)
                print("helper holds \(snapshot?.fanTarget.map { "\($0)" } ?? "nothing (helper predates fan control)") · error \(snapshot?.error ?? "none")")
                done.signal()
            }
            _ = done.wait(timeout: .now() + 10)
        }
        printFans()
        ask(target)
        let end = Date().addingTimeInterval(target.isManual ? seconds : 0)
        while Date() < end { Thread.sleep(forTimeInterval: 1); printFans() }
        if target.isManual { ask(.automatic) }
        connection.invalidate()
        Thread.sleep(forTimeInterval: 3)
        print("after hand-back:"); printFans()
    }
}
