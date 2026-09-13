import Foundation
import Testing
@testable import SystemMonitoring

struct EnergyFlowTests {
    let date = Date(timeIntervalSince1970: 1000)
    func flow(_ adapter: Double?, _ system: Double?, _ battery: Double?) -> EnergyFlow {
        var readings: [String: Reading] = [:]
        for (id, value) in [("sensor.PDTR", adapter), ("sensor.PSTR", system), ("battery.power", battery)] {
            if let value { readings[id] = Reading(value, at: date) }
        }
        return EnergyFlow(readings: readings, now: date)
    }
    @Test func powerSourcesAndDestinations() {
        let charging = flow(50, 25, 20)
        #expect(charging.batteryIn == 20 && charging.batteryOut == 0 && charging.difference == 5)
        let unplugged = flow(0, 25, -26)
        #expect(unplugged.batteryOut == 26 && unplugged.batteryIn == 0 && unplugged.difference == 1)
        let assistance = flow(15, 30, -16)
        #expect(assistance.adapter == 15 && assistance.batteryOut == 16 && assistance.difference == 1)
    }
    @Test func missingAndInconsistentReadingsStayHonest() {
        #expect(flow(nil, 25, -26).adapter == nil)
        #expect(flow(nil, 25, -26).difference == nil)
        let mismatch = flow(15, 30, 0)
        #expect(mismatch.imbalance && mismatch.difference == nil)
        #expect(mismatch.system == 30 && mismatch.adapter == 15)
        #expect(flow(-5, 25, 0).adapter == nil)
        #expect(flow(0, 0, 0).hasLiveFlow == false)
    }
    @Test func staleAndInvalidMetricsAreNotLive() {
        let flow = EnergyFlow(readings: ["sensor.PSTR": Reading(23, at: date),
                                        "battery.charge": Reading(120, at: date.addingTimeInterval(10)),
                                        "battery.temperature": Reading(36, at: date.addingTimeInterval(10))], now: date.addingTimeInterval(10))
        #expect(flow.system == nil && flow.charge == nil && flow.temperature == 36)
    }
    @Test func chartGapsAndRealTimes() {
        let points = [0.0, 2, 4, 60, 62].map { HistoryPoint(time: date.addingTimeInterval($0), value: 55) }
        let segments = EnergyChart.segments(points, maximumGap: 6)
        #expect(segments.map(\.count) == [3, 2])
        let broken = EnergyChart.segments(points, maximumGap: 6, breaks: [date.addingTimeInterval(3)])
        #expect(broken.map(\.count) == [2, 1, 2])
        #expect(EnergyChart.scale([55, 56], percent: true) == 0...100)
        #expect(EnergyChart.scale([10, 20], reference: 40).upperBound > 40)
    }
}
