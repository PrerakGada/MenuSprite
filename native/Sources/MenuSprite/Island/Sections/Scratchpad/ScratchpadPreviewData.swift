import Foundation
import IslandKit

/// Harness-only sample notes, so the page renders without reading the real file:
/// `MenuSprite --island-render <dir> --section scratchpad --scratchpad-preview <state>`.
/// Honoured only while the environment is headless.
enum ScratchpadPreviewData {
    enum State: String {
        /// Three tabs with Markdown notes (the default).
        case notes
        /// The same notes shown with formatting.
        case formatted
        /// One empty pad: the placeholder.
        case empty
        /// A write failed: the warning above the editor.
        case warning
        /// The file could not be read.
        case failed
    }

    static func requested() -> State {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--scratchpad-preview"), arguments.indices.contains(index + 1),
              let state = State(rawValue: arguments[index + 1]) else { return .notes }
        return state
    }

    static func document(for state: State) -> ScratchpadDocument? {
        switch state {
        case .failed: return nil
        case .empty: return ScratchpadDocument()
        case .notes, .formatted, .warning:
            let now = Date()
            let pads = [
                ScratchpadPad(name: "Scratchpad 1", text: "Book the dentist\nBuy a USB-C cable for the desk", edited: now),
                ScratchpadPad(name: "Release notes", text: """
                # Version 2.4
                Search rebuilt on the **new index**, with *faster* results.

                - Import from CSV
                - Keyboard shortcuts
                  - custom per window
                1. Update the changelog
                2. Tag the release

                > Ask design about the new icons.

                ---
                `make release` before tagging
                """, edited: now),
                ScratchpadPad(name: "Ideas", text: "", edited: nil),
            ]
            return ScratchpadDocument(pads: pads, selectedID: pads[1].id)
        }
    }
}
