import Foundation
import IslandKit

/// Harness-only sample history, so the page renders without reading the real pasteboard or file:
/// `MenuSprite --island-render <dir> --section clipboard --clipboard-preview <state>`.
/// Honoured only while the environment is headless.
struct ClipboardPreviewData {
    enum State: String {
        /// Sample entries: pinned text, a colour, a web address, an image, files (the default).
        case list
        /// The same, searched.
        case search
        /// History off, nothing saved: how to turn it on.
        case off
        /// History on but macOS would ask on the first read (never asked yet).
        case ask
        /// History on, set to Deny in Privacy & Security.
        case denied
        /// Saved entries while macOS asks: the one-line banner above the list.
        case blocked
        /// History on and allowed, nothing copied yet.
        case empty
        /// The history file could not be read.
        case failed
    }

    let state: State

    static func requested() -> ClipboardPreviewData {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--clipboard-preview"), arguments.indices.contains(index + 1),
              let state = State(rawValue: arguments[index + 1]) else { return ClipboardPreviewData(state: .list) }
        return ClipboardPreviewData(state: state)
    }

    var keepHistory: Bool { state != .off }
    var failed: Bool { state == .failed }
    var query: String { state == .search ? "release" : "" }

    var access: ClipboardReadAccess {
        switch state {
        case .ask: .notAsked
        case .denied: .denied
        case .blocked: .asks
        default: .allowed
        }
    }

    var entries: [ClipboardEntry] {
        switch state {
        case .off, .ask, .denied, .empty, .failed: return []
        case .list, .search, .blocked: break
        }
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        var pinned = ClipboardEntry.text("Thanks — I'll send the release notes by Friday.\nBest,\nSam", at: ago(300))
        pinned.pinnedAt = ago(200)
        return [
            pinned,
            .text("#0A84FF", at: ago(1)),
            .image(ClipboardImage(file: "preview.png", sha256: "preview", width: 1512, height: 982, bytes: 1_048_576), at: ago(4)),
            .files(["/Users/example/Documents/Release checklist.pdf", "/Users/example/Documents/Release notes.md"], at: ago(9)),
            .text("https://menusprite.prerakgada.in/releases", at: ago(15)),
            .text("git tag app-v1.2.31 && git push origin app-v1.2.31", at: ago(40)),
            .text("Release checklist: build, notarize, staple, upload, update the cask.", rich: ClipboardRichText(file: "preview.rtf", bytes: 800), at: ago(70)),
        ]
    }
}
