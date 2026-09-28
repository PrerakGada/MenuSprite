import AppKit
import Foundation
import Testing
@testable import IslandKit

// Accessory alerts (activity spec §5, and the accessory rows of §4.1).

private let start = Date(timeIntervalSince1970: 1_000_000)

private func reading(_ percent: Int?, name: String = "Magic Mouse", kind: AccessoryKind = .mouse, id: String = "hid:1",
                     at seconds: TimeInterval, address: String? = nil) -> AccessoryReading {
    AccessoryReading(id: id, address: address, name: name, kind: kind, level: AccessoryLevel(main: percent),
                     observedAt: start.addingTimeInterval(seconds))
}

/// Feeds one reading per step (nil = the device was missing) and counts warnings.
private func warnings(_ steps: [Int?], watch: inout AccessoryBatteryWatch, from offset: TimeInterval = 0) -> [Int] {
    var fired: [Int] = []
    for (index, step) in steps.enumerated() {
        let readings = step.map { [reading($0, at: offset + TimeInterval(index + 1))] } ?? []
        fired += watch.consume(readings).warnings.compactMap(\.level.warningLevel)
    }
    return fired
}

/// Notice text as the island measures it: 11-pt medium with monospaced digits.
private func measure(_ text: String) -> CGFloat {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    return ceil((text as NSString).size(withAttributes: [.font: font]).width)
}

// MARK: Symbols

@Test func namesDecideTheSymbolFirst() {
    #expect(AccessoryKind.named("Alex's AirPods Max")?.symbol == "airpodsmax")
    #expect(AccessoryKind.named("Sam's AirPods Pro")?.symbol == "airpodspro")
    #expect(AccessoryKind.named("AirPods")?.symbol == "airpods")
    #expect(AccessoryKind.named("Bose QC Headphones")?.symbol == "headphones")
    #expect(AccessoryKind.named("Jabra Headset")?.symbol == "headphones")
    #expect(AccessoryKind.named("Beats Studio Buds")?.symbol == "headphones")
    #expect(AccessoryKind.named("Magic Keyboard")?.symbol == "keyboard")
    #expect(AccessoryKind.named("Magic Mouse")?.symbol == "computermouse")
    #expect(AccessoryKind.named("Magic Trackpad")?.symbol == "rectangle.and.hand.point.up.left")
    #expect(AccessoryKind.named("Old Track Pad")?.symbol == "rectangle.and.hand.point.up.left")
    #expect(AccessoryKind.named("Kitchen") == nil)
}

@Test func hidUsageNamesMiceKeyboardsAndTrackpads() {
    #expect(AccessoryKind.hidUsage(page: 1, usage: 2) == .mouse)
    #expect(AccessoryKind.hidUsage(page: 1, usage: 6) == .keyboard)
    #expect(AccessoryKind.hidUsage(page: 7, usage: 0) == .keyboard)
    #expect(AccessoryKind.hidUsage(page: 13, usage: 5) == .trackpad)
    #expect(AccessoryKind.hidUsage(page: 12, usage: 1) == nil)
}

@Test func aRenamedDeviceTakesItsSymbolFromItsReportedType() {
    #expect(AccessoryKind.resolve(name: "Kitchen", reported: .reportedType("Loudspeaker")).symbol == "hifispeaker")
    #expect(AccessoryKind.resolve(name: "WH-1000XM4", reported: .reportedType("Headset")).symbol == "headphones")
    #expect(AccessoryKind.resolve(name: "MX Master 2S", reported: .reportedType("Mouse")).symbol == "computermouse")
    #expect(AccessoryKind.resolve(name: "Kitchen").symbol == "dot.radiowaves.left.and.right")
}

@Test func reportedTypesCoverTheClassOfDeviceFamilies() {
    let cases: [(String, AccessoryKind)] = [
        ("Headphones", .headphones), ("Hands-Free Device", .headphones), ("Microphone", .microphone),
        ("Loudspeaker", .speaker), ("Portable Audio", .speaker), ("HiFi Audio Device", .speaker),
        ("Car audio", .car), ("Video Display and Loudspeaker", .tv), ("Gaming/Toy", .gameController),
        ("Gamepad", .gameController), ("Joystick", .gameController), ("Remote Control", .remote),
        ("Digitizer Tablet", .trackpad), ("Combo Keyboard/Pointing Device", .mouse), ("Keyboard", .keyboard),
        ("Printer", .printer), ("Wrist Watch", .watch), ("Glasses", .glasses), ("Smartphone", .phone),
        ("Cellular", .phone), ("Laptop", .laptop), ("Desktop Workstation", .desktop),
    ]
    for (type, kind) in cases { #expect(AccessoryKind.reportedType(type) == kind, "\(type)") }
    #expect(AccessoryKind.reportedType("Uncategorized") == nil)
}

@Test func aNameThatStatesTheTypeOutranksTheReportedType() {
    #expect(AccessoryKind.resolve(name: "Alex's Magic Keyboard", reported: .trackpad, hint: .mouse) == .keyboard)
    #expect(AccessoryKind.resolve(name: "Studio Buds", reported: .speaker) == .headphones)
    #expect(AccessoryKind.resolve(name: "Desk", reported: nil, hint: .trackpad) == .trackpad)
}

@Test func everyAccessorySymbolExistsOnThisMacOS() {
    for kind in AccessoryKind.allCases {
        #expect(NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil) != nil, "\(kind.symbol)")
    }
}

// MARK: Low-battery episodes

@Test func theFirstReadingIsASilentBaselineEvenWhenLow() {
    var watch = AccessoryBatteryWatch(activatedAt: start)
    #expect(warnings([19, 18, nil], watch: &watch).isEmpty)
}

@Test func twentyFiveReArmsAndTwentyWarnsOnce() {
    var watch = AccessoryBatteryWatch(activatedAt: start)
    #expect(warnings([19, 25, 20, 21, 20, 19], watch: &watch) == [20])
}

@Test func thirtyThenTenWarnsOnce() {
    var watch = AccessoryBatteryWatch(activatedAt: start)
    #expect(warnings([30, 10, 10, nil, 9], watch: &watch) == [10])
}

@Test func noiseAboveTheLineNeverReArms() {
    var watch = AccessoryBatteryWatch(activatedAt: start)
    #expect(warnings([50, 20, 24, 20, 23, 18], watch: &watch) == [20])
}

@Test func anInvalidReadingIsNotARecharge() {
    var watch = AccessoryBatteryWatch(activatedAt: start)
    #expect(warnings([19, 101, 20], watch: &watch).isEmpty)
    var fresh = AccessoryBatteryWatch(activatedAt: start)
    #expect(warnings([101, 20, 18], watch: &fresh).isEmpty, "an invalid first reading is no baseline; 20 is")
}

@Test func anotherSourceForTheSameDeviceKeepsItsEpisode() {
    var watch = AccessoryBatteryWatch(activatedAt: start)
    _ = watch.consume([reading(30, id: "hid:1", at: 1)])
    #expect(watch.consume([reading(19, id: "hid:1", at: 2)]).warnings.count == 1)
    #expect(watch.consume([reading(18, id: "bt:aa", at: 3)]).warnings.isEmpty)
    #expect(watch.consume([reading(18, name: "  MAGIC MOUSE ", id: "bt:bb", at: 4)]).warnings.isEmpty)
}

@Test func readingsFromBeforeActivationOrAlreadyConsumedDoNotCount() {
    var watch = AccessoryBatteryWatch(activatedAt: start)
    _ = watch.consume([reading(10, at: -5)])
    _ = watch.consume([reading(40, at: 1)])
    #expect(watch.consume([reading(15, at: 1)]).warnings.isEmpty, "a cached value served again is not new")
    #expect(watch.consume([reading(15, at: 0.5)]).warnings.isEmpty, "an older value is not new")
    #expect(watch.consume([reading(15, at: 2)]).warnings.count == 1)
}

@Test func aFreshRecoveryIsReportedSoAQueuedWarningCanBeWithdrawn() {
    var watch = AccessoryBatteryWatch(activatedAt: start)
    _ = watch.consume([reading(40, at: 1)])
    _ = watch.consume([reading(20, at: 2)])
    let outcome = watch.consume([reading(26, at: 3)])
    #expect(outcome.recovered == [AccessoryIdentity(kind: .mouse, name: "Magic Mouse")])
}

@Test func devicesCrossingTogetherAreOrderedByLevelThenKindThenName() {
    var watch = AccessoryBatteryWatch(activatedAt: start)
    let devices: [(String, AccessoryKind)] = [("Zed Mouse", .mouse), ("Amy Mouse", .mouse), ("Keys", .keyboard), ("Pad", .trackpad)]
    _ = watch.consume(devices.map { reading(60, name: $0.0, kind: $0.1, id: $0.0, at: 1) })
    let crossed = watch.consume([reading(15, name: "Zed Mouse", kind: .mouse, id: "Zed Mouse", at: 2),
                                 reading(15, name: "Amy Mouse", kind: .mouse, id: "Amy Mouse", at: 2),
                                 reading(15, name: "Keys", kind: .keyboard, id: "Keys", at: 2),
                                 reading(12, name: "Pad", kind: .trackpad, id: "Pad", at: 2)]).warnings
    #expect(crossed.map(\.name) == ["Pad", "Keys", "Amy Mouse", "Zed Mouse"])
}

@Test func atMost128DevicesAreRememberedOldestFirstOut() {
    var watch = AccessoryBatteryWatch(activatedAt: start)
    for index in 0...128 { _ = watch.consume([reading(60, name: "Mouse \(index)", id: "\(index)", at: TimeInterval(index + 1))]) }
    #expect(watch.rememberedCount == 128)
    // "Mouse 0" was forgotten, so its next reading is a fresh, silent baseline.
    #expect(watch.consume([reading(10, name: "Mouse 0", id: "0", at: 500)]).warnings.isEmpty)
    #expect(watch.consume([reading(10, name: "Mouse 128", id: "128", at: 501)]).warnings.count == 1)
}

@Test func earbudsWarnOnTheLowerBudButNeverOnTheCaseAlone() {
    let caseLow = AccessoryLevel(left: 90, right: 88, caseLevel: 12)
    #expect(caseLow.warningLevel == 88)
    #expect(AccessoryLevel(caseLevel: 12).warningLevel == nil)
    #expect(AccessoryLevel(left: 15, right: 60, caseLevel: 40).warningLevel == 15)
    #expect(AccessoryLevel(main: 50, left: 10).warningLevel == 50)

    var watch = AccessoryBatteryWatch(activatedAt: start)
    func buds(_ level: AccessoryLevel, at seconds: TimeInterval) -> AccessoryReading {
        AccessoryReading(id: "28:2d", name: "Sam's AirPods Pro", kind: .airpodsPro, level: level, observedAt: start.addingTimeInterval(seconds))
    }
    _ = watch.consume([buds(AccessoryLevel(left: 90, right: 90, caseLevel: 50), at: 1)])
    #expect(watch.consume([buds(caseLow, at: 2)]).warnings.isEmpty)
    let warned = watch.consume([buds(AccessoryLevel(left: 15, right: 60, caseLevel: 40), at: 3)]).warnings
    #expect(warned.count == 1)
    let notice = warned.first.flatMap(AccessoryNoticeContent.lowBattery)
    #expect(notice?.title == "Low battery · 15%")
    #expect(notice?.label == "Low battery, 15%, Sam's AirPods Pro, left 15%, right 60%, case 40%")
}

// MARK: Connections

@Test func connectionBannersFollowTheBaselineAndDuplicateRules() {
    var connections = AccessoryConnections()
    func device(_ address: String, _ name: String = "Buds") -> AccessoryDevice { AccessoryDevice(address: address, name: name) }
    connections.baseline(.audio, ["a": device("aa:01")])
    #expect(connections.update(.audio, ["a": device("aa:01")]).connected.isEmpty, "the baseline never replays")
    #expect(connections.update(.audio, ["a": device("aa:01"), "b": device("aa:02")]).connected.map(\.address) == ["aa:02"])
    #expect(connections.update(.audio, ["a": device("aa:01"), "b": device("aa:02"), "c": device("aa:02")]).connected.isEmpty)
    #expect(connections.update(.audio, ["a": device("aa:01"), "b": device("aa:02"), "d": device("")]).connected.isEmpty,
            "an empty address never counts")
    #expect(connections.update(.audio, ["a": device("aa:01"), "b": device("aa:02"), "e": device("aa:03", " ")]).connected.isEmpty,
            "a device with no name gives no notice")
    let gone = connections.update(.audio, ["b": device("aa:02")])
    #expect(gone.disconnected == ["aa:01"])
    #expect(connections.update(.audio, ["a": device("aa:01"), "b": device("aa:02")]).connected.map(\.address) == ["aa:01"])
}

@Test func aDeviceSeenByTwoSourcesConnectsOnceAndLeavesWhenBothLetGo() {
    var connections = AccessoryConnections()
    connections.baseline(.audio, [:])
    connections.baseline(.hid, [:])
    let headset = AccessoryDevice(address: "02:00:00:00:00:02", name: "WH-1000XM4")
    #expect(connections.update(.audio, ["in": headset, "out": headset]).connected == [headset])
    #expect(connections.update(.hid, ["hid:9": headset]).connected.isEmpty)
    #expect(connections.update(.audio, [:]).disconnected.isEmpty)
    #expect(connections.update(.hid, [:]).disconnected == ["02:00:00:00:00:02"])
}

// MARK: Queue

private func connectedNotice(_ address: String, _ name: String = "Buds") -> AccessoryNoticeContent {
    .connected(AccessoryDevice(address: address, name: name), kind: .headphones)
}

@Test func theQueueHoldsEightAndDropsTheOldest() {
    var queue = AccessoryNoticeQueue()
    for index in 0..<10 { queue.enqueue(connectedNotice("aa:0\(index)"), at: start) }
    #expect(queue.count == 8)
    #expect(queue.next(at: start)?.address == "aa:02")
}

@Test func queuedNoticesExpireAfterThirtySeconds() {
    var queue = AccessoryNoticeQueue()
    queue.enqueue(connectedNotice("aa:01"), at: start)
    queue.enqueue(connectedNotice("aa:02"), at: start.addingTimeInterval(10))
    #expect(queue.next(at: start.addingTimeInterval(29))?.address == "aa:01")
    #expect(queue.next(at: start.addingTimeInterval(30))?.address == "aa:02")
    queue.removeNext()
    #expect(queue.next(at: start.addingTimeInterval(31)) == nil)
    #expect(AccessoryNoticeQueue.interval == 4.1)
}

@Test func aRecoveryWithdrawsTheWarningAndADisconnectDropsTheDevice() {
    var queue = AccessoryNoticeQueue()
    let mouse = AccessoryNoticeContent.lowBattery(reading(18, at: 1, address: "aa:05"))!
    queue.enqueue(mouse, at: start)
    queue.enqueue(connectedNotice("aa:06"), at: start)
    queue.enqueue(connectedNotice("aa:07"), at: start)
    queue.withdrawLowBattery(mouse.identity)
    #expect(queue.next(at: start)?.address == "aa:06")
    queue.drop(address: "aa:06")
    #expect(queue.next(at: start)?.address == "aa:07")
    queue.removeAll()
    #expect(queue.isEmpty)
}

// MARK: Notice text and sizing

@Test func accessoryNoticesUseTheirKindsSlotAndOpenSystem() {
    #expect(IslandNoticeKind.accessory.priority == 1)
    #expect(IslandNoticeKind.accessory.duration == 4)
    #expect(IslandNoticeKind.accessory.section == .system)
    let connected = connectedNotice("aa:01", "Alex's Magic Trackpad")
    #expect(connected.title == "Connected")
    #expect(connected.detail == "Alex's Magic Trackpad")
    #expect(connected.meter == nil)
    #expect(connected.label == "Connected, Alex's Magic Trackpad")
    let low = AccessoryNoticeContent.lowBattery(reading(15, at: 1))!
    #expect(low.detail.isEmpty)
    #expect(low.meter == 0.15)
    #expect(!low.title.contains("—"), "no em dash in copy")
}

@Test func commonNamesFitWholeAndLongNamesShortenInTheMiddle() {
    let width = AccessoryNoticeLayout.nameWidth
    #expect(width == 138)
    for name in ["Alex's Magic Trackpad", "Sam's AirPods Pro", "Alex's Magic Keyboard"] {
        #expect(AccessoryNoticeLayout.middleTruncated(name, width: width, measure: measure) == name)
    }
    let long = "Alex's Magic Keyboard with Touch ID and Numeric Keypad"
    let fitted = AccessoryNoticeLayout.middleTruncated(long, width: width, measure: measure)
    #expect(fitted != long)
    #expect(measure(fitted) <= width)
    #expect(fitted.hasPrefix("Alex") && fitted.hasSuffix("Keypad") && fitted.contains("…"))
    #expect(AccessoryNoticeLayout.middleTruncated(long, width: 0, measure: measure) == "…")
}

@Test func longNamesCapTheWingAt160AndStayInsideA640PointDisplay() {
    let long = String(repeating: "Very Long Accessory Name ", count: 6)
    let notice = connectedNotice("aa:01", long)
    let fitted = AccessoryNoticeLayout.middleTruncated(notice.detail, width: AccessoryNoticeLayout.nameWidth, measure: measure)
    let wing = IslandNoticeWings.text(titleWidth: measure(notice.title), detailWidth: measure(fitted),
                                      cameraGap: AccessoryNoticeLayout.cameraGap, maximum: notice.maxWing)
    #expect(wing <= 160)
    #expect(notice.label.hasSuffix(long), "VoiceOver keeps the full name")
    for bar in stride(from: CGFloat(16), through: 64, by: 8) {
        let small = IslandDisplayMetrics.make(frame: CGRect(x: 0, y: 0, width: 640, height: 480), auxiliaryLeft: nil,
                                              auxiliaryRight: nil, safeAreaTop: 0, barHeight: bar, scale: 2)
        #expect(IslandGeometry.strip(small, wing: wing).width <= 640 - 24)
    }
}

@Test func theLowBatteryTitleIsTextSizedBesideItsMeter() {
    let low = AccessoryNoticeContent.lowBattery(reading(20, at: 1))!
    let wing = IslandNoticeWings.text(titleWidth: measure(low.title), detailWidth: 0,
                                      cameraGap: AccessoryNoticeLayout.cameraGap, maximum: low.maxWing)
    #expect(wing < low.maxWing, "the title never truncates")
    #expect(wing >= 88)
}

// MARK: Sources

@Test func percentagesParseFromNumbersAndStrings() {
    #expect(AccessoryPercent.parse(87) == 87)
    #expect(AccessoryPercent.parse(NSNumber(value: 87.5)) == 88)
    #expect(AccessoryPercent.parse("87%") == 87)
    #expect(AccessoryPercent.parse(" 5 ") == 5)
    #expect(AccessoryPercent.parse(101) == nil)
    #expect(AccessoryPercent.parse("-3%") == nil)
    #expect(AccessoryPercent.parse("full") == nil)
    #expect(AccessoryPercent.parse(nil) == nil)
}

@Test func registryEntriesGiveHIDBatteries() {
    let magic: [String: Any] = ["BatteryPercent": 64, "Product": "Magic Trackpad", "SerialNumber": "F0T123",
                                "DeviceAddress": "02-00-00-00-00-06", "PrimaryUsagePage": 13, "PrimaryUsage": 5]
    let read = AccessoryRegistry.reading(magic, entryID: 7, observedAt: start)
    #expect(read?.level.main == 64)
    #expect(read?.kind == .trackpad)
    #expect(read?.id == "SerialNumber:F0T123")
    #expect(read?.address == "02:00:00:00:00:06")

    let fallback: [String: Any] = ["BatteryLevel": "40%", "ProductName": "Desk", "PrimaryUsagePage": 1, "PrimaryUsage": 2]
    let other = AccessoryRegistry.reading(fallback, entryID: 9, observedAt: start)
    #expect(other?.level.main == 40)
    #expect(other?.kind == .mouse)
    #expect(other?.id == "entry:9")

    #expect(AccessoryRegistry.reading(["BatteryPercent": 50, "Built-In": true], entryID: 1, observedAt: start) == nil)
    #expect(AccessoryRegistry.reading(["BatteryPercent": 120, "Product": "X"], entryID: 1, observedAt: start) == nil)
    #expect(AccessoryRegistry.reading(["Product": "No battery"], entryID: 1, observedAt: start) == nil)
    #expect(AccessoryRegistry.address(Data([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])) == "02:00:00:00:00:01")
}

@Test func theBluetoothReportGivesEarbudPartsAndPairedTypes() throws {
    let json = """
    {"SPBluetoothDataType":[{"controller_properties":{"controller_state":"attrib_on"},
      "device_connected":[
        {"Sam's AirPods Pro":{"device_address":"02:00:00:00:00:01","device_batteryLevelLeft":"87%",
          "device_batteryLevelRight":"88%","device_batteryLevelCase":"40%","device_minorType":"Headphones"}},
        {"Alex’s iPhone":{"device_address":"02:00:00:00:00:03"}},
        {"Speaker":{"device_address":"02:00:00:00:00:04","device_batteryLevelMain":"55%","device_minorType":"Loudspeaker"}}],
      "device_not_connected":[
        {"MX Master 2S":{"device_address":"02:00:00:00:00:05","device_minorType":"Mouse"}},
        {"WH-1000XM4":{"device_address":"02:00:00:00:00:02","device_minorType":"Headset"}}]}]}
    """
    let result = try #require(AccessoryBluetoothReport.parse(Data(json.utf8), observedAt: start))
    #expect(result.readings.count == 2)
    let buds = try #require(result.readings.first { $0.name == "Sam's AirPods Pro" })
    #expect(buds.kind == .airpodsPro)
    #expect(buds.address == "02:00:00:00:00:01")
    #expect(buds.level == AccessoryLevel(left: 87, right: 88, caseLevel: 40))
    #expect(buds.level.warningLevel == 87)
    #expect(result.readings.first { $0.name == "Speaker" }?.level.main == 55)
    #expect(result.types["02:00:00:00:00:05"] == .mouse)
    #expect(result.types["02:00:00:00:00:02"] == .headphones)
    #expect(result.types["02:00:00:00:00:04"] == .speaker)
    #expect(AccessoryBluetoothReport.parse(Data("not json".utf8), observedAt: start) == nil)
}

@Test func mergingKeepsOneFreshestReadingPerDevice() {
    let hid = reading(50, id: "SerialNumber:1", at: 60)
    let cachedBluetooth = reading(60, id: "aa:bb", at: 10)
    let other = reading(70, name: "Magic Keyboard", kind: .keyboard, id: "SerialNumber:2", at: 60)
    let merged = AccessoryReading.merge([[hid, other], [cachedBluetooth]])
    #expect(merged == [hid, other])
    let newer = reading(40, id: "SerialNumber:1", at: 120)
    #expect(AccessoryReading.merge([[hid], [newer]]) == [newer])
}

@Test func bluetoothAddressesNormaliseAcrossSources() {
    #expect(AccessoryAddress.fromAudioUID("02-00-00-00-00-01:output") == "02:00:00:00:00:01")
    #expect(AccessoryAddress.normalize("02:00:00:00:00:01") == "02:00:00:00:00:01")
    #expect(AccessoryAddress.fromAudioUID("BuiltInSpeakerDevice") == nil)
    #expect(AccessoryAddress.normalize("28:2D:7F:C4:53") == nil)
}
