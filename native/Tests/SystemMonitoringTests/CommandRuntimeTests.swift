import Foundation
import Testing
@testable import SystemMonitoring

// MARK: Back-off

@Test func backoffDoublesFromTheIntervalUpToTenMinutes() {
    #expect(CommandSource.delay(interval: 2, failures: 0) == 2)
    #expect(CommandSource.delay(interval: 2, failures: 1) == 4)
    #expect(CommandSource.delay(interval: 2, failures: 3) == 16)
    // Doubling stops after eight failures, and the wait never passes ten minutes.
    #expect(CommandSource.delay(interval: 2, failures: 20) == 512)
    #expect(CommandSource.delay(interval: 5, failures: 8) == 600)
    #expect(CommandSource.delay(interval: 60, failures: 4) == 600)
}

@Test func backoffNeverRetriesSoonerThanTheCommandWouldRun() {
    // A failing hourly or daily command is not retried every ten minutes.
    #expect(CommandSource.delay(interval: 3600, failures: 1) == 3600)
    #expect(CommandSource.delay(interval: 900, failures: 5) == 900)
    #expect(CommandSource.delay(interval: 86400, failures: 3) == 86400)
    #expect(CommandSource.delay(interval: 600, failures: 2) == 600)
}

// MARK: Shared runs

@Test func valuesReadingOneCommandShareARun() {
    let count = CommandSource(command: "gh pr list --json number,title", interval: 300, timeout: 20, output: .json, path: "0.number")
    var title = count; title.path = "0.title"
    var text = count; text.output = .text; text.path = ""
    var kept = count; kept.background = true
    #expect(count.execution == title.execution)
    #expect(count.execution == text.execution)
    #expect(count.execution == kept.execution)
    // Normalising happens first, so values the studio stored a little differently still share.
    var unclamped = count; unclamped.timeout = 900
    var clamped = count; clamped.timeout = 60
    #expect(unclamped.execution == clamped.execution)
    #expect(CommandSource(command: "x", interval: 1).execution == CommandSource(command: "x", interval: 2).execution)
}

@Test func differentSchedulesTimeoutsOrFoldersAreSeparateRuns() {
    let base = CommandSource(command: "date", interval: 60, timeout: 10, directory: "/tmp/a")
    var faster = base; faster.interval = 30
    var longer = base; longer.timeout = 20
    var elsewhere = base; elsewhere.directory = "/tmp/b"
    var other = base; other.command = "date -u"
    for variant in [faster, longer, elsewhere, other] { #expect(variant.execution != base.execution) }
    #expect(base.execution.source.command == "date")
    #expect(base.execution.source.directory == "/tmp/a")
}

// MARK: Limits

@Test func commandsAreKeptWholeUpToSixteenKilobytes() {
    let script = "python3 - <<'EOF'\n" + String(repeating: "print('x')\n", count: 450) + "EOF"
    #expect(script.count > 4000 && script.count < CommandSource.maximumCommandLength)
    #expect(CommandSource(command: script).normalized.command == script)
    let huge = String(repeating: "a", count: 20000)
    #expect(CommandSource(command: huge).normalized.command.count == CommandSource.maximumCommandLength)
}

@Test func everyReachesADayAndAValueStopsAtAMinute() {
    #expect(CommandSource(command: "x", interval: 86400).normalized.interval == 86400)
    #expect(CommandSource(command: "x", interval: 200_000).normalized.interval == 86400)
    #expect(CommandSource(command: "x", timeout: 300).normalized.timeout == 60)
    #expect(CommandSource(command: "x", timeout: .nan).normalized.timeout == 10)
}

// MARK: Reading output

@Test func oneOutputIsParsedOnceForEveryValue() {
    let reader = CommandOutputReader(#"{"project": "site", "state": "READY", "count": 3, "ok": true, "items": [{"name": "a"}]}"#)
    let source = CommandSource(command: "vercel", output: .json)
    func at(_ path: String) -> CommandValue { var copy = source; copy.path = path; return reader.value(for: copy) }
    #expect(at("project") == CommandValue(text: "site"))
    #expect(at("state").text == "READY")
    #expect(at("count") == CommandValue(number: 3))
    #expect(at("ok") == CommandValue(text: "true"))
    #expect(at("items.0.name").text == "a")
    #expect(at("missing").problem == "No “missing” in the JSON")
    #expect(reader.documentParses == 1)
}

@Test func textValuesKeepFiveHundredCharactersOfTheFirstLine() {
    let long = String(repeating: "word ", count: 120)
    let reader = CommandOutputReader("  \(long)\nsecond line\n")
    let value = reader.value(for: CommandSource(command: "x"))
    #expect(value.text?.count == CommandSource.longestText)
    #expect(value.text?.contains("second") == false)
    let json = CommandOutputReader(#"{"title": "\#(String(repeating: "t", count: 700))"}"#)
    #expect(json.value(for: CommandSource(command: "x", output: .json, path: "title")).text?.count == 500)
    #expect(CommandOutputReader("Free: 12,5 GB").value(for: CommandSource(command: "x", output: .number)).number == 12.5)
    #expect(CommandOutputReader("\n  \n").value(for: CommandSource(command: "x")).problem == "Printed nothing")
    #expect(CommandOutputReader("nope").value(for: CommandSource(command: "x", output: .number)).problem == "No number in the output")
    #expect(CommandOutputReader("nope").value(for: CommandSource(command: "x", output: .json, path: "a")).problem == "Output is not JSON")
}

// MARK: Clock times

private func calendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    return calendar
}
private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

@Test func aClockTimeNamesTheDayOnlyWhenItIsNotToday() {
    let now = date("2026-10-01T05:00:00Z")   // Thu 1 Oct, 10:30 in Kolkata
    let gb = Locale(identifier: "en_GB")
    #expect(ValueFormat.clockTime(date("2026-10-01T11:00:00Z"), now: now, calendar: calendar(), locale: gb) == "16:30")
    #expect(ValueFormat.clockTime(date("2026-10-03T11:00:00Z"), now: now, calendar: calendar(), locale: gb) == "Sat 16:30")
    #expect(ValueFormat.clockTime(date("2026-10-07T11:00:00Z"), now: now, calendar: calendar(), locale: gb) == "Wed 16:30")
    #expect(ValueFormat.clockTime(date("2026-10-08T11:00:00Z"), now: now, calendar: calendar(), locale: gb) == "8 Oct 16:30")
    #expect(ValueFormat.clockTime(date("2027-01-08T11:00:00Z"), now: now, calendar: calendar(), locale: gb) == "8 Jan 2027 16:30")
    // Past midnight in Kolkata is tomorrow, though it is still the same UTC day.
    #expect(ValueFormat.clockTime(date("2026-10-01T19:00:00Z"), now: now, calendar: calendar(), locale: gb) == "Fri 00:30")
}

@Test func aClockTimeFollowsTheLocale() {
    let now = date("2026-10-01T05:00:00Z")
    let us = Locale(identifier: "en_US")
    #expect(ValueFormat.clockTime(date("2026-10-01T11:00:00Z"), now: now, calendar: calendar(), locale: us) == "4:30\u{202F}PM"
        || ValueFormat.clockTime(date("2026-10-01T11:00:00Z"), now: now, calendar: calendar(), locale: us) == "4:30 PM")
    #expect(ValueFormat.clockTime(date("2026-10-08T11:00:00Z"), now: now, calendar: calendar(), locale: us).hasPrefix("Oct 8 "))
    #expect(ValueFormat.clockTime(date("2026-10-08T11:00:00Z"), now: now, calendar: calendar(), locale: Locale(identifier: "de_DE")) == "8. Okt. 16:30")
}

@Test func clockFormatSurvivesARoundTrip() throws {
    var format = ValueFormat(); format.clock = true
    let decoded = try JSONDecoder().decode(ValueFormat.self, from: JSONEncoder().encode(format))
    #expect(decoded.clock)
    #expect(try JSONDecoder().decode(ValueFormat.self, from: Data("{}".utf8)).clock == false)
}
