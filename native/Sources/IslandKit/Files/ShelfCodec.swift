import Foundation

/// The shelf's saved form: one JSON array. Decoding is tolerant, item by item, and says whether
/// everything decoded, so a store written by a newer build (or damaged) is loaded as far as it goes
/// but never swept or blindly written back.
public enum ShelfCodec {
    public struct Decoded: Sendable, Equatable {
        public var items: [ShelfItem]
        /// False when any entry, at any depth, could not be read.
        public var isComplete: Bool
    }

    public static func encode(_ shelf: Shelf) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(shelf.items.map(StoredShelfItem.init))
    }

    public static func decode(_ data: Data) -> Decoded {
        guard let entries = try? JSONDecoder().decode([LossyStored].self, from: data) else {
            return Decoded(items: [], isComplete: data.isEmpty)
        }
        var complete = true
        let items = convert(entries, complete: &complete)
        return Decoded(items: Shelf(items: items).items, isComplete: complete)
    }

    fileprivate static func convert(_ entries: [LossyStored], complete: inout Bool) -> [ShelfItem] {
        entries.compactMap { entry in
            guard let stored = entry.value, let item = stored.item(complete: &complete) else {
                complete = false
                return nil
            }
            return item
        }
    }
}

/// One saved entry that may fail to decode without failing the whole list.
private struct LossyStored: Codable {
    var value: StoredShelfItem?

    init(_ value: StoredShelfItem) { self.value = value }

    init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(StoredShelfItem.self) }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

private struct StoredShelfItem: Codable {
    var id: UUID
    var kind: String
    var pinned: Bool?
    var path: String?
    var bookmark: Data?
    var owned: Bool?
    var text: String?
    var url: String?
    var children: [LossyStored]?

    init(_ item: ShelfItem) {
        id = item.id
        pinned = item.pinned ? true : nil
        switch item.content {
        case .file(let file):
            kind = "file"; path = file.path; bookmark = file.bookmark; owned = file.owned ? true : nil
        case .text(let value):
            kind = "text"; text = value
        case .link(let link):
            kind = "link"; url = link.absoluteString
        case .pile(let items):
            kind = "pile"; children = items.map { LossyStored(StoredShelfItem($0)) }
        }
    }

    func item(complete: inout Bool) -> ShelfItem? {
        let content: ShelfContent
        switch kind {
        case "file":
            guard let path, path.hasPrefix("/") else { return nil }
            content = .file(ShelfFile(path: path, bookmark: bookmark, owned: owned ?? false))
        case "text":
            guard let text else { return nil }
            content = .text(text)
        case "link":
            guard let url, let link = URL(string: url) else { return nil }
            content = .link(link)
        case "pile":
            let items = ShelfCodec.convert(children ?? [], complete: &complete)
            guard !items.isEmpty else { return nil }
            content = .pile(items)
        default:
            return nil
        }
        return ShelfItem(id: id, content: content, pinned: pinned ?? false)
    }
}
