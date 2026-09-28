import CoreGraphics
import Foundation
import Testing
@testable import IslandKit

// The AI Agents section's rules, restated from the spec (core §6, activity §1, §3 and §4.11).

private let now = Date(timeIntervalSince1970: 1_790_000_000)

private func window(_ agent: AgentKind, _ key: String, used: Double, resetsIn: Double? = 3600, length: Double? = 18_000,
                    label: String? = nil, account: String? = "a") -> AgentLimitWindow {
    AgentLimitWindow(agent: agent, key: key, label: label ?? key.capitalized, usedPercent: used,
                     resetsAt: resetsIn.map { now.addingTimeInterval($0) }, windowSeconds: length, readAt: now, account: account)
}

private func line(_ text: String) -> Data { Data(text.utf8) }

// MARK: Limits

@Test func bindingWindowIsTheMostUsedAcrossAgents() {
    let windows = [window(.claude, "session", used: 40), window(.claude, "weekly", used: 70, length: 604_800),
                   window(.codex, "session", used: 55), window(.codex, "weekly", used: 81, length: 604_800)]
    #expect(AgentLimits.binding(windows, now: now)?.id == "codex.weekly")
}

@Test func bindingTieWithinAnAgentGoesToTheOneRenewingLater() {
    let windows = [window(.claude, "session", used: 60, resetsIn: 3600), window(.claude, "weekly", used: 60, resetsIn: 90_000, length: 604_800)]
    #expect(AgentLimits.binding(windows, now: now)?.id == "claude.weekly")
}

@Test func bindingTieAcrossAgentsGoesToClaude() {
    let windows = [window(.codex, "session", used: 50, resetsIn: 90_000), window(.claude, "session", used: 50, resetsIn: 60)]
    #expect(AgentLimits.binding(windows, now: now)?.agent == .claude)
}

@Test func aWindowPastItsResetCountsAsNothingUsed() {
    let expired = window(.claude, "session", used: 99, resetsIn: -10)
    #expect(expired.used(at: now) == 0)
    let windows = [expired, window(.codex, "session", used: 20)]
    #expect(AgentLimits.binding(windows, now: now)?.agent == .codex)
}

@Test func codexModelAllowancesNeverStandInForTheMainOne() {
    let windows = [window(.codex, "session", used: 10), window(.codex, "spark", used: 90), window(.codex, "sparkWeekly", used: 95)]
    #expect(AgentLimits.binding(windows, now: now)?.key == "session")
    var alerts = AgentLimitAlerts()
    _ = alerts.observe([window(.codex, "spark", used: 10)], threshold: 80, now: now)
    #expect(alerts.observe([window(.codex, "spark", used: 90)], threshold: 80, now: now).isEmpty)
}

@Test func limitColoursTurnOrangeAtEightyAndRedAtNinetyFiveUsed() {
    #expect(AgentLimitTone.tone(used: 79.9) == .agent)
    #expect(AgentLimitTone.tone(used: 80) == .orange)
    #expect(AgentLimitTone.tone(used: 94.9) == .orange)
    #expect(AgentLimitTone.tone(used: 95) == .red)
}

@Test func limitsReadAsLeftOrUsed() {
    let reading = window(.claude, "session", used: 82)
    #expect(AgentLimits.phrase(reading, display: .left, now: now) == "18% left")
    #expect(AgentLimits.phrase(reading, display: .used, now: now) == "82% used")
    #expect(AgentLimits.percent(reading, display: .left, now: now) == "18%")
    #expect(abs(AgentLimits.fraction(reading, display: .left, now: now) - 0.18) < 1e-9)
}

@Test func windowsAreNamedForNotices() {
    #expect(window(.claude, "session", used: 1).noticeTitle == "Claude · Session")
    #expect(window(.codex, "weekly", used: 1, length: 604_800).noticeTitle == "Codex · Week")
    #expect(window(.claude, "opus", used: 1, length: 604_800, label: "Opus").noticeTitle == "Claude · Week · Opus")
}

@Test func limitsCardShowsTheSessionAndTheMostUsedLongerWindow() {
    let windows = [window(.claude, "weekly", used: 30, length: 604_800), window(.claude, "session", used: 10),
                   window(.claude, "sonnet", used: 45, length: 604_800, label: "Sonnet"), window(.codex, "session", used: 90)]
    #expect(AgentLimits.cardRows(windows, agent: .claude, now: now).map(\.key) == ["session", "sonnet"])
}

@Test func paceTickSitsAtTheElapsedFractionAndMirrorsForLeft() {
    let half = window(.claude, "session", used: 10, resetsIn: 9000, length: 18_000)
    #expect(AgentLimits.paceTick(half, display: .used, now: now) == 0.5)
    let quarter = window(.claude, "session", used: 10, resetsIn: 13_500, length: 18_000)
    #expect(AgentLimits.paceTick(quarter, display: .used, now: now) == 0.25)
    #expect(AgentLimits.paceTick(quarter, display: .left, now: now) == 0.75)
}

@Test func paceTickIsHiddenNearTheEndsAndForRenewedOrEarlyReadings() {
    #expect(AgentLimits.paceTick(window(.claude, "session", used: 1, resetsIn: 17_900, length: 18_000), display: .used, now: now) == nil)
    #expect(AgentLimits.paceTick(window(.claude, "session", used: 1, resetsIn: 100, length: 18_000), display: .used, now: now) == nil)
    #expect(AgentLimits.paceTick(window(.claude, "session", used: 1, resetsIn: -5, length: 18_000), display: .used, now: now) == nil)
    var early = window(.claude, "session", used: 1, resetsIn: 9000, length: 18_000)
    early.readAt = now.addingTimeInterval(-10_000)
    #expect(AgentLimits.paceTick(early, display: .used, now: now) == nil)
}

// MARK: Limit alerts

@Test func theFirstReadingIsNeverAWarning() {
    var alerts = AgentLimitAlerts()
    #expect(alerts.observe([window(.claude, "session", used: 90)], threshold: 80, now: now).isEmpty)
}

@Test func aWarningComesOncePerCrossing() {
    var alerts = AgentLimitAlerts()
    _ = alerts.observe([window(.claude, "session", used: 70)], threshold: 80, now: now)
    let crossing = alerts.observe([window(.claude, "session", used: 85)], threshold: 80, now: now)
    #expect(crossing == [.warning(window(.claude, "session", used: 85))])
    #expect(alerts.observe([window(.claude, "session", used: 88)], threshold: 80, now: now).isEmpty)
}

@Test func aRenewedInstanceAlreadyAboveTheThresholdWarnsAgain() {
    var alerts = AgentLimitAlerts()
    _ = alerts.observe([window(.claude, "session", used: 90, resetsIn: 600)], threshold: 80, now: now)
    let renewed = window(.claude, "session", used: 91, resetsIn: 18_600)
    #expect(alerts.observe([renewed], threshold: 80, now: now) == [.warning(renewed)])
}

@Test func aWarnedWindowIsReportedRenewedWhenItsResetPasses() {
    var alerts = AgentLimitAlerts()
    _ = alerts.observe([window(.claude, "session", used: 70, resetsIn: 600)], threshold: 80, now: now)
    let warned = window(.claude, "session", used: 85, resetsIn: 600)
    _ = alerts.observe([warned], threshold: 80, now: now)
    #expect(alerts.nextRenewal == now.addingTimeInterval(600))
    #expect(alerts.tick(now: now.addingTimeInterval(599)).isEmpty)
    #expect(alerts.tick(now: now.addingTimeInterval(601)) == [.renewed(warned)])
    #expect(alerts.tick(now: now.addingTimeInterval(700)).isEmpty)
}

@Test func anotherAccountsReadingIsNotComparedWithTheLast() {
    var alerts = AgentLimitAlerts()
    _ = alerts.observe([window(.claude, "session", used: 10, account: "a")], threshold: 80, now: now)
    #expect(alerts.observe([window(.claude, "session", used: 95, account: "b")], threshold: 80, now: now).isEmpty)
}

// MARK: Formatting

@Test func elapsedReadsLikeAStopwatch() {
    #expect(AgentFormat.elapsed(42) == "0:42")
    #expect(AgentFormat.elapsed(725) == "12:05")
    #expect(AgentFormat.elapsed(3725) == "1:02:05")
}

@Test func tokensShortenWithoutRoundingUp() {
    let english = Locale(identifier: "en_US")
    #expect(AgentFormat.tokens(950, locale: english) == "950")
    #expect(AgentFormat.tokens(4_299, locale: english) == "4.2K")
    #expect(AgentFormat.tokens(4_000, locale: english) == "4K")
    #expect(AgentFormat.tokens(48_999, locale: english) == "48K")
    #expect(AgentFormat.tokens(120_500, locale: english) == "120K")
    #expect(AgentFormat.tokens(1_599_999, locale: english) == "1.5M")
    #expect(AgentFormat.tokens(4_299, locale: Locale(identifier: "de_DE")) == "4,2K")
}

@Test func costsKeepCentsUnderAHundred() {
    let english = Locale(identifier: "en_US")
    #expect(AgentFormat.cost(4.56, locale: english) == "$4.56")
    #expect(AgentFormat.cost(0.05, locale: english) == "$0.05")
    #expect(AgentFormat.cost(123.4, locale: english) == "$123")
    #expect(AgentFormat.cost(12_345, locale: english) == "$12K")
}

@Test func durationsAndCountdownsNeverShowSecondsPastAMinute() {
    #expect(AgentFormat.duration(42) == "42s")
    #expect(AgentFormat.duration(252) == "4m 12s")
    #expect(AgentFormat.duration(3900) == "1h 05m")
    #expect(AgentFormat.countdown(7_500) == "2h 05m")
    #expect(AgentFormat.countdown(30) == "1m")
    #expect(AgentFormat.countdown(0) == "1m")
    #expect(AgentFormat.countdown(3 * 86_400 + 4 * 3600) == "3d 4h")
}

@Test func modelNamesReadAsPeopleSayThem() {
    #expect(AgentFormat.modelName("claude-opus-5-5") == "Opus 5.5")
    #expect(AgentFormat.modelName("claude-haiku-4-5-20251001") == "Haiku 4.5")
    #expect(AgentFormat.modelName("anthropic/claude-opus-5[1m]") == "Opus 5")
    #expect(AgentFormat.modelName("claude-3-5-sonnet-20241022") == "Sonnet 3.5")
    #expect(AgentFormat.modelName("gpt-6-astra") == "GPT-6 Astra")
    #expect(AgentFormat.modelName("gpt-5.1-codex-latest") == "GPT-5.1 Codex")
    #expect(AgentFormat.modelName("<synthetic>") == nil)
}

@Test func worktreesBelongToTheirRepository() {
    #expect(AgentFormat.projectName("/Users/example/Developer/MenuSprite/.claude/worktrees/agent-3/native") == "MenuSprite")
    #expect(AgentFormat.projectName("/Users/example/Developer/Example-App") == "Example-App")
    #expect(AgentFormat.projectName(nil) == nil)
}

@Test func timestampsParseToUTCWithFractionsAndOffsets() throws {
    let iso = ISO8601DateFormatter()
    let reference = try #require(iso.date(from: "2026-09-28T06:14:44Z"))
    #expect(AgentTimestamp.parse(Array("2026-09-28T06:14:44Z".utf8)) == reference)
    #expect(AgentTimestamp.parse(Array("2026-09-28T11:44:44+05:30".utf8)) == reference)
    #expect(AgentTimestamp.parse(Array("2026-09-27T23:14:44-0700".utf8)) == reference)
    let fractional = try #require(AgentTimestamp.parse(Array("2026-09-28T06:14:44.866Z".utf8)))
    #expect(abs(fractional.timeIntervalSince(reference) - 0.866) < 1e-6)
    #expect(AgentTimestamp.parse(Array("not a date at all".utf8)) == nil)
}

// MARK: Registry and Claude transcripts

@Test func registryRecordsCarryStatusAndWhenItChanged() throws {
    let record = try #require(ClaudeRegistryRecord.parse(line(
        #"{"pid":123,"sessionId":"s-1","cwd":"/tmp/project","status":"busy","statusUpdatedAt":1790000000000,"updatedAt":1,"name":"fix","nameSource":"user"}"#)))
    #expect(record.isBusy)
    #expect(record.statusChangedAt == Date(timeIntervalSince1970: 1_790_000_000))
    #expect(record.userTitle == "fix")
    #expect(ClaudeRegistryRecord.parse(line(#"{"pid":123,"status":"busy"}"#)) == nil)
    let derived = try #require(ClaudeRegistryRecord.parse(line(#"{"pid":1,"sessionId":"s","name":"brave-otter","nameSource":"derived"}"#)))
    #expect(derived.userTitle == nil)
    #expect(derived.status == nil)
}

private let toolUse = #"{"type":"assistant","sessionId":"s","requestId":"r1","timestamp":"2026-09-28T06:00:10Z","message":{"id":"m1","model":"claude-opus-5-5","stop_reason":"tool_use","usage":{"input_tokens":10,"cache_read_input_tokens":2000,"cache_creation_input_tokens":300,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":100},"output_tokens":50}}}"#
private let endTurn = #"{"type":"assistant","sessionId":"s","requestId":"r2","timestamp":"2026-09-28T06:01:00Z","message":{"id":"m2","model":"claude-opus-5-5","stop_reason":"end_turn","usage":{"input_tokens":5,"output_tokens":400}}}"#

@Test func anAssistantReplyYieldsEveryTokenKindKeyedByMessageAndRequest() throws {
    guard case .response(let response)? = ClaudeLogLine.classify(line(toolUse)) else { Issue.record("not a response"); return }
    #expect(response.key == "m1\u{0}r1")
    #expect(response.model == "claude-opus-5-5")
    #expect(response.tokens == AgentTokens(input: 10, cacheWrite5m: 100, cacheWrite1h: 200, cacheRead: 2000, output: 50))
    #expect(response.stop == .working)
    guard case .response(let final)? = ClaudeLogLine.classify(line(endTurn)) else { Issue.record("not a response"); return }
    #expect(final.stop == .completed)
}

@Test func apiErrorsAndSyntheticRepliesEndWithoutBilling() {
    let error = #"{"type":"assistant","isApiErrorMessage":true,"timestamp":"2026-09-28T06:01:00Z","message":{"id":"m","model":"claude-opus-5-5","stop_reason":"end_turn","usage":{"output_tokens":3}}}"#
    guard case .response(let failed)? = ClaudeLogLine.classify(line(error)) else { Issue.record("not a response"); return }
    #expect(failed.stop == .failed)
    let synthetic = #"{"type":"assistant","timestamp":"2026-09-28T06:01:00Z","message":{"id":"m","model":"<synthetic>","stop_reason":"end_turn","usage":{"input_tokens":9,"output_tokens":3}}}"#
    guard case .response(let local)? = ClaudeLogLine.classify(line(synthetic)) else { Issue.record("not a response"); return }
    #expect(local.tokens.total == 0)
    #expect(local.stop == .failed)
}

@Test func userLinesStartEndOrContinueTurns() {
    let time = AgentTimestamp.parse(Array("2026-09-28T06:00:00Z".utf8))
    #expect(ClaudeLogLine.classify(line(#"{"type":"user","timestamp":"2026-09-28T06:00:00Z","message":{"role":"user","content":"Fix the build"}}"#)) == .prompt(time))
    #expect(ClaudeLogLine.classify(line(#"{"type":"user","isMeta":true,"timestamp":"2026-09-28T06:00:00Z","message":{"content":"Caveat"}}"#)) == .activity(time!))
    #expect(ClaudeLogLine.classify(line(#"{"type":"user","isSidechain":true,"timestamp":"2026-09-28T06:00:00Z","message":{"content":"Subagent task"}}"#)) == .activity(time!))
    #expect(ClaudeLogLine.classify(line(#"{"type":"user","timestamp":"2026-09-28T06:00:00Z","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#)) == .interrupted(time))
    #expect(ClaudeLogLine.classify(line(#"{"type":"user","timestamp":"2026-09-28T06:00:00Z","message":{"content":"<local-command-stdout>done</local-command-stdout>"}}"#)) == .interrupted(time))
    // A tool result that quotes an interruption is still just a tool result.
    #expect(ClaudeLogLine.classify(line(#"{"type":"user","timestamp":"2026-09-28T06:00:00Z","message":{"content":[{"type":"tool_result","content":"[Request interrupted by user for tool use]"}]}}"#)) == .activity(time!))
}

@Test func anEscapedKeyInsideAValueNeverPassesTheByteFilter() {
    let quoted = #"{"type":"user","timestamp":"2026-09-28T06:00:00Z","message":{"content":"say \"type\":\"assistant\" please"}}"#
    guard case .prompt? = ClaudeLogLine.classify(line(quoted)) else { Issue.record("an escaped key was treated as structure"); return }
}

@Test func titlesComeFromCustomOverAutomatic() {
    var tracker = ClaudeTurnTracker()
    tracker.apply(ClaudeLogLine.classify(line(#"{"type":"ai-title","aiTitle":"Auto"}"#))!)
    #expect(tracker.title == "Auto")
    tracker.apply(ClaudeLogLine.classify(line(#"{"type":"custom-title","customTitle":"Mine"}"#))!)
    tracker.apply(.title("Later auto", isCustom: false))
    #expect(tracker.title == "Mine")
}

@Test func aPromptStartsATurnAtItsOwnTimeAndAReplyEndsIt() {
    let start = now, reply = now.addingTimeInterval(90)
    var tracker = ClaudeTurnTracker()
    tracker.apply(.prompt(start))
    #expect(tracker.isOpen && tracker.openedAt == start)
    tracker.apply(.response(AgentResponse(key: "a", model: "claude-opus-5-5", tokens: AgentTokens(), time: now.addingTimeInterval(5), stop: .working)))
    tracker.apply(.activity(now.addingTimeInterval(6)))
    #expect(tracker.isOpen && tracker.openedAt == start)
    tracker.apply(.response(AgentResponse(key: "b", model: "claude-opus-5-5", tokens: AgentTokens(), time: reply, stop: .completed)))
    #expect(!tracker.isOpen)
    #expect(tracker.lastEnd == .completed && tracker.endedAt == reply)
    #expect(tracker.model == "claude-opus-5-5")
}

@Test func aSubagentFinishingNeverFinishesItsParent() {
    var tracker = ClaudeTurnTracker()
    tracker.apply(.prompt(now))
    tracker.apply(.response(AgentResponse(key: "s", model: "claude-haiku-4-5", tokens: AgentTokens(), time: now, stop: .completed, isSidechain: true)))
    #expect(tracker.isOpen)
    #expect(tracker.model == nil)
}

@Test func interruptionsEndATurnWithNothingToAnnounce() {
    var tracker = ClaudeTurnTracker()
    tracker.apply(.prompt(now))
    tracker.apply(.interrupted(now.addingTimeInterval(3)))
    #expect(!tracker.isOpen && tracker.lastEnd == .silent)
    tracker.apply(.prompt(now.addingTimeInterval(10)))
    tracker.apply(.response(AgentResponse(key: "e", model: "claude-opus-5-5", tokens: AgentTokens(), time: now, stop: .failed)))
    #expect(tracker.lastEnd == .silent)
}

// MARK: Spend

@Test func duplicatesCountOnceAtTheirFinalOutput() {
    var spend = AgentTurnSpend()
    spend.add(key: "m1", model: "claude-opus-5-5", tokens: AgentTokens(input: 10, output: 5))
    spend.add(key: "m1", model: "claude-opus-5-5", tokens: AgentTokens(input: 10, output: 50))
    spend.add(key: "m1", model: "claude-opus-5-5", tokens: AgentTokens(input: 10, output: 20))
    spend.add(key: "m2", model: "claude-haiku-4-5", tokens: AgentTokens(output: 7))
    #expect(spend.responseCount == 2)
    #expect(spend.total == AgentTokens(input: 10, output: 57))
    #expect(spend.byModel["claude-opus-5-5"] == AgentTokens(input: 10, output: 50))
}

// MARK: Codex

@Test func codexRecordsTakeCachedInputOutOfInput() throws {
    let record = #"{"timestamp":"2026-09-28T06:00:00Z","type":"token_usage_record","payload":{"response_id":"resp_1","usage":{"input_tokens":38120,"cached_input_tokens":22144,"cache_write_input_tokens":0,"output_tokens":206,"reasoning_output_tokens":8,"total_tokens":38326}}}"#
    guard case .usage(let key, let tokens, _)? = CodexLogLine.classify(line(record)) else { Issue.record("not usage"); return }
    #expect(key == "resp_1")
    #expect(tokens == AgentTokens(input: 15_976, cacheRead: 22_144, output: 206))
}

@Test func codexTasksReportTheirOwnDuration() {
    let started = #"{"timestamp":"2026-09-28T06:00:00Z","type":"event_msg","payload":{"type":"task_started","started_at":1790392901}}"#
    let complete = #"{"timestamp":"2026-09-28T06:10:00Z","type":"event_msg","payload":{"type":"task_complete","completed_at":1790395225,"duration_ms":2323565}}"#
    #expect(CodexLogLine.classify(line(started)) == .started(Date(timeIntervalSince1970: 1_790_392_901)))
    #expect(CodexLogLine.classify(line(complete)) == .completed(at: Date(timeIntervalSince1970: 1_790_395_225), duration: 2323.565))
    let aborted = #"{"timestamp":"2026-09-28T06:10:00Z","type":"event_msg","payload":{"type":"turn_aborted"}}"#
    guard case .aborted? = CodexLogLine.classify(line(aborted)) else { Issue.record("not aborted"); return }
}

@Test func codexTurnsAccumulateSpendAndEndAsCompletedOrAborted() {
    var tracker = CodexTurnTracker()
    tracker.apply(.context(model: "gpt-6-astra", directory: "/tmp/app"))
    tracker.apply(.started(now))
    tracker.apply(.usage(key: "r1", tokens: AgentTokens(input: 100, output: 10), time: now.addingTimeInterval(1)))
    tracker.apply(.usage(key: "r1", tokens: AgentTokens(input: 100, output: 10), time: now.addingTimeInterval(1)))
    #expect(tracker.isOpen)
    let ended = tracker.apply(.completed(at: now.addingTimeInterval(300), duration: 299))
    #expect(ended?.outcome == .completed(duration: 299))
    #expect(ended?.spend.total == AgentTokens(input: 100, output: 10))
    #expect(ended?.model == "gpt-6-astra")
    #expect(!tracker.isOpen)
    tracker.apply(.started(now.addingTimeInterval(400)))
    #expect(tracker.spend.total.total == 0)
    let aborted = tracker.apply(.aborted(now.addingTimeInterval(500)))
    #expect(aborted?.outcome == .aborted)
    let stray = tracker.apply(.completed(at: now, duration: 1))
    #expect(stray == nil)
}

@Test func codexRunningTotalsCountGrowthOnceAndStopOnceRecordsAppear() {
    var tracker = CodexTurnTracker()
    tracker.apply(.started(now))
    tracker.apply(.totals(last: nil, total: AgentTokens(input: 100, output: 10), time: now))
    tracker.apply(.totals(last: nil, total: AgentTokens(input: 250, output: 30), time: now))
    #expect(tracker.spend.total == AgentTokens(input: 250, output: 30))
    tracker.apply(.totals(last: AgentTokens(input: 5, output: 5), total: AgentTokens(input: 900, output: 90), time: now))
    #expect(tracker.spend.total == AgentTokens(input: 255, output: 35))
    tracker.apply(.usage(key: "r", tokens: AgentTokens(output: 1), time: now))
    tracker.apply(.totals(last: AgentTokens(input: 1000), total: nil, time: now))
    #expect(tracker.spend.total == AgentTokens(input: 255, output: 36))
}

// MARK: Turn rules

@Test func quietTurnsStopShowingAsWorkingAfterTenMinutes() {
    #expect(AgentTurnRules.isWorking(open: true, lastActivity: now.addingTimeInterval(-300), now: now))
    #expect(!AgentTurnRules.isWorking(open: true, lastActivity: now.addingTimeInterval(-601), now: now))
    #expect(!AgentTurnRules.isWorking(open: false, lastActivity: now, now: now))
}

@Test func finishNoticesFollowLengthCompletionAndNews() {
    #expect(AgentTurnRules.announcesFinish(completed: true, duration: 61, minimum: 60, endedAt: now, now: now, armed: true))
    #expect(!AgentTurnRules.announcesFinish(completed: true, duration: 59, minimum: 60, endedAt: now, now: now, armed: true))
    #expect(AgentTurnRules.announcesFinish(completed: true, duration: 1, minimum: 0, endedAt: now, now: now, armed: true))
    #expect(!AgentTurnRules.announcesFinish(completed: false, duration: 600, minimum: 60, endedAt: now, now: now, armed: true))
    #expect(!AgentTurnRules.announcesFinish(completed: true, duration: 600, minimum: 60, endedAt: now.addingTimeInterval(-301), now: now, armed: true))
    #expect(!AgentTurnRules.announcesFinish(completed: true, duration: 600, minimum: 60, endedAt: now, now: now, armed: false))
}

// MARK: Options and layout

@Test func savedCardOrderIgnoresUnknownAndRepeatedEntriesAndAppendsNewOnes() {
    #expect(AgentCard.normalized(["now", "bogus", "now", "limits"]) == [.now, .limits, .spending, .trend, .models, .projects, .activity])
}

@Test func theLastAgentLeftOnCannotBeSwitchedOff() {
    var options = AgentOptions()
    let codexOff = options.setAgent(.codex, false)
    let claudeOff = options.setAgent(.claude, false)
    #expect(codexOff && !claudeOff)
    #expect(options.isOn(.claude) && !options.isOn(.codex))
    options.finishMinimum = 99_999
    #expect(options.finishMinimum == 3600)
    #expect(AgentOptions().liveActivity && AgentOptions().reading == .time && AgentOptions().warnAt == 80)
}

@Test func onlyTimeAndLimitReadingsNeedAClock() {
    #expect(AgentReading.allCases.filter(\.needsClock) == [.time, .limit])
}

@Test func cardsPairInReadingOrderWithChartsAndLoneCardsFullWidth() {
    #expect(AgentGrid.rows(charts: [false, false, false, false, true, false], width: 424) == [[0, 1], [2, 3], [4], [5]])
    #expect(AgentGrid.rows(charts: [false, true, false], width: 504) == [[0], [1], [2]])
    #expect(AgentGrid.rows(charts: [false, false], width: 380) == [[0], [1]])
}

@Test func thePageIsExactlyAsTallAsItsRows() {
    let charts = [false, false, true]
    #expect(AgentGrid.height(rows: [[0, 1], [2]], charts: charts) == CGFloat(96 + 118 + 10))
    #expect(AgentGrid.height(rows: [], charts: []) == 0)
}

@Test func stripWingsFitTheReadingBetweenFortyFourAndEighty() {
    let inset = AgentStrip.textInset(height: 32, fontSize: 15)
    #expect(inset >= 11.08 && inset < 11.2)
    #expect(AgentStrip.wing(readingWidth: 20, marksWidth: AgentStrip.marksWidth(count: 1), inset: inset) == 44)
    #expect(AgentStrip.wing(readingWidth: 40, marksWidth: 0, inset: inset) == 58)
    #expect(AgentStrip.wing(readingWidth: 70, marksWidth: 0, inset: inset) == 80)
    #expect(abs(AgentStrip.marksWidth(count: 1) - 21.3) < 1e-9)
    #expect(abs(AgentStrip.marksWidth(count: 2) - 34.9) < 1e-9)
    #expect(AgentStrip.restInset(height: 32) == IslandSilhouette(width: 100, height: 32).shoulder + 5)
}

@Test func everyAgentStripElementClearsTheCurveByTheGap() {
    for height in stride(from: CGFloat(24), through: 64, by: 4) {
        let font = AgentStrip.fontSize(height: height)
        let box = 0.72 * font
        let inset = AgentStrip.edgeInset(height: height, contentHeight: box)
        let shape = IslandSilhouette(width: 400, height: height)
        let centre = CGPoint(x: shape.shoulder + shape.bottomRadius, y: height - shape.bottomRadius)
        let corner = CGPoint(x: inset, y: (height + box) / 2)
        if corner.y > centre.y, corner.x < centre.x {
            let distance = ((corner.x - centre.x) * (corner.x - centre.x) + (corner.y - centre.y) * (corner.y - centre.y)).squareRoot()
            #expect(distance + 5 <= shape.bottomRadius + 0.001)
        }
        #expect(inset >= shape.shoulder + 5)
    }
}

@Test func onlyACharacterCountChangeResizesTheStrip() {
    #expect(AgentStrip.shape("12:05") == AgentStrip.shape("59:59"))
    #expect(AgentStrip.shape("9:59") != AgentStrip.shape("10:00"))
    #expect(AgentStrip.shape("4.2K") == AgentStrip.shape("9.9K"))
}

// MARK: Spend

private func testPrice(_ model: String, _ tokens: AgentTokens) -> Double? {
    model.hasPrefix("claude") ? Double(tokens.output) / 1000 : nil
}

@Test func periodsAddOnlyWhatFallsInsideThem() {
    let days = [AgentSpendDay(daysAgo: 0, agent: .claude, models: ["claude-opus-5": AgentTokens(cacheRead: 500, output: 2000)]),
                AgentSpendDay(daysAgo: 3, agent: .claude, models: ["claude-opus-5": AgentTokens(output: 1000)]),
                AgentSpendDay(daysAgo: 20, agent: .claude, models: ["claude-opus-5": AgentTokens(output: 4000)])]
    let today = AgentSpendSummary.make(days: days, period: .today, agents: [.claude], price: testPrice)
    #expect(today.dollars == 2)
    #expect(today.tokens == 2500)
    #expect(today.cacheShare == 0.2)
    #expect(AgentSpendSummary.make(days: days, period: .week, agents: [.claude], price: testPrice).dollars == 3)
    #expect(AgentSpendSummary.make(days: days, period: .month, agents: [.claude], price: testPrice).dollars == 7)
}

@Test func trendBarsRunOldestToTodayAndAWeekAtLeast() {
    let days = [AgentSpendDay(daysAgo: 0, agent: .claude, models: ["claude-opus-5": AgentTokens(output: 2000)]),
                AgentSpendDay(daysAgo: 6, agent: .claude, models: ["claude-opus-5": AgentTokens(output: 1000)])]
    let summary = AgentSpendSummary.make(days: days, period: .today, agents: [.claude], price: testPrice)
    #expect(summary.bars.count == 7)
    #expect(summary.bars.last?[.claude] == 2)
    #expect(summary.bars.first?[.claude] == 1)
    #expect(AgentSpendSummary.make(days: days, period: .month, agents: [.claude], price: testPrice).bars.count == 30)
}

@Test func unpricedWorkMakesDollarsAMinimumAndRanksByTokens() {
    let days = [AgentSpendDay(daysAgo: 0, agent: .claude, models: ["claude-opus-5": AgentTokens(output: 1000)]),
                AgentSpendDay(daysAgo: 0, agent: .codex, models: ["gpt-6-astra": AgentTokens(input: 50_000, output: 10)])]
    let summary = AgentSpendSummary.make(days: days, period: .today, agents: [.claude, .codex], price: testPrice)
    #expect(summary.hasUnpriced && !summary.barsAreDollars)
    #expect(summary.dollars == 1)
    #expect(summary.models.map(\.name) == ["GPT-6 Astra", "Opus 5"])
}

@Test func aSwitchedOffAgentLeavesEveryTotal() {
    let days = [AgentSpendDay(daysAgo: 0, agent: .codex, models: ["gpt-6-astra": AgentTokens(output: 10)])]
    let summary = AgentSpendSummary.make(days: days, period: .today, agents: [.claude], price: testPrice)
    #expect(summary.tokens == 0 && summary.models.isEmpty && !summary.hasUnpriced)
}
