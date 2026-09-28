import AppKit
import IslandKit
import SwiftUI

/// What the capture controls show and what they can do, kept apart from the chooser so the same
/// view draws the live controls and the harness's samples.
@MainActor
final class CaptureControlsModel: ObservableObject {
    @Published var tool: CaptureTool
    @Published var phase: CaptureControlsStrip.Phase = .expanded
    @Published var canRepeat: Bool
    var select: (CaptureTool) -> Void = { _ in }
    var collapse: () -> Void = {}
    var reopen: () -> Void = {}
    var close: () -> Void = {}
    var repeatRegion: () -> Void = {}

    init(tool: CaptureTool, canRepeat: Bool) {
        self.tool = tool
        self.canRepeat = canRepeat
    }
}

enum CaptureControlsStyle {
    /// Hanging from the island's camera, as wide as the open island.
    case island(cutout: IslandCutout, width: CGFloat)
    /// A bar near the bottom of the screen, when captures open in a separate window.
    case floating

    static let floatingWidth: CGFloat = 460

    func height(for tool: CaptureTool) -> CGFloat {
        switch self {
        case .island(let cutout, _):
            CaptureControlsGeometry.expandedHeight(cutoutHeight: cutout.height, tool: tool)
        case .floating:
            16 + CaptureControlsGeometry.headerHeight + 12 + CaptureControlsGeometry.toolsHeight
                + (tool.showsAudioOptions ? CaptureControlsGeometry.audioRowHeight : 0) + 16
        }
    }

    var width: CGFloat {
        switch self {
        case .island(_, let width): width
        case .floating: Self.floatingWidth
        }
    }
}

/// The capture controls: a header with the repeat chip, collapse and cancel; a tile per tool; and,
/// for recordings, the sound switches. In the island they collapse to a small target beside the camera.
struct CaptureControlsView: View {
    @ObservedObject var model: CaptureControlsModel
    @ObservedObject var options: CaptureOptions
    let style: CaptureControlsStyle
    var headless = false

    var body: some View {
        switch style {
        case .island(let cutout, let width): island(cutout: cutout, width: width)
        case .floating: floating
        }
    }

    private func island(cutout: IslandCutout, width: CGFloat) -> some View {
        let expanded = model.phase == .expanded
        let height = style.height(for: model.tool)
        let target = CaptureControlsGeometry.collapsedSize(cutout: cutout)
        return ZStack(alignment: .top) {
            IslandShape().fill(Color.black)
                .frame(width: expanded ? width : target.width, height: expanded ? height : target.height)
            if expanded {
                content(collapsible: true)
                    .padding(.horizontal, IslandGeometry.horizontalInset)
                    .padding(.top, cutout.height + CaptureControlsGeometry.cameraGap)
                    .transition(.opacity)
            } else if model.phase == .collapsed {
                collapsedTarget(camera: cutout.width, size: target)
            }
        }
        .frame(width: width, height: height, alignment: .top)
        .animation(.spring(duration: 0.3, bounce: 0.12), value: model.phase)
        .animation(.spring(duration: 0.3, bounce: 0.12), value: model.tool)
    }

    private var floating: some View {
        content(collapsible: false)
            .padding(16)
            .frame(width: style.width, height: style.height(for: model.tool), alignment: .top)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black.opacity(0.9)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
    }

    private func content(collapsible: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(collapsible: collapsible).frame(height: CaptureControlsGeometry.headerHeight)
            Spacer().frame(height: CaptureControlsGeometry.headerSpacing)
            tools.frame(height: CaptureControlsGeometry.toolsHeight)
            if model.tool.showsAudioOptions { audio.frame(height: CaptureControlsGeometry.audioRowHeight) }
        }
        .foregroundStyle(.white)
    }

    private func header(collapsible: Bool) -> some View {
        HStack(spacing: 6) {
            Text("Screen capture").font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 8)
            if model.canRepeat {
                Button(action: model.repeatRegion) {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.dashed")
                        Text("R")
                    }
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Capture the last area again (R)")
                .accessibilityLabel("Repeat the last area")
            }
            if collapsible { headerButton("chevron.up", "Collapse", action: model.collapse) }
            headerButton("xmark", "Cancel", action: model.close)
        }
    }

    private func headerButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
        }
        .buttonStyle(IslandButtonStyle(cornerRadius: 8))
        .help(label)
        .accessibilityLabel(label)
    }

    private var tools: some View {
        HStack(spacing: IslandStyle.tileSpacing) {
            ForEach(CaptureTool.allCases, id: \.self) { tool in
                IslandTileView(title: tool.title, symbol: tool.symbol, isOn: model.tool == tool, onFill: .white, onGlyph: .black) {
                    model.select(tool)
                }
                .frame(width: IslandStyle.tileMinWidth)
                .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
            }
            VStack(alignment: .leading, spacing: 4) {
                hint("rectangle.dashed", "Drag to choose an area")
                hint("macwindow", "Click a window")
                hint("return", "Return for the whole screen")
            }
            .padding(.leading, 10)
            Spacer(minLength: 0)
        }
    }

    private func hint(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).frame(width: 16)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(IslandStyle.secondaryText)
        .lineLimit(1)
    }

    private var audio: some View {
        HStack(spacing: 22) {
            CaptureSwitch(title: "Mac sound", isOn: $options.recordsSystemAudio)
            CaptureSwitch(title: "Microphone", isOn: Binding(get: { options.recordsMicrophone },
                                                            set: { options.setRecordsMicrophone($0, headless: headless) }))
        }
        .frame(maxHeight: .infinity)
    }

    private func collapsedTarget(camera: CGFloat, size: CGSize) -> some View {
        HStack(spacing: 0) {
            Image(systemName: model.tool.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(model.tool == .recording ? Color.red : Color.white)
                .frame(maxWidth: .infinity)
            Color.clear.frame(width: camera)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onTapGesture(perform: model.reopen)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Show capture controls")
    }
}

/// A small green switch drawn by hand: system switches turn grey in a window that is not key, which
/// the capture controls never are, and on would look like off.
struct CaptureSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 11, weight: .medium))
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? Color.green : Color.white.opacity(0.2))
                    Circle().fill(Color.white).padding(2)
                }
                .frame(width: 28, height: 16)
                .animation(.easeOut(duration: 0.15), value: isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(title, isOn: $isOn) }
    }
}

/// The controls' window, one level above the selection surface. In the island it hangs from the
/// camera of the island's display and only its visible controls take clicks; the rest of the window
/// lets clicks through to the selection surface.
@MainActor
final class CaptureControlsPanel: CaptureUtilityPanel {
    let style: CaptureControlsStyle
    private(set) var expandedRect: CGRect = .zero
    private(set) var targetRect: CGRect = .zero
    private weak var chooser: CaptureChooser?
    private let screenFrame: CGRect
    private let visibleFrame: CGRect
    private let metrics: IslandDisplayMetrics

    init(chooser: CaptureChooser, screen: NSScreen, inIsland: Bool, settings: IslandSettings) {
        self.chooser = chooser
        screenFrame = screen.frame
        visibleFrame = screen.visibleFrame
        metrics = screen.islandMetrics
        style = inIsland ? .island(cutout: metrics.cutout, width: IslandGeometry.openWidth(metrics, settings: settings)) : .floating
        super.init(frame: .zero, level: NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1))
        let host = CaptureHostingView(rootView: CaptureControlsView(model: chooser.controls, options: chooser.options, style: style))
        let tracker = CaptureTrackingView(content: host) { [weak chooser] in chooser?.pointerMoved(to: NSEvent.mouseLocation) }
        contentView = tracker
        layoutForTool()
    }

    /// Sizes the window for the current tool (recordings add the sound switches).
    func layoutForTool() {
        guard let chooser else { return }
        let width = style.width
        let height = style.height(for: chooser.controls.tool)
        let frame: CGRect
        switch style {
        case .island:
            frame = CGRect(x: metrics.align(screenFrame.midX - width / 2), y: screenFrame.maxY - height, width: width, height: height)
        case .floating:
            frame = CGRect(x: (visibleFrame.midX - width / 2).rounded(), y: visibleFrame.minY + 56, width: width, height: height)
        }
        setFrame(frame, display: true)
        expandedRect = CGRect(origin: .zero, size: frame.size)
        let target = CaptureControlsGeometry.collapsedSize(cutout: metrics.cutout)
        targetRect = CGRect(x: (width - target.width) / 2, y: 0, width: target.width, height: target.height)
    }

    /// A global AppKit point in this window's top-left space.
    func topLeft(_ global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - frame.minX, y: frame.maxY - global.y)
    }

    /// While a drag is under way the whole window is gone, clicks included.
    func stripChanged(_ phase: CaptureControlsStrip.Phase) {
        switch phase {
        case .hidden, .ended: orderOut(nil)
        case .expanded, .collapsed: if !isVisible { orderFrontRegardless() }
        }
    }
}

/// Reports pointer moves over the controls, which the chooser needs to decide what takes clicks.
@MainActor
final class CaptureTrackingView: NSView {
    private let moved: () -> Void

    init(content: NSView, moved: @escaping () -> Void) {
        self.moved = moved
        super.init(frame: .zero)
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { moved() }
    override func mouseExited(with event: NSEvent) { moved() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
