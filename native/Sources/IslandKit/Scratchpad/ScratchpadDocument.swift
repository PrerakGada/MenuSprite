import Foundation

/// One tab of the scratchpad.
public struct ScratchpadPad: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var text: String
    /// When the text last changed; nil for an empty pad.
    public var edited: Date?

    public init(id: UUID = UUID(), name: String, text: String = "", edited: Date? = nil) {
        self.id = id; self.name = name; self.text = text; self.edited = edited
    }
}

/// The scratchpad: an ordered list of up to twelve pads (the order is the tab order) and the
/// selected one. Every rule about tabs lives here, so it can be tested without a window.
public struct ScratchpadDocument: Codable, Sendable, Equatable {
    public static let version = 1
    public static let maximumPads = 12
    public static let maximumNameLength = 40
    public static let baseName = "Scratchpad"

    public var version = ScratchpadDocument.version
    public private(set) var pads: [ScratchpadPad]
    public private(set) var selectedID: UUID

    /// A fresh document: one empty "Scratchpad 1".
    public init() {
        let pad = ScratchpadPad(name: "\(Self.baseName) 1")
        pads = [pad]
        selectedID = pad.id
    }

    public init(pads: [ScratchpadPad], selectedID: UUID?) {
        self.pads = pads
        self.selectedID = selectedID ?? pads.first?.id ?? UUID()
        sanitize()
    }

    private enum CodingKeys: String, CodingKey { case version, pads, selectedID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.version
        pads = try container.decode([ScratchpadPad].self, forKey: .pads)
        selectedID = try container.decodeIfPresent(UUID.self, forKey: .selectedID) ?? UUID()
        sanitize()
    }

    public var selected: ScratchpadPad { pads.first { $0.id == selectedID } ?? pads[0] }
    public var selectedIndex: Int { pads.firstIndex { $0.id == selectedID } ?? 0 }
    public var canAddPad: Bool { pads.count < Self.maximumPads }
    public var canClosePad: Bool { pads.count > 1 }

    /// Drops duplicate ids, keeps the first twelve, names blank tabs, drops the edit time of empty
    /// pads, repairs an unknown selection and never leaves the document empty.
    public mutating func sanitize() {
        var seen = Set<UUID>()
        var kept = pads.filter { seen.insert($0.id).inserted }
        if kept.count > Self.maximumPads { kept = Array(kept.prefix(Self.maximumPads)) }
        pads = []
        for var pad in kept {
            let name = Self.cleanName(pad.name)
            pad.name = name.isEmpty ? Self.nextName(existing: pads.map(\.name) + kept.map(\.name)) : name
            if pad.text.isEmpty { pad.edited = nil }
            pads.append(pad)
        }
        if pads.isEmpty { pads = [ScratchpadPad(name: "\(Self.baseName) 1")] }
        if !pads.contains(where: { $0.id == selectedID }) { selectedID = pads[0].id }
    }

    // MARK: Tabs

    /// Appends a pad named with the first free number and selects it. Nil at the limit.
    @discardableResult
    public mutating func addPad() -> ScratchpadPad? {
        guard canAddPad else { return nil }
        let pad = ScratchpadPad(name: Self.nextName(existing: pads.map(\.name)))
        pads.append(pad)
        selectedID = pad.id
        return pad
    }

    public mutating func select(_ id: UUID) {
        guard pads.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// Only a pad with text asks before closing.
    public func needsConfirmation(toClose id: UUID) -> Bool {
        pads.first { $0.id == id }.map { !$0.text.isEmpty } ?? false
    }

    /// Closes a pad, keeping the order; when it was selected, the nearest neighbour (the one after,
    /// else the one before) is selected. The last pad never closes.
    @discardableResult
    public mutating func close(_ id: UUID) -> Bool {
        guard canClosePad, let index = pads.firstIndex(where: { $0.id == id }) else { return false }
        pads.remove(at: index)
        if selectedID == id { selectedID = pads[min(index, pads.count - 1)].id }
        return true
    }

    /// Renames a pad: collapsed to single-spaced words, at most 40 characters; blank keeps the old name.
    public mutating func rename(_ id: UUID, to name: String) {
        guard let index = pads.firstIndex(where: { $0.id == id }) else { return }
        let clean = Self.cleanName(name)
        if !clean.isEmpty { pads[index].name = clean }
    }

    /// Replaces a pad's text; the edit time follows (none for an empty pad).
    public mutating func setText(_ text: String, of id: UUID, at date: Date) {
        guard let index = pads.firstIndex(where: { $0.id == id }), pads[index].text != text else { return }
        pads[index].text = text
        pads[index].edited = text.isEmpty ? nil : date
    }

    // MARK: Retention

    /// Clears pads whose own last edit is strictly older than the period. No edit time, or an edit
    /// time in the future (a clock that moved back), never clears. Returns the pads cleared.
    @discardableResult
    public mutating func applyRetention(_ retention: ScratchpadRetention, now: Date) -> [UUID] {
        guard let period = retention.period else { return [] }
        var cleared: [UUID] = []
        for index in pads.indices {
            guard let edited = pads[index].edited, edited <= now, now.timeIntervalSince(edited) > period else { continue }
            pads[index].text = ""
            pads[index].edited = nil
            cleared.append(pads[index].id)
        }
        return cleared
    }

    // MARK: Names

    public static func cleanName(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return String(words.joined(separator: " ").prefix(maximumNameLength))
    }

    /// "Scratchpad n" with the first free n from 1. An unnumbered "Scratchpad" holds slot 1.
    public static func nextName(existing: [String]) -> String {
        var taken = Set<Int>()
        for name in existing {
            if name == baseName { taken.insert(1); continue }
            let prefix = baseName + " "
            if name.hasPrefix(prefix), let number = Int(name.dropFirst(prefix.count)), number > 0 { taken.insert(number) }
        }
        var number = 1
        while taken.contains(number) { number += 1 }
        return "\(baseName) \(number)"
    }

    /// "<name> yyyy-MM-dd.txt" in the local date, with slashes and colons made safe for a file name.
    public static func exportName(for padName: String, on date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let safe = padName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(safe) \(formatter.string(from: date)).txt"
    }
}

/// "Clear on its own": a pad left unedited this long is emptied the next time the scratchpad opens.
public enum ScratchpadRetention: String, CaseIterable, Sendable, Identifiable {
    case never, day, week, month

    public var id: String { rawValue }

    /// Unknown stored values mean Never.
    public init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .never }

    public var period: TimeInterval? {
        switch self {
        case .never: nil
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        }
    }

    public var title: String {
        switch self {
        case .never: "Never"
        case .day: "After a day unused"
        case .week: "After a week unused"
        case .month: "After a month unused"
        }
    }
}

/// ⌘T and ⌘W on the scratchpad.
public enum ScratchpadKeyCommand: Equatable, Sendable {
    case newPad, closePad

    /// Matched by the typed character with ⌘ as the only modifier (Caps Lock allowed), so a layout
    /// that puts another letter at the US-W position does not close. No character, no command.
    public init?(characters: String?, commandOnly: Bool) {
        guard commandOnly, let characters, characters.count == 1 else { return nil }
        switch characters.lowercased() {
        case "t": self = .newPad
        case "w": self = .closePad
        default: return nil
        }
    }
}

/// The floating pad's background opacity over its frosted material: 0 translucent … 1 opaque.
public enum ScratchpadBackground {
    public static let standard = 0.0

    /// Clamped to 0…1; a value that is not a number becomes opaque.
    public static func resolve(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(1, max(0, value))
    }
}
