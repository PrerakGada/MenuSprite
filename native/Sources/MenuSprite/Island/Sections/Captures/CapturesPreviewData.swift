import AppKit
import IslandKit
import SwiftUI

/// Harness-only states of the capture feature, drawn from made-up captures: nothing is read from disk,
/// no screen is captured and no window is shown. Rendered by `--island-render … --section captures`.
@MainActor
struct CapturesSamples {
    let environment: IslandEnvironment
    let display: IslandDisplayMetrics
    let settings: IslandSettings
    /// The section's own options view, drawn as Settings › Content shows it.
    let options: AnyView?

    var all: [IslandRenderSample] {
        var compact = settings
        compact.size = .compact
        let hosted = service(entries: Self.entries(), access: true)
        hosted.preview.pageDidAppear()
        hosted.preview.restore(Self.previewItem())
        let islandWidth = IslandGeometry.openWidth(display, settings: settings)
        let island = CaptureControlsStyle.island(cutout: display.cutout, width: islandWidth)
        return [
            page("empty", service(entries: [], access: true), settings: settings),
            page("permission", service(entries: [], access: false), settings: settings),
            page("recent", service(entries: Self.entries(), access: true), settings: settings),
            page("recent-compact", service(entries: Self.entries(), access: true), settings: compact),
            page("preview", hosted, settings: settings),
            controls("controls-screenshot", tool: .screenshot, phase: .expanded, canRepeat: true, style: island),
            controls("controls-recording", tool: .recording, phase: .expanded, canRepeat: false, style: island),
            controls("controls-collapsed", tool: .screenshot, phase: .collapsed, canRepeat: true, style: island),
            controls("controls-floating", tool: .recording, phase: .expanded, canRepeat: true, style: .floating),
            IslandRenderSample(name: "preview-floating", size: CapturePreviewLayout.floatingSize,
                               view: AnyView(CaptureFloatingPreviewView(controller: hosted.preview, revealsActions: true))),
            pill("pill-countdown", .countdown(3)),
            pill("pill-recording", .recording(since: Date().addingTimeInterval(-83))),
            pill("pill-saved", .message("Saved to Desktop", symbol: "checkmark.circle.fill", tint: .green)),
        ] + (options.map { view in
            [IslandRenderSample(name: "options", size: CGSize(width: 520, height: 600),
                                view: AnyView(view.padding(20).frame(width: 520, height: 600, alignment: .top)
                                    .background(Color(nsColor: .windowBackgroundColor))))]
        } ?? [])
    }

    private func service(entries: [RecentCapture], access: Bool) -> CaptureService {
        let thumbnails = Dictionary(uniqueKeysWithValues: entries.enumerated().compactMap { index, entry -> (UUID, NSImage)? in
            guard index != entries.count - 1 else { return nil }  // the last one shows the placeholder
            let art = Self.art(width: 360, height: 225, hue: Double(index) * 0.13, recording: entry.kind == .recording)
            return (entry.id, NSImage(cgImage: art, size: CGSize(width: 180, height: 112)))
        })
        return CaptureService(environment: environment, options: CaptureOptions(defaults: nil),
                              library: CaptureLibrary(preview: entries, thumbnails: thumbnails), hasAccess: access)
    }

    private func page(_ name: String, _ service: CaptureService, settings: IslandSettings) -> IslandRenderSample {
        let probe = IslandGeometry.openLayout(display, settings: settings, page: .fill)
        let context = IslandPageContext(width: probe.contentWidth, budget: probe.budget, isPreview: false, environment: environment)
        var height = IslandPageHeight.fill
        if service.preview.isHosted, let item = service.preview.item {
            height = .fixed(CapturePreviewLayout.pageHeight(item.image.size, width: context.width, budget: context.budget))
        }
        let layout = IslandGeometry.openLayout(display, settings: settings, page: height)
        let view = ZStack(alignment: .topTrailing) {
            IslandRenderFrame(title: IslandSectionID.captures.headerTitle, layout: layout) { CapturesPage(service: service, context: context) }
            CapturePreviewActions(controller: service.preview)
                .foregroundStyle(.white)
                .frame(height: layout.headerHeight)
                .padding(.trailing, IslandGeometry.horizontalInset + 32)
                .offset(y: layout.headerTop)
        }
        return IslandRenderSample(name: name, size: CGSize(width: layout.width, height: layout.height), view: AnyView(view))
    }

    private func controls(_ name: String, tool: CaptureTool, phase: CaptureControlsStrip.Phase, canRepeat: Bool,
                          style: CaptureControlsStyle) -> IslandRenderSample {
        let model = CaptureControlsModel(tool: tool, canRepeat: canRepeat)
        model.phase = phase
        let size = CGSize(width: style.width + 80, height: style.height(for: tool) + 40)
        let view = ZStack(alignment: .top) {
            Self.backdrop
            CaptureControlsView(model: model, options: CaptureOptions(defaults: nil), style: style, headless: true)
                .padding(.top, { if case .floating = style { 20 } else { 0 } }())
        }
        .frame(width: size.width, height: size.height)
        return IslandRenderSample(name: name, size: size, view: AnyView(view))
    }

    private func pill(_ name: String, _ state: CaptureRecordingController.State) -> IslandRenderSample {
        let size = CGSize(width: RecordingPillPanel.size.width, height: RecordingPillPanel.size.height + 16)
        let view = ZStack { Self.backdrop; RecordingPillView(state: state) {} }.frame(width: size.width, height: size.height)
        return IslandRenderSample(name: name, size: size, view: AnyView(view))
    }

    /// A stand-in for the desktop behind the controls.
    private static var backdrop: some View {
        LinearGradient(colors: [Color(red: 0.36, green: 0.45, blue: 0.62), Color(red: 0.62, green: 0.52, blue: 0.66)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func entries(now: Date = Date()) -> [RecentCapture] {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        func entry(_ kind: CaptureKind, minutesAgo: Double, saved: Bool = true) -> RecentCapture {
            let date = now.addingTimeInterval(-minutesAgo * 60)
            let id = UUID()
            return RecentCapture(id: id, kind: kind, date: date,
                                 fileURL: saved ? desktop.appendingPathComponent(CaptureNaming.fileName(kind, date: date)) : nil,
                                 imageName: kind == .screenshot ? RecentCapturesStore.imageName(for: id) : nil,
                                 thumbnailName: RecentCapturesStore.thumbnailName(for: id), imageBytes: 2_400_000,
                                 pixelWidth: 3024, pixelHeight: 1964)
        }
        return [entry(.screenshot, minutesAgo: 0.5), entry(.recording, minutesAgo: 6), entry(.screenshot, minutesAgo: 25, saved: false),
                entry(.screenshot, minutesAgo: 130), entry(.recording, minutesAgo: 1_500), entry(.screenshot, minutesAgo: 4_400),
                entry(.screenshot, minutesAgo: 9_000)]
    }

    static func previewItem() -> CapturePreviewItem {
        let art = art(width: 1200, height: 750, hue: 0.58, recording: false)
        var entry = entries()[0]
        entry.fileURL = nil
        return CapturePreviewItem(entry: entry, image: NSImage(cgImage: art, size: CGSize(width: 1512, height: 945)),
                                  png: Data(), status: "Copied")
    }

    /// A made-up screen: a soft wallpaper with a window of text lines (or a video frame).
    static func art(width: Int, height: Int, hue: Double, recording: Bool) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let w = CGFloat(width), h = CGFloat(height)
        let top = NSColor(hue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.45, brightness: 0.75, alpha: 1).cgColor
        let bottom = NSColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.45, alpha: 1).cgColor
        let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
        let window = CGRect(x: w * 0.12, y: h * 0.12, width: w * 0.76, height: h * 0.74)
        context.setFillColor(NSColor(white: recording ? 0.08 : 0.97, alpha: 1).cgColor)
        context.addPath(CGPath(roundedRect: window, cornerWidth: w * 0.02, cornerHeight: w * 0.02, transform: nil))
        context.fillPath()
        let bar = h * 0.06
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(x: window.minX + bar * (0.6 + CGFloat(index) * 0.9), y: window.maxY - bar * 0.8, width: bar * 0.5, height: bar * 0.5))
        }
        if recording {
            context.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            let play = CGMutablePath()
            play.move(to: CGPoint(x: w * 0.46, y: h * 0.38))
            play.addLine(to: CGPoint(x: w * 0.46, y: h * 0.58))
            play.addLine(to: CGPoint(x: w * 0.57, y: h * 0.48))
            play.closeSubpath()
            context.addPath(play)
            context.fillPath()
        } else {
            for line in 0..<7 {
                let length = [0.62, 0.48, 0.55, 0.3, 0.58, 0.44, 0.52][line]
                context.setFillColor(NSColor(white: line == 0 ? 0.35 : 0.72, alpha: 1).cgColor)
                context.fill(CGRect(x: window.minX + bar, y: window.maxY - bar * CGFloat(2.2 + Double(line) * 1.1),
                                    width: window.width * length, height: bar * 0.45))
            }
        }
        return context.makeImage()!
    }
}
