import Foundation
import IslandKit

/// Harness-only sample shelf, so the Files page can be rendered without reading Prerak's shelf or
/// touching any file: `MenuSprite --island-render <dir> --section files --files-preview <state>`.
/// Honoured only while the environment is headless; the paths are never opened.
struct ShelfPreviewData {
    enum State: String {
        case empty, items, selected, pile, zipping, saved, error
    }

    let state: State
    let shelf: Shelf

    init(state: State) {
        self.state = state
        shelf = Self.sample(state)
    }

    static func requested() -> ShelfPreviewData? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--files-preview"), arguments.indices.contains(index + 1),
              let state = State(rawValue: arguments[index + 1]) else { return nil }
        return ShelfPreviewData(state: state)
    }

    private static func file(_ name: String) -> ShelfContent {
        .file(ShelfFile(path: "/Users/example/MenuSprite Preview/" + name))
    }

    private static func sample(_ state: State) -> Shelf {
        var shelf = Shelf()
        guard state != .empty else { return shelf }
        shelf.add([Self.file("Quarterly report.pdf")])
        shelf.add([Self.file("Screenshot 2026-09-28 at 10.14.12.png")])
        shelf.add([Self.file("Beach.heic"), Self.file("Sunset.jpg"), Self.file("Harbour.jpg")])
        shelf.add([.link(URL(string: "https://www.apple.com/macbook-pro/")!)])
        shelf.add([.text("Meeting notes\nShip the island by Friday")])
        if case .added(let id) = shelf.add([Self.file("Launch trailer.mov")]) { shelf.setPinned([id], true) }
        shelf.add([Self.file("Keynote deck.key")])
        shelf.add([Self.file("Invoice March 2026.pdf")])
        return shelf
    }

    var pileToExpand: UUID? { state == .pile ? shelf.items.first(where: \.isPile)?.id : nil }

    /// The first two tiles, for the selected state.
    var selection: [UUID] { state == .selected ? Array(shelf.items.prefix(2).map(\.id)) : [] }

    var status: ShelfStatus? {
        switch state {
        case .zipping: .zipping(completed: 1, total: 3, cancelling: false)
        case .saved: .saved([URL(fileURLWithPath: "/Users/example/MenuSprite Preview/Quarterly report.pdf.zip")])
        case .error: .message("“Quarterly report.pdf.zip” already exists, so it was left as it was.")
        default: nil
        }
    }
}
