import Foundation

/// What a System card shows under its big value.
public enum IslandSystemCardDetail: String, Codable, Sendable, CaseIterable {
    /// Just the value.
    case none
    /// A thin bar filled from a percentage reading.
    case bar
    /// A second, smaller reading on its own line.
    case reading

    public var title: String {
        switch self {
        case .none: "Nothing"
        case .bar: "Bar"
        case .reading: "Second reading"
        }
    }
}

/// One card on the island's System page: any reading from MenuSprite's catalog, with an optional bar
/// or second reading under it.
public struct IslandSystemCard: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// The reading drawn large.
    public var metricID: String
    /// The card's title; empty uses the reading's short name.
    public var title: String
    public var detail: IslandSystemCardDetail
    /// The bar's percentage reading (empty: the card's own reading) or the second reading's ID.
    public var detailMetricID: String
    /// Bar only: fill with what is left (100 − the reading), for "disk available".
    public var barShowsRemainder: Bool

    public init(id: UUID = UUID(), metricID: String, title: String = "", detail: IslandSystemCardDetail = .none,
                detailMetricID: String = "", barShowsRemainder: Bool = false) {
        self.id = id
        self.metricID = metricID
        self.title = IslandSystemCard.clean(title)
        self.detail = detail
        self.detailMetricID = detailMetricID
        self.barShowsRemainder = barShowsRemainder
    }

    static func clean(_ title: String) -> String {
        let line = title.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return String(line.prefix(32)).trimmingCharacters(in: .whitespaces)
    }

    /// The reading the bar fills from.
    public var barMetricID: String { detailMetricID.isEmpty ? metricID : detailMetricID }

    /// Every reading this card needs sampled.
    public var metricIDs: [String] {
        switch detail {
        case .none: [metricID]
        case .bar: Array(Set([metricID, barMetricID])).sorted()
        case .reading: detailMetricID.isEmpty ? [metricID] : [metricID, detailMetricID]
        }
    }

    /// The bar's fill for a percentage value, 0…1.
    public func barFraction(percent: Double) -> Double {
        let fraction = min(1, max(0, percent / 100))
        return barShowsRemainder ? 1 - fraction : fraction
    }

    /// Whether the bar should be drawn in the warning colour: a nearly full load (85% or more), little
    /// left (under 10%), or a low battery (20% or less).
    public func barWantsAttention(percent: Double, onBattery: Bool) -> Bool {
        if barMetricID == "battery.charge" { return percent <= 20 && onBattery }
        return barShowsRemainder ? (100 - percent) < 10 : percent >= 85
    }

    private enum CodingKeys: String, CodingKey { case id, metricID, title, detail, detailMetricID, barShowsRemainder }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        metricID = try c.decode(String.self, forKey: .metricID)
        title = IslandSystemCard.clean((try? c.decode(String.self, forKey: .title)) ?? "")
        detail = (try? c.decode(IslandSystemCardDetail.self, forKey: .detail)) ?? .none
        detailMetricID = (try? c.decode(String.self, forKey: .detailMetricID)) ?? ""
        barShowsRemainder = (try? c.decode(Bool.self, forKey: .barShowsRemainder)) ?? false
    }
}

/// The System page's cards, in order.
public struct IslandSystemLayout: Codable, Sendable, Hashable {
    public static let limit = 12
    public private(set) var cards: [IslandSystemCard]

    public init(cards: [IslandSystemCard]) {
        var seen = Set<UUID>()
        self.cards = Array(cards.filter { !$0.metricID.isEmpty && seen.insert($0.id).inserted }.prefix(Self.limit))
    }

    /// CPU, GPU, memory, battery, network, disk available, power and fans: what the page showed before
    /// it could be customised.
    public static let standard = IslandSystemLayout(cards: [
        .init(metricID: "cpu.usage", title: "CPU", detail: .bar),
        .init(metricID: "gpu.usage", title: "GPU", detail: .bar),
        .init(metricID: "memory.usage", title: "Memory", detail: .bar),
        .init(metricID: "battery.charge", title: "Battery", detail: .bar),
        .init(metricID: "network.download", title: "Network", detail: .reading, detailMetricID: "network.upload"),
        .init(metricID: "disk.available", title: "Disk available", detail: .bar, detailMetricID: "disk.usage", barShowsRemainder: true),
        .init(metricID: "sensor.PSTR", title: "Power", detail: .reading, detailMetricID: "battery.adapterRated"),
        .init(metricID: "sensor.fanSpeed", title: "Fans"),
    ])

    public var isFull: Bool { cards.count >= Self.limit }

    @discardableResult
    public mutating func add(_ card: IslandSystemCard) -> Bool {
        guard !isFull, !card.metricID.isEmpty, !cards.contains(where: { $0.id == card.id }) else { return false }
        cards.append(card)
        return true
    }

    public mutating func remove(_ id: UUID) { cards.removeAll { $0.id == id } }

    public mutating func update(_ card: IslandSystemCard) {
        guard let index = cards.firstIndex(where: { $0.id == card.id }), !card.metricID.isEmpty else { return }
        var value = card
        value.title = IslandSystemCard.clean(card.title)
        cards[index] = value
    }

    /// Moves a card to sit before the card at `index` (or to the end).
    public mutating func move(_ id: UUID, to index: Int) {
        guard let from = cards.firstIndex(where: { $0.id == id }) else { return }
        let card = cards.remove(at: from)
        cards.insert(card, at: min(max(0, index > from ? index - 1 : index), cards.count))
    }

    /// Every reading the page needs sampled.
    public var metricIDs: Set<String> { Set(cards.flatMap(\.metricIDs)) }

    private enum CodingKeys: String, CodingKey { case cards }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var list = try c.nestedUnkeyedContainer(forKey: .cards)
        var decoded: [IslandSystemCard] = []
        while !list.isAtEnd {
            if let card = try? list.decode(IslandSystemCard.self) { decoded.append(card) } else { _ = try? list.decode(Discard.self) }
        }
        self.init(cards: decoded)
    }

    private struct Discard: Decodable {}
}

/// The System page grid: cards at least 128 pt wide and 72 pt tall, 10 pt apart, in balanced rows in
/// reading order (eight cards in three columns make rows of 3, 3 and 2).
public enum IslandSystemGrid {
    public static let minWidth: Double = 128
    public static let height: Double = 72
    public static let spacing: Double = 10

    public static func columns(width: Double) -> Int { max(1, Int((width + spacing) / (minWidth + spacing))) }

    public static func rows(count: Int, width: Double) -> [Int] {
        guard count > 0 else { return [] }
        let rowCount = Int(ceil(Double(count) / Double(columns(width: width))))
        let base = count / rowCount, extra = count % rowCount
        return (0..<rowCount).map { $0 < extra ? base + 1 : base }
    }

    public static func pageHeight(count: Int, width: Double) -> Double {
        let rows = rows(count: count, width: width).count
        return rows == 0 ? 140 : Double(rows) * height + Double(rows - 1) * spacing
    }
}
