import Foundation
import Testing
@testable import SystemMonitoring

private func counter(_ pid: Int32 = 10, birth: UInt64 = 1, cpu: UInt64?, energy: UInt64?, time: Double) -> ProcessMemoryRecord {
    .init(pid: pid, parentPID: 1, userID: 501, started: birth, name: "Worker", executablePath: "/Applications/Worker.app/Contents/MacOS/Worker", bytes: 1024, cpuTicks: cpu, energyNanojoules: energy, sampledUptime: time)
}
@Test func CPUUsesMachTimebaseAndDoesNotClampMultipleCores() {
    var rates = ProcessActivityRates(nanosecondsPerTick: 125.0 / 3)
    rates.update([counter(cpu: 0, energy: 1, time: 10)])
    #expect(rates.intervals.isEmpty)
    rates.update([counter(cpu: 48_000_000, energy: 2_000_000_001, time: 11)])
    #expect(abs((rates.intervals[10]?.cpuPercent ?? -1) - 200) < 0.0001)
    #expect(rates.intervals[10]?.cpuWatts == 2)
}
@Test func RatesUseElapsedTimeAndResetAcrossPIDReuseOrCounterReset() {
    var rates = ProcessActivityRates(nanosecondsPerTick: 1)
    rates.update([counter(cpu: 1_000, energy: 1_000, time: 10)])
    rates.update([counter(cpu: 1_000_001_000, energy: 4_000_001_000, time: 12)])
    #expect(rates.intervals[10]?.cpuPercent == 50)
    #expect(rates.intervals[10]?.cpuWatts == 2)
    rates.update([counter(birth: 2, cpu: 200, energy: 200, time: 13)])
    #expect(rates.intervals.isEmpty)
    rates.update([counter(birth: 2, cpu: 100, energy: 100, time: 14)])
    #expect(rates.intervals[10]?.cpuPercent == nil)
    #expect(rates.intervals[10]?.cpuWatts == nil)
}
@Test func ZeroOrMissingEnergyDoesNotInventSupport() {
    var rates = ProcessActivityRates(nanosecondsPerTick: 1)
    rates.update([counter(cpu: 1, energy: 0, time: 1)])
    rates.update([counter(cpu: 1_000_000_001, energy: 0, time: 2)])
    #expect(rates.intervals[10]?.cpuPercent == 100)
    #expect(rates.intervals[10]?.cpuWatts == nil && !rates.energyObserved)
    rates.update([counter(cpu: 2_000_000_001, energy: nil, time: 3)])
    #expect(rates.intervals[10]?.cpuWatts == nil)
    var observed = ProcessActivityRates(nanosecondsPerTick: 1)
    observed.update([counter(cpu: 1, energy: 12, time: 1)])
    observed.update([counter(cpu: 1, energy: 12, time: 2)])
    #expect(observed.intervals[10]?.cpuWatts == 0) // A valid idle interval, with proven counter support.
}
@Test func RanksUseSelectedMetricAndMarkPartialAppSubtotals() {
    var rates = ProcessActivityRates(nanosecondsPerTick: 1)
    rates.update([counter(10, cpu: 0, energy: 1, time: 1), counter(11, cpu: 0, energy: 1, time: 1)])
    let current = [counter(10, cpu: 3_000_000_000, energy: 1_000_000_001, time: 2), counter(11, cpu: 1_000_000_000, energy: 5_000_000_001, time: 2), counter(12, cpu: 1, energy: 1, time: 2)]
    rates.update(current)
    let groups = MemoryAttribution.group(current, applications: [])
    let cpu = rates.rank(groups, by: .cpu)
    let power = rates.rank(groups, by: .power)
    #expect(cpu.count == 1 && cpu[0].value == 400 && cpu[0].missingCount == 1)
    #expect(power.count == 1 && power[0].value == 6 && power[0].missingCount == 1)
    #expect(cpu[0].processValues[12] == nil)
    rates.update([])
    #expect(rates.intervals.isEmpty)
}
@Test func NonpositiveTimeIntervalsProduceNoRates() {
    var rates = ProcessActivityRates(nanosecondsPerTick: 1)
    rates.update([counter(cpu: 1, energy: 1, time: 2)])
    rates.update([counter(cpu: 2, energy: 2, time: 2)])
    #expect(rates.intervals.isEmpty)
}
