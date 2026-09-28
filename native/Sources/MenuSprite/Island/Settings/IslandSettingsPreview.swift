import IslandKit
import SwiftUI

/// The open island as settings previews show it: laid out by the shell's own geometry on one fixed
/// stand-in display and drawn with the island's own views, so a preview matches the island exactly.
/// Previews never take the keyboard or start hardware: pages get `isPreview`, the view takes no clicks.
@MainActor
enum IslandSettingsPreview {
    /// A 1920 × 1080 display with a 210 × 32 camera, so the editor looks the same on every Mac.
    static let display = IslandDisplayMetrics.make(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                                   auxiliaryLeft: CGRect(x: 0, y: 1048, width: 855, height: 32),
                                                   auxiliaryRight: CGRect(x: 1065, y: 1048, width: 855, height: 32),
                                                   safeAreaTop: 32, barHeight: 32, scale: 2)

    /// The layout the shell would give this section right now, and the context its page is built with.
    static func layout(_ section: IslandSectionID, environment: IslandEnvironment) -> (IslandOpenLayout, IslandPageContext) {
        let settings = environment.settings
        let vertical = environment.sections[section]?.isVertical ?? false
        let bottom = !settings.floating.buttons(on: .bottom).isEmpty
        let probe = IslandGeometry.openLayout(display, settings: settings, page: .fill, vertical: vertical, hasBottomButtons: bottom)
        let context = IslandPageContext(width: probe.contentWidth, budget: probe.budget, isPreview: true, environment: environment)
        let request = environment.sections[section]?.pageHeight(context) ?? .fill
        let layout = IslandGeometry.openLayout(display, settings: settings, page: request, vertical: vertical, hasBottomButtons: bottom)
        return (layout, IslandPageContext(width: layout.contentWidth, budget: layout.budget, isPreview: true, environment: environment))
    }

    /// The tallest island any listed section would open to, for one scale that never jumps.
    static func tallest(environment: IslandEnvironment) -> CGSize {
        IslandSectionID.allCases.reduce(CGSize.zero) { size, section in
            let layout = layout(section, environment: environment).0
            return CGSize(width: max(size.width, layout.width), height: max(size.height, layout.height))
        }
    }

    /// The Custom grip starts from the preset's full height: what a filled page would reach.
    static func maximumHeight(environment: IslandEnvironment) -> CGFloat {
        let settings = environment.settings
        if settings.size == .custom { return settings.customHeight }
        return IslandGeometry.openLayout(display, settings: settings, page: .fill).height
    }

    static func presentation(_ section: IslandSectionID, environment: IslandEnvironment) -> IslandPresentation {
        let (layout, context) = layout(section, environment: environment)
        let presentation = IslandPresentation()
        presentation.display = display
        presentation.surface = .open
        presentation.destination = .section(section)
        presentation.openLayout = layout
        presentation.pageContext = context
        presentation.size = CGSize(width: layout.width, height: layout.height)
        presentation.stage = presentation.size
        return presentation
    }
}

/// One open island, real size: black silhouette, the island's own open view, and the outline when set.
struct IslandPreviewIsland: View {
    let section: IslandSectionID
    @ObservedObject var environment: IslandEnvironment
    let outline: Bool

    var body: some View {
        let presentation = IslandSettingsPreview.presentation(section, environment: environment)
        let size = presentation.size
        ZStack(alignment: .topLeading) {
            IslandShape().fill(Color.black)
            IslandOpenView(presentation: presentation, environment: environment, notices: IslandNoticeCenter(), commands: IslandCommands())
            if outline {
                // Open at the top, like the island's own outline.
                IslandShape().stroke(Color.white.opacity(0.65), lineWidth: 2)
                    .mask(Rectangle().padding(.top, 1))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }
}

/// Draws a real-size view at `scale`, taking up only the scaled size in layout.
struct IslandScaled<Content: View>: View {
    let size: CGSize
    let scale: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
    }
}
