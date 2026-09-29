import Foundation
import Testing
@testable import IslandKit

@Test func standardSystemCardsMatchThePageBeforeItWasCustomisable() {
    let cards = IslandSystemLayout.standard.cards
    #expect(cards.map(\.metricID) == ["cpu.usage", "gpu.usage", "memory.usage", "battery.charge", "network.download",
                                      "disk.available", "sensor.PSTR", "sensor.fanSpeed"])
    #expect(cards.map(\.title) == ["CPU", "GPU", "Memory", "Battery", "Network", "Disk available", "Power", "Fans"])
    #expect(IslandSystemLayout.standard.metricIDs == ["cpu.usage", "gpu.usage", "memory.usage", "battery.charge",
                                                      "network.download", "network.upload", "disk.available", "disk.usage",
                                                      "sensor.PSTR", "battery.adapterRated", "sensor.fanSpeed"])
}

@Test func barFillsFromItsSourceAndCanShowWhatIsLeft() {
    let disk = IslandSystemLayout.standard.cards[5]
    #expect(disk.barMetricID == "disk.usage")
    #expect(abs(disk.barFraction(percent: 93) - 0.07) < 1e-9)
    #expect(disk.barWantsAttention(percent: 93, onBattery: false))
    #expect(!disk.barWantsAttention(percent: 80, onBattery: false))
    let cpu = IslandSystemLayout.standard.cards[0]
    #expect(cpu.barMetricID == "cpu.usage")
    #expect(cpu.barFraction(percent: 150) == 1)
    #expect(cpu.barWantsAttention(percent: 85, onBattery: false))
    #expect(!cpu.barWantsAttention(percent: 84.9, onBattery: false))
    let battery = IslandSystemLayout.standard.cards[3]
    #expect(battery.barWantsAttention(percent: 20, onBattery: true))
    #expect(!battery.barWantsAttention(percent: 20, onBattery: false))
}

@Test func aCardSamplesOnlyWhatItShows() {
    #expect(IslandSystemCard(metricID: "sensor.cpuTemperature").metricIDs == ["sensor.cpuTemperature"])
    #expect(IslandSystemCard(metricID: "cpu.usage", detail: .bar).metricIDs == ["cpu.usage"])
    #expect(IslandSystemCard(metricID: "disk.available", detail: .bar, detailMetricID: "disk.usage").metricIDs == ["disk.available", "disk.usage"])
    #expect(IslandSystemCard(metricID: "network.download", detail: .reading).metricIDs == ["network.download"])
}

@Test func layoutHoldsAtMostTwelveCardsAndReordersByIdentity() {
    var layout = IslandSystemLayout(cards: [])
    for index in 0..<14 { layout.add(IslandSystemCard(metricID: "cpu.core.\(index)")) }
    #expect(layout.cards.count == 12)
    #expect(layout.isFull)
    let last = layout.cards[11].id
    layout.move(last, to: 0)
    #expect(layout.cards.first?.id == last)
    let first = layout.cards[0].id
    layout.move(first, to: 12)
    #expect(layout.cards.last?.id == first)
    layout.remove(first)
    #expect(layout.cards.count == 11)
}

@Test func titlesAreOneShortLineAndAnEmptyReadingIsRefused() {
    var layout = IslandSystemLayout.standard
    var card = layout.cards[0]
    card.title = "  Processor\nload that goes on and on and on  "
    layout.update(card)
    #expect(layout.cards[0].title == "Processor load that goes on and")
    card.metricID = ""
    layout.update(card)
    #expect(layout.cards[0].metricID == "cpu.usage")
    let addedEmpty = layout.add(IslandSystemCard(metricID: ""))
    #expect(!addedEmpty)
}

@Test func savedLayoutsSurviveARoundTripAndDropBrokenCards() throws {
    let data = try JSONEncoder().encode(IslandSystemLayout.standard)
    #expect(try JSONDecoder().decode(IslandSystemLayout.self, from: data) == IslandSystemLayout.standard)
    let messy = #"{"cards":[{"metricID":"cpu.usage","detail":"sparkles"},{"title":"no reading"},{"metricID":"gpu.usage","detail":"bar"}]}"#
    let layout = try JSONDecoder().decode(IslandSystemLayout.self, from: Data(messy.utf8))
    #expect(layout.cards.map(\.metricID) == ["cpu.usage", "gpu.usage"])
    #expect(layout.cards.map(\.detail) == [.none, .bar])
}

@Test func systemGridBalancesRowsInReadingOrder() {
    #expect(IslandSystemGrid.columns(width: 504) == 3)
    #expect(IslandSystemGrid.rows(count: 8, width: 504) == [3, 3, 2])
    #expect(IslandSystemGrid.rows(count: 4, width: 504) == [2, 2])
    #expect(IslandSystemGrid.pageHeight(count: 8, width: 504) == 236)
    #expect(IslandSystemGrid.pageHeight(count: 0, width: 504) == 140)
}
