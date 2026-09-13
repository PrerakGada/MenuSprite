import Foundation
import Testing
@testable import AIAccounts

private let paceStart = Date(timeIntervalSince1970: 1_800_000_000)
private func paceWindow(_ used: Double, duration: Double = 604_800) -> UsageWindow {
    UsageWindow(id: duration == 18_000 ? "session" : "weekly", label: "Limit", usedPercent: used,
                resetsAt: paceStart.addingTimeInterval(duration), windowSeconds: duration)
}

@Test func weeklyPaceUsesWholeResetAnchoredDays() {
    let window = paceWindow(25)
    #expect(UsagePace.evaluate(window, now: paceStart)?.level == .ahead)
    #expect(UsagePace.evaluate(window, now: paceStart.addingTimeInterval(86_399))?.level == .ahead)
    let secondDay = UsagePace.evaluate(window, now: paceStart.addingTimeInterval(86_400))
    #expect(secondDay?.level == .onTrack && secondDay?.bucket == 2)
    #expect(secondDay?.allowance == 200.0 / 7)
    #expect(UsagePace.evaluate(paceWindow(43), now: paceStart.addingTimeInterval(86_400))?.level == .over)
    #expect(UsagePace.evaluate(paceWindow(99), now: paceStart.addingTimeInterval(6 * 86_400))?.level == .onTrack)
    #expect(UsagePace.evaluate(paceWindow(100), now: paceStart.addingTimeInterval(6 * 86_400))?.level == .over)
}

@Test func paceThresholdsIncludeExactlyOneExtraBucket() {
    for day in 1...6 {
        let now = paceStart.addingTimeInterval(Double(day - 1) * 86_400)
        #expect(UsagePace.evaluate(paceWindow(Double(day) * 100 / 7), now: now)?.level == .onTrack)
        #expect(UsagePace.evaluate(paceWindow(Double(day) * 100 / 7 + 0.001), now: now)?.level == .ahead)
        if day < 6 {
            #expect(UsagePace.evaluate(paceWindow(Double(day + 1) * 100 / 7), now: now)?.level == .ahead)
            #expect(UsagePace.evaluate(paceWindow(Double(day + 1) * 100 / 7 + 0.001), now: now)?.level == .over)
        }
    }
}

@Test func fiveHourPaceUsesTwentyPercentHoursForEitherProvider() {
    #expect(UsagePace.evaluate(paceWindow(20, duration: 18_000), now: paceStart)?.level == .onTrack)
    #expect(UsagePace.evaluate(paceWindow(40, duration: 18_000), now: paceStart)?.level == .ahead)
    #expect(UsagePace.evaluate(paceWindow(41, duration: 18_000), now: paceStart)?.level == .over)
    #expect(UsagePace.evaluate(paceWindow(40, duration: 18_000), now: paceStart.addingTimeInterval(3_599))?.level == .ahead)
    let next = UsagePace.evaluate(paceWindow(40, duration: 18_000), now: paceStart.addingTimeInterval(3_600))
    #expect(next?.level == .onTrack && next?.bucket == 2 && next?.bucketCount == 5)
}

@Test func oldOrInvalidWindowsNeverGetAPaceColor() {
    #expect(UsagePace.evaluate(paceWindow(0), now: paceStart.addingTimeInterval(604_800)) == nil)
    #expect(UsagePace.evaluate(paceWindow(0), now: paceStart.addingTimeInterval(-1)) == nil)
    for used in [Double.nan, .infinity, -1, 101] {
        #expect(UsagePace.evaluate(paceWindow(used), now: paceStart) == nil)
    }
    #expect(UsagePace.evaluate(paceWindow(20, duration: 7_200), now: paceStart) == nil)
    let unknown = UsageWindow(id: "weekly", label: "Weekly", usedPercent: 20, resetsAt: nil, windowSeconds: 604_800)
    #expect(UsagePace.evaluate(unknown, now: paceStart) == nil)
}
