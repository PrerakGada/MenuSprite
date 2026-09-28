import AppKit
import IslandKit
import SwiftUI

/// What the island is showing right now, published for its SwiftUI views. The controller decides it;
/// the views only draw it.
@MainActor
final class IslandPresentation: ObservableObject {
    enum Surface: Equatable {
        case hidden, rest, activity, chooser, notice, peek, open, dropTarget
    }

    @Published var surface: Surface = .rest
    /// The island's target size; the mask animates towards it.
    @Published var size: CGSize = .zero
    @Published var stage: CGSize = .zero
    @Published var display: IslandDisplayMetrics?
    @Published var restWing: CGFloat = 0
    @Published var activityWing: CGFloat = 0
    @Published var noticeWing: CGFloat = 0
    @Published var destination: IslandDestination = .section(.controls)
    @Published var openLayout: IslandOpenLayout?
    @Published var floatingVisible = false
    @Published var hovering = false
    @Published var exploreQuery = ""
    @Published var exploreHighlight: IslandSectionID?
    /// The page context handed to the visible page.
    @Published var pageContext: IslandPageContext?
    /// Header controls fade in only while the pointer is in the header row.
    @Published var headerHover = false
    /// A held notification banner opened into its full message card.
    @Published var noticeExpanded = false
    /// Files are being dragged over the drop target.
    @Published var dropHovering = false

    var camera: IslandCutout { display?.cutout ?? IslandCutout(width: 185, height: 32, isPhysical: true) }

    /// The island's top-left corner in stage coordinates.
    var origin: CGPoint {
        let x = (stage.width - size.width) / 2
        return CGPoint(x: display?.align(x) ?? x.rounded(), y: 0)
    }

    func origin(for size: CGSize) -> CGPoint {
        let x = (stage.width - size.width) / 2
        return CGPoint(x: display?.align(x) ?? x.rounded(), y: 0)
    }
}

/// Measuring notice text once, with the font notices draw in.
enum IslandTextMetrics {
    static func width(_ text: String, size: CGFloat = 11, weight: NSFont.Weight = .medium) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// The inset keeping wing content clear of a strip's curved ends: shoulder plus a 5-pt gap.
enum IslandEdge {
    static func inset(height: CGFloat) -> CGFloat {
        min(16, IslandSilhouette(width: 400, height: height).shoulder + 5)
    }
}
