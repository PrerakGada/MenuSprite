import CoreGraphics
import Foundation
import Testing
@testable import IslandKit

// The Timer section's pure rules (spec-sections-core §1.8, spec-activity §3.4).

private let en = Locale(identifier: "en_US")

/// A suite named by an absolute path is stored at that path, so test preferences live in the temporary
/// folder and never in ~/Library/Preferences.
private func scratchDefaults() -> (UserDefaults, String) {
    let suite = FileManager.default.temporaryDirectory.appendingPathComponent("MenuSprite.TimerTests.\(UUID().uuidString)").path
    return (UserDefaults(suiteName: suite)!, suite)
}

private func discard(_ defaults: UserDefaults, _ suite: String) {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(atPath: suite + ".plist")
}

// MARK: 1, 15, 23 — remembered choices

@Test func modeDefaultsToTimerAndUnknownValuesFallBack() {
    let (defaults, suite) = scratchDefaults()
    defer { discard(defaults, suite) }
    #expect(TimerSettings(defaults: defaults).mode == .timer)
    defaults.set("egg-timer", forKey: TimerSettings.Key.mode.defaultsKey)
    #expect(TimerSettings(defaults: defaults).mode == .timer)
}

@Test func chosenModeSurvivesRelaunch() {
    let (defaults, suite) = scratchDefaults()
    defer { discard(defaults, suite) }
    var settings = TimerSettings(defaults: defaults)
    settings.mode = .stopwatch
    settings.write(to: defaults)
    #expect(TimerSettings(defaults: defaults).mode == .stopwatch)
}

@Test func pomodoroDefaultsAreTwentyFiveFiveFifteenFourFour() {
    let plan = TimerSettings().plan
    #expect(plan == PomodoroPlan(focusMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15, sessionsBeforeLongBreak: 4, totalSessions: 4))
}

@Test func restoredOutOfRangePomodoroValuesAreClamped() {
    let (defaults, suite) = scratchDefaults()
    defer { discard(defaults, suite) }
    defaults.set(0, forKey: TimerSettings.Key.focusMinutes.defaultsKey)
    defaults.set(Int.max, forKey: TimerSettings.Key.shortBreakMinutes.defaultsKey)
    defaults.set(-40, forKey: TimerSettings.Key.longBreakMinutes.defaultsKey)
    defaults.set(99, forKey: TimerSettings.Key.sessionsBeforeLongBreak.defaultsKey)
    defaults.set(Double.nan, forKey: TimerSettings.Key.totalSessions.defaultsKey)
    let plan = TimerSettings(defaults: defaults).plan
    #expect(plan.focusMinutes == 1)
    #expect(plan.shortBreakMinutes == 60)
    #expect(plan.longBreakMinutes == 1)
    #expect(plan.sessionsBeforeLongBreak == 24)
    #expect(plan.totalSessions == 4)
    var edited = plan
    edited.focusMinutes = 500
    #expect(edited.focusMinutes == 180)
}

@Test func everyChoiceIsARegisteredDefault() {
    let registered = TimerSettings.defaultValues
    for key in TimerSettings.Key.allCases { #expect(registered[key.defaultsKey] != nil) }
    #expect(registered[TimerSettings.Key.mode.defaultsKey] as? String == "timer")
    #expect(registered[TimerSettings.Key.sound.defaultsKey] as? Bool == true)
}

@Test func savedChoicesRestoreTheWholeCycle() {
    let (defaults, suite) = scratchDefaults()
    defer { discard(defaults, suite) }
    var settings = TimerSettings()
    settings.plan = PomodoroPlan(focusMinutes: 50, shortBreakMinutes: 10, longBreakMinutes: 30, sessionsBeforeLongBreak: 3, totalSessions: 6)
    settings.write(to: defaults)
    #expect(TimerSettings(defaults: defaults).plan == settings.plan)
}

@Test func alarmSoundIsOnByDefaultAndSurvivesReload() {
    let (defaults, suite) = scratchDefaults()
    defer { discard(defaults, suite) }
    #expect(TimerSettings(defaults: defaults).sound)
    var settings = TimerSettings(defaults: defaults)
    settings.sound = false
    settings.write(to: defaults)
    #expect(TimerSettings(defaults: defaults).sound == false)
}

@Test func liveSessionsAreNotSettings() {
    let keys = Set(TimerSettings.Key.allCases.map(\.rawValue))
    #expect(keys == ["mode", "focusMinutes", "shortBreakMinutes", "longBreakMinutes", "sessionsBeforeLongBreak", "totalSessions", "sound"])
}

// MARK: 2–8 — countdown

@Test func countdownReadsFromItsAbsoluteDeadline() {
    let session = TimerSession.countdown(minutes: 5, at: 100)!
    #expect(session.deadline == 400)
    #expect(session.reading(at: 101.25) == 298.75)
}

@Test func startingWhileASessionExistsChangesNothing() {
    var slot = TimerSlot()
    let started = slot.start(TimerSession.countdown(minutes: 5, at: 100))
    #expect(started)
    let started2 = slot.start(TimerSession.stopwatch(at: 200))
    #expect(!started2)
    #expect(slot.session?.mode == .timer)
    #expect(slot.session?.deadline == 400)
}

@Test func pausedTimeHoldsThroughSleepAndResumeKeepsOnlyTheRemainder() {
    var session = TimerSession.countdown(minutes: 5, at: 0)!
    let paused = session.pause(at: 60)
    #expect(paused == nil)
    #expect(session.reading(at: 9_000) == 240)
    let resumed = session.resume(at: 10_000)
    #expect(resumed)
    #expect(session.deadline == 10_240)
}

@Test func completionHappensOnlyAtTheDeadlineAndOnlyOnce() {
    var session = TimerSession.countdown(minutes: 5, at: 100)!
    let completed = session.complete(at: 399.999)
    #expect(completed == nil)
    #expect(!session.isFinished)
    let completion = session.complete(at: 400.5)
    #expect(completion == TimerCompletion(phase: .countdown, endsCycle: false))
    #expect(completion?.title == "Time is up")
    let completed2 = session.complete(at: 500)
    #expect(completed2 == nil)
    #expect(session.title == "Time is up")
}

@Test func cancelDiscardsTheWholeSessionIncludingPomodoroProgress() {
    var slot = TimerSlot()
    slot.start(TimerSession.pomodoro(.standard, at: 0))
    _ = slot.update { $0.complete(at: 1_500) }
    #expect(slot.session?.completedFocuses == 1)
    slot.dismiss()
    #expect(slot.session == nil)
    slot.start(TimerSession.pomodoro(.standard, at: 2_000))
    #expect(slot.session?.completedFocuses == 0)
    #expect(slot.session?.phase == .focus)
}

@Test func zeroMinutesIsOneMinuteAndHugeInputIsThreeHours() {
    #expect(TimerSession.countdownLength(minutes: 0) == 60)
    #expect(TimerSession.countdownLength(minutes: -5) == 60)
    #expect(TimerSession.countdownLength(minutes: Int.max) == 10_800)
    #expect(TimerSession.countdown(minutes: Int.max, at: 0)?.deadline == 10_800)
}

@Test func pausingAtTheDeadlineCompletesInsteadOfStoringZero() {
    var session = TimerSession.countdown(minutes: 1, at: 0)!
    let paused = session.pause(at: 60)
    #expect(paused != nil)
    #expect(session.isFinished)
    #expect(!session.isPaused)
}

@Test func pausingTwiceOrResumingARunningSessionChangesNothing() {
    var session = TimerSession.countdown(minutes: 5, at: 0)!
    let resumed = session.resume(at: 10)
    #expect(!resumed)
    #expect(session.deadline == 300)
    _ = session.pause(at: 100)
    _ = session.pause(at: 150)
    #expect(session.state == .paused(reading: 200))
}

@Test func anUnreadableClockStartsAndPausesNothing() {
    #expect(TimerSession.countdown(minutes: 5, at: .nan) == nil)
    var session = TimerSession.countdown(minutes: 5, at: 0)!
    let paused = session.pause(at: .nan)
    #expect(paused == nil)
    #expect(session.isRunning)
    #expect(session.reading(at: .infinity).isNaN)
}

// MARK: 9, 10, 18 — how time is written

@Test func bigClockCases() {
    let cases: [(Double, String)] = [(0.01, "00:01"), (-1, "00:00"), (.nan, "00:00"), (59, "00:59"), (60, "01:00"),
                                      (3599, "59:59"), (3599.01, "1:00:00"), (3601, "1:00:01"), (8580, "2:23:00"),
                                      (10_800, "3:00:00"), (1e12, "3:00:00"), (.infinity, "00:00")]
    for (seconds, text) in cases { #expect(TimerFormat.clock(countdown: seconds) == text, "\(seconds)") }
}

@Test func narrowUnitDurations() {
    let cases: [(Double, String)] = [(870, "14m"), (60, "1m"), (59, "59s"), (0.01, "1s"), (3599, "59m"), (3599.01, "1h"),
                                      (3600, "1h"), (3659, "1h"), (3660, "1h 1m"), (8580, "2h 23m"), (10_800, "3h"),
                                      (1e12, "3h"), (.nan, "0s"), (.infinity, "0s"), (-1, "0s"), (0, "0s")]
    for (seconds, text) in cases { #expect(TimerFormat.duration(seconds, locale: en) == text, "\(seconds)") }
}

@Test func stripHourForm() {
    let cases: [(Double, String)] = [(3600, "1h00"), (3659.9, "1h00"), (3660, "1h01"), (5700, "1h35"), (8580, "2h23"),
                                      (10_800, "3h00"), (1e12, "3h00"), (.nan, "0h00")]
    for (seconds, text) in cases { #expect(TimerFormat.hours(seconds, limit: TimerSession.maximumLength) == text, "\(seconds)") }
}

@Test func stripCountdownReading() {
    let cases: [(Double, String)] = [(870, "14m"), (59, "59s"), (0.01, "1s"), (60.5, "1m"), (3599, "59m"),
                                      (3600, "1h00"), (5700, "1h35"), (1e12, "3h00"), (0, "0s"), (.nan, "0s"), (-3, "0s")]
    for (seconds, text) in cases { #expect(TimerFormat.strip(countdown: seconds, locale: en) == text, "\(seconds)") }
}

@Test func everyLanguageGetsANonEmptyCompactReading() {
    for identifier in ["en_US", "fr_FR", "de_DE", "es_ES", "it_IT", "ja_JP", "ko_KR", "zh_Hans", "pt_BR", "ru_RU", "ar", "hi_IN", "tr_TR", "nl_NL", "pl_PL"] {
        let locale = Locale(identifier: identifier)
        #expect(!TimerFormat.strip(countdown: 870, locale: locale).isEmpty, "\(identifier)")
        #expect(!TimerFormat.strip(countdown: 8580, locale: locale).isEmpty, "\(identifier)")
        #expect(!TimerFormat.duration(870, locale: locale).isEmpty, "\(identifier)")
    }
}

@Test func stopwatchRoundsDownPassesThreeHoursAndSaturates() {
    #expect(TimerFormat.clock(stopwatch: 0.99) == "00:00")
    #expect(TimerFormat.clock(stopwatch: 59.999) == "00:59")
    #expect(TimerFormat.clock(stopwatch: 3600) == "1:00:00")
    #expect(TimerFormat.clock(stopwatch: 20_000) == "5:33:20")
    #expect(TimerFormat.clock(stopwatch: 1e9) == "99:59:59")
    #expect(TimerFormat.clock(stopwatch: -5) == "00:00")
    #expect(TimerFormat.strip(stopwatch: 42.7) == "00:42")
    #expect(TimerFormat.strip(stopwatch: 725) == "12:05")
    #expect(TimerFormat.strip(stopwatch: 3599.9) == "59:59")
    #expect(TimerFormat.strip(stopwatch: 3900) == "1h05")
    #expect(TimerFormat.strip(stopwatch: 1e9) == "99h59")
    // Countdowns still switch to hours at the hour boundary.
    #expect(TimerFormat.strip(countdown: 3600, locale: en) == "1h00")
}

@Test func readingShapeIgnoresDigitsButNotLength() {
    #expect(TimerFormat.shape("14m") == TimerFormat.shape("13m"))
    #expect(TimerFormat.shape("10m") != TimerFormat.shape("9m"))
    #expect(TimerFormat.shape("1h35") == "0h00")
}

// MARK: 13, 14 — Pomodoro

@Test func pomodoroRoundsWithDefaultsAndFiveSessions() {
    let plan = PomodoroPlan(totalSessions: 5)
    var session = TimerSession.pomodoro(plan, at: 0)!
    var now: Double = 0
    for round in 1...4 {
        #expect(session.phase == .focus)
        #expect(session.length == 1500)
        now += 1500
        let completed = session.complete(at: now)
        #expect(completed != nil)
        #expect(session.isFinished, "each focus waits")
        #expect(session.completedFocuses == round)
        let expected: TimerPhase = round == 4 ? .longBreak : .shortBreak
        #expect(session.nextPhase == expected)
        let advanced = session.startNextPhase(at: now)
        #expect(advanced)
        #expect(session.length == (round == 4 ? 900 : 300))
        now += session.length
        let completed2 = session.complete(at: now)
        #expect(completed2 != nil)
        #expect(session.nextPhase == .focus)
        let advanced2 = session.startNextPhase(at: now)
        #expect(advanced2)
    }
    now += 100_000
    let last = session.complete(at: now)
    #expect(last?.endsCycle == true)
    #expect(last?.title == "Pomodoro complete")
    let completed3 = session.complete(at: now + 1)
    #expect(completed3 == nil)
    #expect(session.completedFocuses == 5)
    #expect(session.nextPhase == nil)
    #expect(session.title == "Pomodoro complete")
}

@Test func pomodoroKeepsItsConfigurationAndCountsEachFocusOnce() {
    let plan = PomodoroPlan(focusMinutes: 40, totalSessions: 2)
    var session = TimerSession.pomodoro(plan, at: 0)!
    #expect(session.deadline == 2400)
    _ = session.pause(at: 400)
    let resumed = session.resume(at: 1000)
    #expect(resumed)
    #expect(session.deadline == 3000)
    #expect(session.plan == plan)
    let completed = session.complete(at: 3000)
    #expect(completed != nil)
    let completed2 = session.complete(at: 3001)
    #expect(completed2 == nil)
    #expect(session.completedFocuses == 1)
    #expect(session.nextPhase == .shortBreak)
    session.startNextPhase(at: 3100)
    let completed3 = session.complete(at: 3100 + 300)
    #expect(completed3 != nil)
    #expect(session.completedFocuses == 1, "breaks do not count")
    #expect(session.sessionNumber == 1)
    session.startNextPhase(at: 3500)
    #expect(session.sessionNumber == 2)
    let completed4 = session.complete(at: 3500 + 2400)
    #expect(completed4?.endsCycle == true)
    #expect(session.nextPhase == nil, "no final break")
    let advanced = session.startNextPhase(at: 9000)
    #expect(!advanced, "a finished cycle cannot continue")
}

@Test func aOneSessionGoalEndsAtTheFocus() {
    var session = TimerSession.pomodoro(PomodoroPlan(sessionsBeforeLongBreak: 1, totalSessions: 1), at: 0)!
    let completed = session.complete(at: 1500)
    #expect(completed?.endsCycle == true)
    #expect(session.nextPhase == nil)
}

@Test func unfinishedCyclesOfferExplicitContinuationOnly() {
    var session = TimerSession.pomodoro(.standard, at: 0)!
    _ = session.complete(at: 1500)
    #expect(session.phase == .focus)
    #expect(session.isFinished, "a new phase never starts by itself")
    #expect(session.nextPhase == .shortBreak)
    let completed = session.complete(at: 1_000_000)
    #expect(completed == nil)
}

@Test func pomodoroMenusOfferEveryAcceptedValue() {
    #expect(PomodoroPlan.focusChoices == Array(1...180))
    #expect(PomodoroPlan.breakChoices == Array(1...60))
    #expect(PomodoroPlan.sessionChoices == Array(1...24))
    let standard = PomodoroPlan.standard
    #expect(PomodoroPlan.focusChoices.contains(standard.focusMinutes))
    #expect(PomodoroPlan.breakChoices.contains(standard.shortBreakMinutes))
    #expect(PomodoroPlan.breakChoices.contains(standard.longBreakMinutes))
    #expect(PomodoroPlan.sessionChoices.contains(standard.sessionsBeforeLongBreak))
    #expect(PomodoroPlan.sessionChoices.contains(standard.totalSessions))
}

// MARK: 16 — stopwatch

@Test func stopwatchRunsFromItsAnchorAndNeverCompletes() {
    var session = TimerSession.stopwatch(at: 50)!
    #expect(session.deadline == nil)
    #expect(session.reading(at: 62.5) == 12.5)
    #expect(session.reading(at: 10) == 0, "a clock read before the anchor never shows negative time")
    let completed = session.complete(at: 1e9)
    #expect(completed == nil)
    let paused = session.pause(at: .nan)
    #expect(paused == nil)
    #expect(session.isRunning, "an invalid clock cannot pause it")
    _ = session.pause(at: 100)
    #expect(session.reading(at: 90_000) == 50)
    _ = session.pause(at: 200)
    #expect(session.reading(at: 300) == 50)
    let resumed = session.resume(at: 100_000)
    #expect(resumed)
    #expect(session.reading(at: 100_010) == 60, "resumes from the held reading, not the wall-clock gap")
}

@Test func stopwatchCannotBeReplacedAndCancelReturnsToSetup() {
    var slot = TimerSlot()
    slot.start(TimerSession.stopwatch(at: 0))
    let started = slot.start(TimerSession.stopwatch(at: 99))
    #expect(!started)
    #expect(slot.session?.reading(at: 10) == 10)
    slot.dismiss()
    #expect(slot.session == nil)
}

// MARK: 17 — ticks aligned to the displayed value

@Test func ticksLandWhenTheShownSecondChanges() {
    #expect(TimerTicks.delay(reading: 298.75, countsDown: true) == 0.75)
    #expect(TimerTicks.delay(reading: 299, countsDown: true) == 1)
    #expect(TimerTicks.delay(reading: 0.25, countsDown: true) == 0.25)
    #expect(TimerTicks.delay(reading: 0, countsDown: true) == nil)
    #expect(abs(TimerTicks.delay(reading: 12.3, countsDown: false)! - 0.7) < 1e-9)
    #expect(TimerTicks.delay(reading: 0, countsDown: false) == 1)
    #expect(TimerTicks.delay(reading: .nan, countsDown: true) == 0, "unreadable: tick at once")
    // After the delay the shown value has just changed, and one second later it changes again.
    let remaining = 298.75
    let delay = TimerTicks.delay(reading: remaining, countsDown: true)!
    #expect(TimerFormat.clock(countdown: remaining) == "04:59")
    #expect(TimerFormat.clock(countdown: remaining - delay) == "04:58")
    #expect(TimerFormat.clock(countdown: remaining - delay + 0.001) == "04:59")
    #expect(delay > 0 && delay <= 1, "the first wake is the next boundary, never a full second late")
}

// MARK: 12, 19, 20 — page layout

@Test func setupPageHeights() {
    for width: CGFloat in [320, 424, 480, 504, 560] {
        for mode in TimerMode.allCases {
            let full = TimerPageLayout.setup(mode: mode, width: width, budget: 400)
            #expect(full.ruler == 82)
            #expect(full.height >= TimerPageLayout.modeRow + 8 + 56)
            #expect(TimerPageLayout.activeHeight(mode: mode) >= 96)
            #expect(TimerPageLayout.activeHeight(mode: mode) < full.height, "the active page is shorter than setup")
            let squeezed = TimerPageLayout.setup(mode: mode, width: width, budget: 60)
            #expect(squeezed.ruler == 56, "the ruler shrinks to 56 before anything is cut")
        }
    }
    #expect(TimerPageLayout.setup(mode: .timer, width: 424, budget: 180).height == 126)
    #expect(TimerPageLayout.setup(mode: .pomodoro, width: 424, budget: 180).height == 162)
    #expect(TimerPageLayout.setup(mode: .timer, width: 320, budget: 180).height == 170)
}

@Test func switchingBetweenTimerAndStopwatchNeverResizes() {
    for width: CGFloat in [320, 424, 504] {
        let timer = TimerPageLayout.setup(mode: .timer, width: width, budget: 264)
        let stopwatch = TimerPageLayout.setup(mode: .stopwatch, width: width, budget: 264)
        #expect(timer.height == stopwatch.height && timer.ruler == stopwatch.ruler)
        #expect(TimerPageLayout.activeHeight(mode: .timer) == TimerPageLayout.activeHeight(mode: .stopwatch))
    }
}

@Test func startSitsBesideTheModesFromFourHundredPoints() {
    #expect(TimerPageLayout.isWide(400))
    #expect(TimerPageLayout.isWide(424))
    #expect(!TimerPageLayout.isWide(399))
}

@Test func eachModeHasItsOwnName() {
    #expect(Set(TimerMode.allCases.map(\.title)).count == 3)
    #expect(TimerPhase.allCases.map(\.title) == ["Timer", "Focus", "Short break", "Long break", "Stopwatch"])
}

// MARK: 22 — ruler

@Test func rulerHourLabelsUseH() {
    #expect(TimerRuler.label(1) == "1")
    #expect(TimerRuler.label(45) == "45")
    #expect(TimerRuler.label(60) == "1h00")
    #expect(TimerRuler.label(65) == "1h05")
    #expect(TimerRuler.label(180) == "3h00")
    #expect(TimerRuler.hasLabel(1) && TimerRuler.hasLabel(5) && TimerRuler.hasLabel(180))
    #expect(!TimerRuler.hasLabel(2) && !TimerRuler.hasLabel(59))
}

@Test func selectedMinuteSitsUnderThePointer() {
    for selected in [1, 15, 180] {
        #expect(TimerRuler.offset(of: selected, selected: selected) == 0)
        #expect(TimerRuler.minute(atOffset: 0, selected: selected) == selected)
        #expect(TimerRuler.visibleMinutes(selected: selected, width: 300).contains(selected))
    }
    #expect(TimerRuler.visibleMinutes(selected: 1, width: 300).lowerBound == 1)
    #expect(TimerRuler.visibleMinutes(selected: 180, width: 300).upperBound == 180)
}

@Test func draggingOneTickChangesOneMinuteInTheMatchingDirection() {
    var drag = TimerRuler.Drag(startX: 200, value: 15)
    let minute = drag.move(to: 190)
    #expect(minute == 15, "less than a tick does nothing")
    let minute2 = drag.move(to: 186)
    #expect(minute2 == 16, "dragging left increases")
    let minute3 = drag.move(to: 186 + 14)
    #expect(minute3 == 15, "dragging right decreases")
    let minute4 = drag.move(to: 200 + 14 * 3)
    #expect(minute4 == 12)
}

@Test func draggingPastAnEndHasNoDeadZone() {
    var drag = TimerRuler.Drag(startX: 100, value: 3)
    let minute = drag.move(to: 100 + 14 * 20)
    #expect(minute == 1)
    let minute2 = drag.move(to: 100 + 14 * 19)
    #expect(minute2 == 2, "reversing responds at once")
    var top = TimerRuler.Drag(startX: 500, value: 178)
    let minute3 = top.move(to: 500 - 14 * 30)
    #expect(minute3 == 180)
    let minute4 = top.move(to: 500 - 14 * 29)
    #expect(minute4 == 179)
}

@Test func clickingATickSelectsItWithTheSameSpacing() {
    #expect(TimerRuler.minute(atOffset: 14, selected: 15) == 16)
    #expect(TimerRuler.minute(atOffset: -28, selected: 15) == 13)
    #expect(TimerRuler.minute(atOffset: 6.9, selected: 15) == 15)
    #expect(TimerRuler.minute(atOffset: 14 * 5, selected: 15) == 20)
    #expect(TimerRuler.minute(atOffset: 14 * 5, selected: 15) == 15 + Int(TimerRuler.offset(of: 20, selected: 15) / 14))
    #expect(TimerRuler.minute(atOffset: -1000, selected: 3) == 1)
}

@Test func fineScrollDeltasAccumulateUntilTheyCrossATick() {
    var scroll = TimerRuler.Scroll()
    var total = 0
    for _ in 0..<6 { total += scroll.steps(deltaX: 0, deltaY: 2, precise: true) }
    #expect(total == 0, "12 pt is less than a tick")
    total += scroll.steps(deltaX: 0, deltaY: 2, precise: true)
    #expect(total == 1)
    scroll.reset()
    let steps = scroll.steps(deltaX: 0, deltaY: 13, precise: true)
    #expect(steps == 0)
    let steps2 = scroll.steps(deltaX: 0, deltaY: 1, precise: true)
    #expect(steps2 == 1, "carried across events")
    scroll.reset()
    let steps3 = scroll.steps(deltaX: -30, deltaY: 1, precise: true)
    #expect(steps3 == 2, "the larger axis wins; leftward adds")
    var wheel = TimerRuler.Scroll()
    let steps4 = wheel.steps(deltaX: 0, deltaY: 0.1, precise: false)
    #expect(steps4 == 1, "a wheel notch is one tick")
    let steps5 = wheel.steps(deltaX: 0, deltaY: -3, precise: false)
    #expect(steps5 == -1)
}

@Test func keysMoveOneMinuteOrJumpToTheEnds() {
    #expect(TimerRuler.minute(after: .left, selected: 15) == 14)
    #expect(TimerRuler.minute(after: .down, selected: 1) == 1)
    #expect(TimerRuler.minute(after: .right, selected: 15) == 16)
    #expect(TimerRuler.minute(after: .up, selected: 180) == 180)
    #expect(TimerRuler.minute(after: .home, selected: 90) == 1)
    #expect(TimerRuler.minute(after: .end, selected: 90) == 180)
}

@Test func invalidOrExcessiveRulerValuesStayInRange() {
    #expect(TimerRuler.clamp(0) == 1)
    #expect(TimerRuler.clamp(Int.max) == 180)
    #expect(TimerRuler.clamp(Int.min) == 1)
    #expect(TimerRuler.clamp(Double.nan) == 1)
    #expect(TimerRuler.clamp(Double.infinity) == 180)
    #expect(TimerRuler.clamp(42.4) == 42)
}

@Test func ticksFadeOverTheOuterTwelvePercent() {
    #expect(TimerRuler.edgeOpacity(offset: 0, width: 300) == 1)
    #expect(TimerRuler.edgeOpacity(offset: 150, width: 300) == 0)
    #expect(abs(TimerRuler.edgeOpacity(offset: 150 - 18, width: 300) - 0.5) < 1e-9)
    #expect(TimerRuler.edgeOpacity(offset: 200, width: 300) == 0)
}

// MARK: Strip (spec-activity §3.4, rules 10, 11, 13)

@Test func stripWingsFitTheReadingWithinFortyFourToSixtyFour() {
    #expect(TimerStripMetrics.wing(fit: 30) == 44, "a short reading keeps 44 pt wings")
    #expect(TimerStripMetrics.wing(fit: 51.2) == 52)
    #expect(TimerStripMetrics.wing(fit: 90) == 64)
    #expect(TimerStripMetrics.minimumRoom == 64)
}

@Test func stripContentClearsTheCurveByTheGap() {
    // A 32-pt notch: the shoulder is 6.08 pt, so nothing sits closer than 11.08 pt to the end.
    let flat = TimerStripMetrics.edgeInset(stripHeight: 32, contentHeight: 22, cornerRadius: 5.88)
    #expect(abs(flat - 11.08) < 0.01)
    let bars = TimerStripMetrics.edgeInset(stripHeight: 32, contentHeight: 16, cornerRadius: 0.9)
    #expect(abs(bars - 11.5) < 0.05)
    for height in stride(from: CGFloat(24), through: 64, by: 4) {
        let font = TimerStripMetrics.readingFontSize(height: height)
        let box = TimerStripMetrics.textBoxHeight(fontSize: font)
        let inset = TimerStripMetrics.edgeInset(stripHeight: height, contentHeight: box)
        let outline = IslandSilhouette(width: 400, height: height)
        #expect(inset >= outline.shoulder + 5)
        // The box's lower outer corner keeps 5 pt from the bottom arc.
        let corner = CGPoint(x: inset, y: (height + box) / 2)
        let centre = CGPoint(x: outline.shoulder + outline.bottomRadius, y: height - outline.bottomRadius)
        if corner.y > centre.y, corner.x < centre.x {
            let distance = hypot(corner.x - centre.x, corner.y - centre.y)
            #expect(outline.bottomRadius - distance >= 5 - 1e-6, "height \(height)")
        }
    }
}

@Test func stripWingForTypicalReadings() {
    let fit = TimerStripMetrics.fit(readingWidth: 28, height: 32)
    #expect(TimerStripMetrics.wing(fit: fit) == 46)
    #expect(TimerStripMetrics.showsReading(wing: 44))
    #expect(!TimerStripMetrics.showsReading(wing: 41))
    #expect(TimerStripMetrics.showsMark(wing: 28))
    #expect(!TimerStripMetrics.showsMark(wing: 27))
    #expect(TimerStripMetrics.readingFontSize(height: 32) == 16)
    #expect(TimerStripMetrics.readingFontSize(height: 20) == 14)
    #expect(TimerStripMetrics.markSize(height: 32) == 20)
    #expect(TimerStripMetrics.markSize(height: 24) == 14)
}

// MARK: 23 — alarm

@Test func alarmRingsAtOnceEveryTwoSecondsForAtMostFiveMinutes() {
    var alarm = TimerAlarm()
    alarm.arm(at: 1000)
    let command = alarm.sync(soundOn: true, suspended: false, now: 1000)
    #expect(command == .start)
    var rings = 1
    var now: Double = 1000
    while let delay = alarm.nextRing(after: now) {
        #expect(delay == 2)
        now += delay
        rings += 1
    }
    #expect(now < 1300)
    #expect(rings == 150)
    #expect(!alarm.isRinging)
}

@Test func alarmIsSilentWhenTheSoundIsOff() {
    var alarm = TimerAlarm()
    alarm.arm(at: 0)
    let command = alarm.sync(soundOn: false, suspended: false, now: 0)
    #expect(command == .none)
    #expect(!alarm.isRinging)
}

@Test func syncingPreferencesNeverStartsASecondLoop() {
    var alarm = TimerAlarm()
    alarm.arm(at: 0)
    let command = alarm.sync(soundOn: true, suspended: false, now: 0)
    #expect(command == .start)
    let command2 = alarm.sync(soundOn: true, suspended: false, now: 1)
    #expect(command2 == .none)
    let next = alarm.nextRing(after: 2)
    #expect(next == 2, "repeats until acknowledged")
}

@Test func disablingStopsAndReEnablingResumesWithinTheOriginalBudget() {
    var alarm = TimerAlarm()
    alarm.arm(at: 0)
    _ = alarm.sync(soundOn: true, suspended: false, now: 0)
    let command = alarm.sync(soundOn: false, suspended: false, now: 10)
    #expect(command == .stop)
    let next = alarm.nextRing(after: 10)
    #expect(next == nil, "the pending replay is dropped")
    let command2 = alarm.sync(soundOn: true, suspended: false, now: 100)
    #expect(command2 == .start)
    let command3 = alarm.sync(soundOn: true, suspended: true, now: 120)
    #expect(command3 == .stop, "suspension stops playback")
    let command4 = alarm.sync(soundOn: true, suspended: false, now: 200)
    #expect(command4 == .start, "and keeps the budget")
    let command5 = alarm.sync(soundOn: false, suspended: false, now: 250)
    #expect(command5 == .stop)
    let command6 = alarm.sync(soundOn: true, suspended: false, now: 300)
    #expect(command6 == .none, "after five minutes nothing restarts it")
    let command7 = alarm.sync(soundOn: true, suspended: false, now: 10_000)
    #expect(command7 == .none)
}

@Test func aNewPhaseGetsAFreshBudgetAndDismissalPreventsDelayedPlayback() {
    var alarm = TimerAlarm()
    alarm.arm(at: 0)
    _ = alarm.sync(soundOn: true, suspended: false, now: 0)
    let acknowledged = alarm.acknowledge()
    #expect(acknowledged == .stop)
    let next = alarm.nextRing(after: 1)
    #expect(next == nil)
    let command = alarm.sync(soundOn: true, suspended: false, now: 2)
    #expect(command == .none)
    alarm.arm(at: 400)
    let command2 = alarm.sync(soundOn: true, suspended: false, now: 400)
    #expect(command2 == .start)
}
