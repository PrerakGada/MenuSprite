import AIAccounts
import AppKit
import ScreenCaptureKit
import IslandKit
import SwiftUI

/// Renders island pages to PNG files without showing anything: no status items, no Dock icon, no
/// window on screen, no keychain access. For checking layouts while Prerak is using the Mac.
///
///     MenuSprite --island-render <dir> [--section <id>|all] [--size compact|spacious|custom]
///                [--wait <seconds>] [--start]
///
/// `--start` also calls every feature's `islandDidStart()` so live activities and notices can be
/// rendered; features must skip anything invasive (event taps, audio capture, permission prompts)
/// while `IslandEnvironment.isHeadless` is true.

@MainActor
enum IslandRenderHarness {
    /// Throwaway preferences for a render. A suite named by an absolute path is stored at that path,
    /// so it lands in the render's own folder and never in ~/Library/Preferences (deleting a normal
    /// suite at exit does not work: the preferences daemon writes the emptied domain back afterwards).
    static func scratchDefaults(in directory: URL) -> UserDefaults {
        let path = directory.appendingPathComponent("render-defaults-\(UUID().uuidString)").path
        return UserDefaults(suiteName: path)!
    }

    static func runIfRequested() {
        IslandSettingsRender.runIfRequested()
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--island-render"), arguments.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1])
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = scratchDefaults(in: directory)

        let monitoring = MonitoringStore(configurationURL: directory.appendingPathComponent("render-monitoring.json"))
        let power = PowerStore(preferences: defaults)
        let accounts = AccountsStore(switcher: AccountSwitcher(usage: UsageService.shared, http: URLSessionTransport()),
                                     usage: UsageService.shared) { _ in }
        let settings = IslandSettingsStore(defaults: defaults)
        let size = value("--size").flatMap(IslandSize.init(rawValue:))
        settings.update { settings in
            settings.enabled = true
            if let size { settings.size = size }
        }
        let environment = IslandEnvironment(monitoring: monitoring, power: power, accounts: accounts, settings: settings)
        environment.isHeadless = true
        IslandRegistry.install(in: environment)
        environment.notices.canShow = { true }
        if arguments.contains("--start") {
            // No shell here to decide presentability: accept notices so they can be reported.
            environment.notices.canShow = { true }
            environment.features.forEach { $0.islandDidStart() }
        }

        let wait = value("--wait").flatMap(Double.init) ?? 3
        if arguments.contains("--window-check") {
            windowCheck(environment: environment, directory: directory, wait: wait)
            return
        }
        if arguments.contains("--states") {
            renderStates(environment: environment, settings: settings, directory: directory, wait: wait)
            return
        }
        let requested = value("--section") ?? "all"
        let sections = requested == "all" ? IslandSectionID.allCases : [IslandSectionID(rawValue: requested)].compactMap { $0 }
        let display = IslandDisplayMetrics.make(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                                auxiliaryLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                                                auxiliaryRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
                                                safeAreaTop: 32, barHeight: 33, scale: 2)
        var report: [String] = []
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            for id in sections {
                guard let section = environment.sections[id] else { continue }
                let availability = section.availability
                guard availability.isAvailable else {
                    report.append("\(id.rawValue): unavailable — \(availability.reason ?? "")")
                    continue
                }
                section.pageDidAppear()
                try? await Task.sleep(for: .seconds(wait))
                let probe = IslandGeometry.openLayout(display, settings: settings.value, page: .fill, vertical: section.isVertical)
                let context = IslandPageContext(width: probe.contentWidth, budget: probe.budget, isPreview: false, environment: environment)
                let requestedHeight = section.pageHeight(context)
                let layout = IslandGeometry.openLayout(display, settings: settings.value, page: requestedHeight, vertical: section.isVertical)
                let page = section.page(context)
                let url = directory.appendingPathComponent("page-\(id.rawValue).png")
                let view = IslandRenderFrame(title: id.headerTitle, layout: layout) { page }
                render(view, size: CGSize(width: layout.width, height: layout.height), to: url)
                section.pageDidDisappear()
                report.append("\(id.rawValue): \(Int(layout.width)) × \(Int(layout.height)) page \(Int(layout.pageHeight)) (budget \(Int(layout.budget))) → \(url.lastPathComponent)")
                for sample in (section as? IslandRenderSampling)?.renderSamples(display: display, settings: settings.value) ?? [] {
                    let sampleURL = directory.appendingPathComponent("sample-\(id.rawValue)-\(sample.name).png")
                    render(sample.view, size: sample.size, to: sampleURL)
                    report.append("sample \(id.rawValue) \(sample.name): \(Int(sample.size.width)) × \(Int(sample.size.height)) → \(sampleURL.lastPathComponent)")
                }
            }
            for (kind, strip) in environment.activities.strips {
                // A strip whose wing depends on the side room is also drawn for a crowded and a roomy menu bar.
                var wings = [("", strip.wing)]
                if let fit = strip.wingForRoom {
                    wings += [60, 120, 400].map { ("-room\(Int($0))", fit($0, display.cutout.height)) }
                }
                for (suffix, wing) in wings {
                    let size = CGSize(width: display.cutout.width + 2 * wing, height: display.cutout.height)
                    let url = directory.appendingPathComponent("strip-\(kind.rawValue)\(suffix).png")
                    render(WingsView(camera: display.cutout.width, wing: wing, height: display.cutout.height,
                                     left: strip.left, right: strip.right).background(IslandShape().fill(Color.black)),
                           size: size, to: url)
                    report.append("strip \(kind.rawValue)\(suffix): wing \(wing) → \(url.lastPathComponent)")
                }
            }
            if let notice = environment.notices.current {
                report.append("notice: \(notice.kind.rawValue) \(notice.label)")
                if case .custom(let wing, let left, let right) = notice.style {
                    let url = directory.appendingPathComponent("notice-\(notice.kind.rawValue).png")
                    render(IslandStripFrame(camera: display.cutout.width, wing: wing, left: left, right: right),
                           size: CGSize(width: display.cutout.width + 2 * wing, height: display.cutout.height), to: url)
                    report.append("notice strip: wing \(wing) → \(url.lastPathComponent)")
                }
                if let expanded = notice.expanded {
                    // The held-banner card: preview width, the camera row above, 16 pt below.
                    let width = NotificationPreviewLayout.width(camera: display.cutout.width,
                                                                openWidth: IslandGeometry.openWidth(display, settings: settings.value))
                    let size = CGSize(width: width, height: display.cutout.height + 10 + notice.expandedHeight + 16)
                    let url = directory.appendingPathComponent("notice-\(notice.kind.rawValue)-expanded.png")
                    let card = expanded
                        .frame(width: width, height: notice.expandedHeight)
                        .padding(.top, display.cutout.height + 10)
                        .padding(.bottom, 16)
                        .background(IslandShape().fill(Color.black))
                    render(card, size: size, to: url)
                    report.append("notice card: \(Int(size.width)) × \(Int(size.height)) → \(url.lastPathComponent)")
                }
            }
            if arguments.contains("--start") { environment.features.forEach { $0.islandDidStop() } }
            try? report.joined(separator: "\n").appending("\n").write(to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            print(report.joined(separator: "\n"))
            done.signal()
            exit(0)
        }
        app.run()
        _ = done
    }

    /// The shell's own states through the real controller logic and views, clipped to the silhouette the
    /// window's mask would draw: rest (bare and with battery), a level notice, a text notice, the peek,
    /// Controls and System open with floating buttons, and Explore.
    static func renderStates(environment: IslandEnvironment, settings: IslandSettingsStore, directory: URL, wait: Double) {
        let controller = IslandController(environment: environment)
        environment.notices.canShow = { true }
        let displays: [(String, IslandDisplayMetrics)] = [
            ("notch", IslandDisplayMetrics.make(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                                auxiliaryLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                                                auxiliaryRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
                                                safeAreaTop: 32, barHeight: 33, scale: 2)),
            ("external", IslandDisplayMetrics.make(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), auxiliaryLeft: nil,
                                                   auxiliaryRight: nil, safeAreaTop: 0, barHeight: 24, scale: 1)),
        ]
        var report: [String] = []
        Task { @MainActor in
            environment.sections[.system]?.pageDidAppear()
            try? await Task.sleep(for: .seconds(wait))
            for (name, display) in displays {
                @MainActor func shot(_ label: String, open: IslandDestination? = nil, hovering: Bool = false) {
                    controller.preview(display: display, open: open, hovering: hovering)
                    let p = controller.presentation
                    let url = directory.appendingPathComponent("state-\(name)-\(label).png")
                    let crop = CGRect(x: max(0, p.origin.x - 90), y: 0, width: min(display.frame.width, p.size.width + 180),
                                      height: min(display.frame.height, p.size.height + 100))
                    let view = IslandStatePreview(presentation: p, environment: environment, crop: crop)
                    render(view, size: crop.size, to: url)
                    report.append("\(name) \(label): \(p.surface) \(Int(p.size.width)) × \(Int(p.size.height))")
                }
                settings.update { $0.atRest = .nothing }
                shot("rest-bare")
                settings.update { $0.atRest = .battery }
                shot("rest-battery")
                shot("rest-battery-hover", hovering: true)
                environment.notices.post(IslandNotice(kind: .volume, style: .level(symbol: "speaker.wave.2.fill", value: 0.45), label: "Volume, 45%"))
                shot("notice-volume")
                environment.notices.dismiss()
                environment.notices.post(IslandNotice(kind: .battery, style: .text(symbol: "battery.100percent.bolt", image: nil,
                                                                                   title: "Charging", detail: "71%", cameraGap: 16),
                                                      label: "Charging, 71%"))
                shot("notice-battery")
                environment.notices.dismiss()
                shot("open-controls", open: .section(.controls))
                shot("open-system", open: .section(.system))
                shot("open-explore", open: .explore)
            }
            environment.sections[.system]?.pageDidDisappear()
            try? report.joined(separator: "\n").appending("\n").write(to: directory.appendingPathComponent("states.txt"), atomically: true, encoding: .utf8)
            print(report.joined(separator: "\n"))
            exit(0)
        }
        NSApplication.shared.run()
    }

    /// The real window — panel, stage, Core Animation mask, outline, floating buttons — on a display
    /// parked 20 000 pt off-screen, captured through ScreenCaptureKit. Catches what the SwiftUI-only
    /// renders cannot (a mirrored mask drew nothing but the outline on screen). Needs the calling
    /// process to be allowed to record the screen; it never asks, it reports the failure.
    static func windowCheck(environment: IslandEnvironment, directory: URL, wait: Double) {
        let controller = IslandController(environment: environment)
        environment.notices.canShow = { true }
        let display = IslandDisplayMetrics.make(frame: CGRect(x: -20000, y: -20000, width: 1512, height: 982),
                                                auxiliaryLeft: CGRect(x: -20000, y: -19050, width: 663.5, height: 32),
                                                auxiliaryRight: CGRect(x: -19151.5, y: -19050, width: 663.5, height: 32),
                                                safeAreaTop: 32, barHeight: 33, scale: 2)
        environment.settingsStore.update { $0.outline = true; $0.atRest = .battery }
        Task { @MainActor in
            guard let window = controller.harnessWindow(display: display) else { exit(1) }
            var report: [String] = []
            // Where Core Animation actually puts the mask's shape, in the window's content layer, against
            // where the island should be (top centre of the window). A mirrored mask lands at the bottom.
            @MainActor func capture(_ name: String) async {
                guard let host = window.contentView, let hostLayer = host.layer,
                      let stage = host.subviews.first as? IslandStageView, let path = stage.maskLayer.path else {
                    report.append("\(name): no stage"); return
                }
                let actual = stage.maskLayer.convert(path.boundingBoxOfPath, to: hostLayer)
                let island = CGRect(origin: controller.presentation.origin, size: controller.presentation.size)
                let expected = stage.convert(island, to: host)
                let expectedInLayer = hostLayer.isGeometryFlipped == host.isFlipped ? expected
                    : CGRect(x: expected.minX, y: host.bounds.height - expected.maxY, width: expected.width, height: expected.height)
                let outline = stage.outlineLayer.convert(stage.outlineLayer.path?.boundingBoxOfPath ?? .zero, to: hostLayer)
                let ok = abs(actual.midY - expectedInLayer.midY) < 1 && abs(actual.midY - outline.midY) < 1
                report.append("\(name): mask \(actual.integral) outline \(outline.integral) expected \(expectedInLayer.integral) → \(ok ? "OK" : "MISPLACED")")
            }
            try? await Task.sleep(for: .seconds(1))
            await capture("closed")
            controller.open(.section(.controls), explicit: false)
            try? await Task.sleep(for: .seconds(max(1.5, wait)))
            await capture("open-controls")
            controller.open(.section(.system), explicit: false)
            try? await Task.sleep(for: .seconds(max(1.5, wait)))
            await capture("open-system")
            controller.close()
            try? await Task.sleep(for: .seconds(1))
            await capture("closed-again")
            window.orderOut(nil)
            try? report.joined(separator: "\n").appending("\n").write(to: directory.appendingPathComponent("window.txt"), atomically: true, encoding: .utf8)
            print(report.joined(separator: "\n"))
            exit(0)
        }
        NSApplication.shared.run()
    }

    static func render<V: View>(_ view: V, size: CGSize, to url: URL) {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.contentView = nil
        window.close()
    }
}

/// A section that can also draw states the page render cannot reach (other page states from sample
/// data, strips and floating panels). Each lands in `sample-<section>-<name>.png`.
@MainActor
protocol IslandRenderSampling {
    func renderSamples(display: IslandDisplayMetrics, settings: IslandSettings) -> [IslandRenderSample]
}

struct IslandRenderSample {
    var name: String
    var size: CGSize
    var view: AnyView
}

/// The open island's frame for renders: black silhouette, a header with the title, the page below.
struct IslandRenderFrame<Page: View>: View {
    let title: String
    let layout: IslandOpenLayout
    @ViewBuilder var page: Page

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            IslandShape().fill(Color.black)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(height: layout.headerHeight)
                .offset(x: IslandGeometry.horizontalInset, y: layout.headerTop)
            page
                .frame(width: layout.contentWidth, height: layout.pageHeight, alignment: .top)
                .offset(x: IslandGeometry.horizontalInset, y: layout.contentTop)
        }
        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }
}

/// A closed strip for renders: camera gap in the middle, wings each side.
struct IslandStripFrame: View {
    let camera: CGFloat
    let wing: CGFloat
    let left: AnyView
    let right: AnyView
    var body: some View {
        HStack(spacing: 0) {
            left.frame(width: wing)
            Color.clear.frame(width: camera)
            right.frame(width: wing)
        }
        .background(IslandShape().fill(Color.black))
    }
}

/// The island's silhouette as a SwiftUI shape.
struct IslandShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(IslandSilhouette(width: rect.width, height: rect.height).path(origin: rect.origin))
    }
}

/// One island state as the window would show it: the root view masked by the silhouette over a grey
/// backdrop (so transparent parts are visible), plus the floating buttons, cropped around the island.
struct IslandStatePreview: View {
    @ObservedObject var presentation: IslandPresentation
    let environment: IslandEnvironment
    let crop: CGRect
    var body: some View {
        let island = CGRect(origin: presentation.origin, size: presentation.size)
        ZStack(alignment: .topLeading) {
            Color(white: 0.55)
            IslandRootView(presentation: presentation, environment: environment, activities: environment.activities,
                           notices: environment.notices, commands: IslandCommands())
                .background(alignment: .topLeading) {
                    IslandShape().fill(Color.black).frame(width: island.width, height: island.height).offset(x: island.minX)
                }
                .mask(alignment: .topLeading) {
                    IslandShape().frame(width: island.width, height: island.height).offset(x: island.minX)
                }
            IslandFloatingView(presentation: presentation, environment: environment, settings: environment.settingsStore,
                               commands: IslandCommands())
        }
        .frame(width: presentation.stage.width, height: presentation.stage.height, alignment: .topLeading)
        .offset(x: -crop.minX, y: -crop.minY)
        .frame(width: crop.width, height: crop.height, alignment: .topLeading)
        .clipped()
    }
}
