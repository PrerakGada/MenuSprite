import AppKit
import Foundation
import Testing
@testable import SystemMonitoring

@Test func batteryIconClaimsMoreWidthThanASquareSymbol() {
    #expect(ReadoutIcon.symbol("cpu").width(forHeight: 14) == 14)
    #expect(ReadoutIcon.battery(.init(percent: 50)).width(forHeight: 14) == 29)
}

@MainActor @Test func batteryLayoutLeavesRoomForTheGlyphAndTheValue() {
    var config = SpriteConfiguration.battery
    config.showIcon = true
    let columns = [ReadoutColumn(label: "Battery", value: "98%")]
    let wide = StackedReadout.layout(columns: columns, config: config, height: 24, icon: .battery(.init(percent: 98)))
    let narrow = StackedReadout.layout(columns: columns, config: config, height: 24, icon: .symbol("battery.100percent"))
    #expect(wide.iconRect.width == BatteryGlyph.width(forHeight: 14))
    #expect(wide.size.width > narrow.size.width)
    // The value never overlaps the glyph.
    #expect(wide.columns[0].value.minX >= wide.iconRect.maxX)
}

@Test func glyphSummaryNeverInventsAMissingLevel() {
    #expect(BatteryGlyph().summary == "Battery level unavailable, not charging")
    #expect(BatteryGlyph(percent: 55, charging: true, ceiling: 55).summary == "Battery 55%, charging, limited to 55%")
}

@MainActor @Test func onlyAReadingDrivenAlertForcesAColoredMenuBarImage() {
    let columns = [ReadoutColumn(label: "Battery", value: "8%")]
    var config = SpriteConfiguration.battery
    config.colorHex = "auto"; config.iconColorHex = "text"
    let calm = StackedReadout.image(columns: columns, config: config, height: 24, icon: .battery(.init(percent: 80)))
    let low = StackedReadout.image(columns: columns, config: config, height: 24, icon: .battery(.init(percent: 8, alertHex: "FF6B5E")))
    #expect(calm.isTemplate)
    #expect(!low.isTemplate)
}

@Test func drawingAnUnreadBatteryProducesAShellRatherThanAGuess() {
    let size = NSSize(width: 30, height: 14)
    func pixels(_ glyph: BatteryGlyph) -> Int {
        let image = NSImage(size: size, flipped: false) { rect in glyph.draw(in: rect, ink: .black); return true }
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) else { return -1 }
        var opaque = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { opaque += 1 }
        }
        return opaque
    }
    let empty = pixels(BatteryGlyph())
    let half = pixels(BatteryGlyph(percent: 50))
    let full = pixels(BatteryGlyph(percent: 100))
    #expect(empty > 0)          // the shell is always drawn
    #expect(half > empty)       // an unread battery is never drawn as a level
    #expect(full > half)
}

@Test func batteryItemIsRecognizedFromItsReadingsAlone() {
    #expect(SpriteConfiguration.battery.isBatteryItem)
    #expect(SpriteConfiguration(metricIDs: ["battery.charge", "battery.remaining"]).isBatteryItem)
    #expect(!SpriteConfiguration(metricIDs: ["battery.charge", "cpu.usage"]).isBatteryItem)
    #expect(!SpriteConfiguration(metricIDs: ["sensor.PSTR"]).isBatteryItem)
}

@Test func theSeededBatteryItemShowsItsGlyphAndAskedForOneReading() {
    let item = SpriteConfiguration.battery
    #expect(item.showIcon && !item.showLabels)
    #expect(item.metricIDs == ["battery.charge"])
    #expect(SpriteConfiguration.initial.filter(\.isBatteryItem).count == 1)
}

@Test func batteryPercentDefaultsInsideAndOlderSettingsDecodeToIt() throws {
    #expect(SpriteConfiguration.battery.batteryPercentPlacement == .inside)
    #expect(SpriteConfiguration.battery.drawsChargeInsideBattery)
    // A configuration saved before the setting existed has no key at all.
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SpriteConfiguration.battery)) as! [String: Any]
    json.removeValue(forKey: "batteryPercentPosition")
    let decoded = try JSONDecoder().decode(SpriteConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.batteryPercentPlacement == .inside)
    var hidden = SpriteConfiguration.battery
    hidden.showIcon = false
    #expect(!hidden.drawsChargeInsideBattery)   // no glyph, so the charge stays as text
    #expect(!SpriteConfiguration(metricIDs: ["cpu.usage"]).drawsChargeInsideBattery)
    #expect(!SpriteConfiguration(metricIDs: ["cpu.usage"]).iconTrailing)
}

@MainActor @Test func aBatteryWithItsChargeInsideIsJustTheGlyph() {
    let config = SpriteConfiguration.battery
    let glyph = BatteryGlyph(percent: 55, percentInside: true)
    let layout = StackedReadout.layout(columns: [], config: config, height: 24, icon: .battery(glyph))
    #expect(layout.iconRect.height == 15)
    #expect(layout.size.width == layout.iconRect.maxX + StackedReadout.horizontalPadding)
}

@MainActor @Test func percentOnTheLeftPutsTheGlyphAfterTheValue() {
    var config = SpriteConfiguration.battery
    let columns = [ReadoutColumn(label: "Battery", value: "98%")]
    let icon = ReadoutIcon.battery(.init(percent: 98))
    config.batteryPercentPlacement = .right
    let right = StackedReadout.layout(columns: columns, config: config, height: 24, icon: icon)
    config.batteryPercentPlacement = .left
    let left = StackedReadout.layout(columns: columns, config: config, height: 24, icon: icon)
    #expect(left.size == right.size)
    #expect(left.columns[0].value.minX >= StackedReadout.horizontalPadding)
    #expect(left.iconRect.minX >= left.columns[0].value.maxX)
    #expect(left.iconRect.maxX == left.size.width - StackedReadout.horizontalPadding)
}

@Test func theNumberInsideIsWholeOverADimmedFill() {
    let size = NSSize(width: 31, height: 15)
    func pixels(_ glyph: BatteryGlyph) -> Int {
        let image = NSImage(size: size, flipped: false) { rect in glyph.draw(in: rect, ink: .black); return true }
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) else { return -1 }
        var opaque = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { opaque += 1 }
        }
        return opaque
    }
    // Full: the fill is dimmed behind the digits. Empty: the digits are solid ink in the shell.
    #expect(pixels(BatteryGlyph(percent: 100, percentInside: true)) < pixels(BatteryGlyph(percent: 100)))
    #expect(pixels(BatteryGlyph(percent: 0, percentInside: true)) > pixels(BatteryGlyph(percent: 0)))
    // Nothing crosses the digits: an active ceiling draws no mark while the number is inside.
    #expect(pixels(BatteryGlyph(percent: 71, ceiling: 55, percentInside: true)) == pixels(BatteryGlyph(percent: 71, percentInside: true)))
    #expect(pixels(BatteryGlyph(percent: 71, ceiling: 55)) != pixels(BatteryGlyph(percent: 71)))
    // An unread level draws no number rather than a guess.
    #expect(pixels(BatteryGlyph(percentInside: true)) == pixels(BatteryGlyph()))
}

@Test func batteryActivityFollowsTheCableThenTheMeasuredCurrent() {
    #expect(BatteryActivity(state: "Charging", amps: 2.1) == .charging)
    #expect(BatteryActivity(state: "AC · not charging", amps: 0.01) == .holding)   // a limit held by macOS
    #expect(BatteryActivity(state: "AC · not charging", amps: -1.2) == .draining)  // drain to the limit, cable in
    #expect(BatteryActivity(state: "On AC power", amps: 0.4) == .charging)
    #expect(BatteryActivity(state: "On battery", amps: -1.5) == .onBattery)
    #expect(BatteryActivity(state: nil, amps: 1) == nil)                           // unread is never guessed
    #expect(BatteryActivity.onBattery.capHex == nil)
    #expect(Set(BatteryActivity.allCases.compactMap(\.capHex)).count == 3)
}

@MainActor @Test func aColoredCapMakesTheItemColoredButRunningOnBatteryStaysTemplate() {
    let config = SpriteConfiguration.battery
    func template(_ activity: BatteryActivity?) -> Bool {
        StackedReadout.image(columns: [], config: config, height: 24,
                             icon: .battery(.init(percent: 60, percentInside: true, activity: activity))).isTemplate
    }
    #expect(!template(.holding) && !template(.charging) && !template(.draining))
    #expect(template(.onBattery) && template(nil))
    #expect(BatteryGlyph(percent: 55, activity: .holding).summary == "Battery 55%, holding, cable connected")
}

@MainActor @Test func lowPowerModeColorsTheFillAndIsNamed() {
    let config = SpriteConfiguration.battery
    let image = StackedReadout.image(columns: [], config: config, height: 24,
                                     icon: .battery(.init(percent: 60, percentInside: true, activity: .onBattery, lowPower: true)))
    #expect(!image.isTemplate)   // yellow cannot follow the menu bar's own tint
    #expect(BatteryGlyph(percent: 60, activity: .onBattery, lowPower: true).summary == "Battery 60%, running on battery, Low Power Mode")
}
