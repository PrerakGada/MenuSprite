import CoreGraphics
import Foundation

/// How long a screenshot's quick preview stays up. It belongs to the preview, not to the island:
/// 12 s normally, 3 s once an automatic save or copy has succeeded, 30 s once it holds a link.
/// The pointer resting on it pauses the countdown, and leaving starts the full delay again.
public struct CapturePreviewCountdown: Equatable, Sendable {
    public static let standard: Double = 12
    public static let afterAutomaticAction: Double = 3
    public static let withLink: Double = 30

    public static func duration(automaticActionSucceeded: Bool, hasLink: Bool = false) -> Double {
        if hasLink { return withLink }
        return automaticActionSucceeded ? afterAutomaticAction : standard
    }

    public let duration: Double
    /// When the preview closes by itself; nil while paused.
    public private(set) var deadline: Double?

    public init(duration: Double, now: Double) {
        self.duration = duration
        deadline = now + duration
    }

    public mutating func hover(_ inside: Bool, now: Double) {
        deadline = inside ? nil : now + duration
    }

    public func isExpired(now: Double) -> Bool {
        guard let deadline else { return false }
        return now >= deadline
    }
}

/// Sizes for the quick preview, hosted in the island or floating.
public enum CapturePreviewLayout {
    /// Room under the image for the capture's name and what happened to it.
    public static let captionHeight: CGFloat = 20
    public static let captionSpacing: CGFloat = 6
    public static let scrollInset: CGFloat = 4
    /// The preview's copy of the image is at most this many pixels on its long side.
    public static let imagePixelLimit: CGFloat = 1200
    public static let floatingSize = CGSize(width: 350, height: 210)
    public static let floatingInset: CGFloat = 10

    /// The image fitted to the page width and to what the budget leaves after the caption.
    public static func imageSize(_ image: CGSize, width: CGFloat, budget: CGFloat) -> CGSize {
        let room = CGSize(width: width, height: max(0, budget - captionHeight - captionSpacing - scrollInset))
        return fitted(image, in: room)
    }

    /// The hosted preview's page: its measured height plus the scroll inset, never more than the
    /// budget. The history instead fills the whole budget.
    public static func pageHeight(_ image: CGSize, width: CGFloat, budget: CGFloat) -> CGFloat {
        let fitted = imageSize(image, width: width, budget: budget)
        return min(budget, fitted.height + captionSpacing + captionHeight + scrollInset)
    }

    public static func fitted(_ size: CGSize, in room: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, room.width > 0, room.height > 0 else { return .zero }
        let scale = min(room.width / size.width, room.height / size.height, 1)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    /// A downscaled pixel size for the preview's copy of a large capture.
    public static func downscaled(_ size: CGSize) -> CGSize {
        fitted(size, in: CGSize(width: imagePixelLimit, height: imagePixelLimit))
    }

    /// The floating preview's origin (AppKit coordinates): the bottom-right corner of the visible frame.
    public static func floatingOrigin(visibleFrame: CGRect, size: CGSize = floatingSize) -> CGPoint {
        CGPoint(x: visibleFrame.maxX - size.width - floatingInset, y: visibleFrame.minY + floatingInset)
    }
}

/// The screen recorder's fixed rules.
public enum CaptureRecordingRules {
    public static let framesPerSecond = 60
    public static let countdownChoices = [0, 3, 5, 10]
    public static let defaultCountdown = 3
    public static let recordsSystemAudioByDefault = true
    public static let recordsMicrophoneByDefault = false
    /// A recording starts only with this much free space, and stops when free space falls below the second.
    public static let minimumFreeToStart: Int64 = 2_000_000_000
    public static let minimumFreeToContinue: Int64 = 500_000_000

    public static func canStart(freeBytes: Int64) -> Bool { freeBytes >= minimumFreeToStart }
    public static func mustStop(freeBytes: Int64) -> Bool { freeBytes < minimumFreeToContinue }

    /// "m:ss" for the recording pill.
    public static func elapsed(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
