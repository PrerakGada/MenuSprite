import AppKit
import IslandKit
import SwiftUI

/// What the island's views can ask the controller to do.
@MainActor
struct IslandCommands {
    var open: (IslandDestination?) -> Void = { _ in }
    var close: () -> Void = {}
    var togglePin: () -> Void = {}
    var openSettings: () -> Void = {}
    var choose: (IslandActivityKind) -> Void = { _ in }
    var combine: (IslandActivityKind) -> Void = { _ in }
    var noticeClicked: () -> Void = {}
    var headerHover: (Bool) -> Void = { _ in }
    var floating: (IslandFloatingAction) -> Void = { _ in }
}

/// The whole stage: the island drawn at its target size, centred at the top. The mask reveals it.
struct IslandRootView: View {
    @ObservedObject var presentation: IslandPresentation
    @ObservedObject var environment: IslandEnvironment
    @ObservedObject var activities: IslandActivityCenter
    @ObservedObject var notices: IslandNoticeCenter
    let commands: IslandCommands

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            surface
                .frame(width: presentation.size.width, height: presentation.size.height, alignment: .top)
                .offset(x: presentation.origin.x)
        }
        .frame(width: presentation.stage.width, height: presentation.stage.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var surface: some View {
        switch presentation.surface {
        case .hidden:
            Color.clear
        case .rest:
            restStrip.id("rest").transition(.opacity.animation(.easeIn(duration: 0.16)))
        case .activity:
            activityStrip.id("activity").transition(.opacity.animation(.easeIn(duration: 0.16)))
        case .chooser:
            ActivityChooserView(presentation: presentation, activities: activities, commands: commands)
        case .notice:
            if let notice = notices.current {
                NoticeStripView(notice: notice, presentation: presentation, commands: commands)
                    .id(notice.kind.isLevel ? "level-\(notice.kind.rawValue)" : notice.id.uuidString)
                    .transition(.opacity.animation(.easeIn(duration: 0.16)))
            }
        case .peek:
            PeekView(presentation: presentation, commands: commands)
        case .dropTarget:
            DropTargetView(presentation: presentation)
        case .open:
            IslandOpenView(presentation: presentation, environment: environment, notices: notices, commands: commands)
                .id("open")
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.29).delay(0.16)), removal: .identity))
        }
    }

    @ViewBuilder private var restStrip: some View {
        let wing = presentation.restWing
        if wing > 0, let wings = environment.rests[environment.settings.atRest]?.wings() {
            WingsView(camera: presentation.camera.width, wing: wing, height: presentation.size.height,
                      left: wings.left, right: wings.right)
        } else {
            Color.clear
        }
    }

    @ViewBuilder private var activityStrip: some View {
        let wing = presentation.activityWing
        if let resolved = activities.resolved, wing > 0 {
            let left = resolved.companion?.companionMark ?? resolved.primary.left
            WingsView(camera: presentation.camera.width, wing: wing, height: presentation.size.height,
                      left: left, right: resolved.primary.right,
                      leftAction: { commands.open(.section(resolved.companion?.kind.section ?? resolved.primary.kind.section)) },
                      rightAction: { commands.open(.section(resolved.primary.kind.section)) })
        } else {
            Color.clear
        }
    }
}

/// Two wings beside the camera, content at the island's ends, clear of the curved corners.
struct WingsView: View {
    let camera: CGFloat
    let wing: CGFloat
    let height: CGFloat
    let left: AnyView
    let right: AnyView
    var leftAction: (() -> Void)?
    var rightAction: (() -> Void)?

    var body: some View {
        let inset = IslandEdge.inset(height: height)
        HStack(spacing: 0) {
            wingButton(left, alignment: .leading, inset: inset, action: leftAction)
            Color.clear.frame(width: camera)
            wingButton(right, alignment: .trailing, inset: inset, action: rightAction)
        }
        .frame(height: height)
    }

    @ViewBuilder private func wingButton(_ content: AnyView, alignment: Alignment, inset: CGFloat, action: (() -> Void)?) -> some View {
        let body = content
            .frame(width: max(0, wing - inset), height: height, alignment: alignment)
            .padding(alignment == .leading ? .leading : .trailing, inset)
            .frame(width: wing, height: height, alignment: alignment)
        if let action {
            Button(action: action) { body.contentShape(Rectangle()) }.buttonStyle(.plain)
        } else {
            body
        }
    }
}

/// A notice in the closed island.
struct NoticeStripView: View {
    let notice: IslandNotice
    @ObservedObject var presentation: IslandPresentation
    let commands: IslandCommands

    var body: some View {
        let height = presentation.size.height
        let wing = presentation.noticeWing
        let camera = presentation.camera.width
        Button(action: commands.noticeClicked) {
            Group {
                if presentation.noticeExpanded, let expanded = notice.expanded {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: presentation.camera.height + 10)
                        expanded.padding(.horizontal, 16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                } else {
                switch notice.style {
                case .level(let symbol, let value):
                    let endInset = min(16, wing / 6)
                    HStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 18)
                            Text("\(Int((value * 100).rounded()))%")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .contentTransition(.numericText())
                                .animation(.easeOut(duration: 0.14), value: value)
                        }
                        .frame(width: wing - endInset, alignment: .trailing)
                        .padding(.leading, endInset)
                        Color.clear.frame(width: camera)
                        IslandMeter(value: value).frame(width: wing - 2 * endInset).padding(.horizontal, endInset)
                    }
                case .text(let symbol, let image, let title, let detail, let gap, _, let tint, let meter):
                    let inset = IslandEdge.inset(height: height)
                    HStack(spacing: 0) {
                        HStack(spacing: 6) {
                            if let image {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: min(18, height - 6), height: min(18, height - 6))
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            } else if let symbol {
                                Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(tint ?? .white)
                            }
                            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        }
                        .frame(width: max(0, wing - inset - gap), alignment: .leading)
                        .padding(.leading, inset)
                        .padding(.trailing, gap)
                        Color.clear.frame(width: camera)
                        Group {
                            if let meter {
                                IslandMeter(value: meter, tint: tint ?? .white)
                            } else {
                                Text(detail).font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.8)).lineLimit(1).truncationMode(.tail)
                            }
                        }
                        .frame(width: max(0, wing - inset - gap), alignment: .trailing)
                        .padding(.leading, gap)
                        .padding(.trailing, inset)
                    }
                case .custom(_, let left, let right):
                    WingsView(camera: camera, wing: wing, height: height, left: left, right: right)
                }
                }
            }
            .foregroundStyle(.white)
            .frame(width: presentation.size.width, height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(notice.label)
        .accessibilityHint("Open Dynamic Island")
    }
}

/// "Preview on hover": a small panel naming the page an opening would show, and an Open chevron.
struct PeekView: View {
    @ObservedObject var presentation: IslandPresentation
    let commands: IslandCommands
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: presentation.camera.height + 10)
            HStack(spacing: 10) {
                Button { commands.open(.explore) } label: {
                    Label(peekTitle, systemImage: "square.grid.2x2")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12).frame(height: 36)
                }
                .buttonStyle(IslandButtonStyle())
                Spacer()
                Button { commands.open(nil) } label: {
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .semibold)).frame(width: 36, height: 36)
                }
                .buttonStyle(IslandButtonStyle())
                .accessibilityLabel("Open")
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
        }
        .foregroundStyle(.white)
    }

    private var peekTitle: String {
        switch presentation.destination {
        case .section(let id): id.headerTitle
        case .explore: "Explore"
        case .appPanel: "MenuSprite"
        }
    }
}

/// Several live activities: the current strip on top, named choices below, and "Combine" for the timer.
struct ActivityChooserView: View {
    @ObservedObject var presentation: IslandPresentation
    @ObservedObject var activities: IslandActivityCenter
    let commands: IslandCommands

    static func layout(live: [IslandActivityKind], combos: Bool, stripWidth: CGFloat, stripHeight: CGFloat, maxWidth: CGFloat) -> CGSize {
        let label = live.map { IslandTextMetrics.width($0.title, size: 12) + 18 }.max() ?? 60
        let columns = min(3, max(1, live.count))
        let rows = Int(ceil(Double(live.count) / Double(columns)))
        let width = max(stripWidth + 48, CGFloat(columns) * (label + 48) + CGFloat(columns - 1) * 6 + 48)
        let height = stripHeight + CGFloat(rows) * 32 + CGFloat(rows - 1) * 6 + 24 + (combos ? 30 : 0)
        return CGSize(width: min(width, maxWidth), height: height)
    }

    var body: some View {
        let live = IslandActivityKind.allCases.filter(activities.live.contains)
        let current = activities.choice.resolve(live: activities.live, timerRunning: activities.timerRunning)
        let companions = IslandActivityChoice.companions(live: activities.live, timerRunning: activities.timerRunning)
        VStack(spacing: 0) {
            Color.clear.frame(height: presentation.camera.height)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: min(3, max(1, live.count))), spacing: 6) {
                ForEach(live) { kind in
                    let selected = current?.primary == kind && current?.companion == nil
                    Button { commands.choose(kind) } label: {
                        Label(kind.title, systemImage: kind.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .foregroundStyle(selected ? Color.black : .white)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.white : Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            if !companions.isEmpty {
                Menu {
                    ForEach(companions) { companion in
                        Button { commands.combine(companion) } label: {
                            Label("Timer + \(companion.title)", systemImage: current?.companion == companion ? "checkmark" : companion.symbol)
                        }
                    }
                } label: {
                    Label(current?.companion.map { "Timer + \($0.title)" } ?? "Combine",
                          systemImage: current?.companion == nil ? "plus" : "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(current?.companion == nil ? 0.75 : 1))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .frame(height: 24)
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The island while files are dragged: a dashed well that says what a drop does.
struct DropTargetView: View {
    @ObservedObject var presentation: IslandPresentation
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: presentation.camera.height + 10)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(.white.opacity(presentation.dropHovering ? 0.9 : 0.45))
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(presentation.dropHovering ? 0.12 : 0.05)))
                .overlay {
                    Label("Drop to keep on the shelf", systemImage: "tray.and.arrow.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 20)
                .frame(height: 50)
            Spacer(minLength: 0)
        }
    }
}
