import AppKit
import Foundation
import Testing
@testable import SystemMonitoring

private func values(_ numbers: [String: Double], texts: [String: String] = [:]) -> DesignValues {
    DesignValues(
        formatted: { variable in
            guard let id = variable.readingID else { return "" }
            if let text = texts[id] { return text }
            return numbers[id].map { String(Int($0)) } ?? "—"
        },
        number: { $0.readingID.flatMap { numbers[$0] } },
        text: { $0.readingID.flatMap { texts[$0] } })
}

// MARK: Wi-Fi

@Test func signalFillsLinearlyBetweenMinus90AndMinus30() {
    #expect(WiFiSignal.percent(rssi: -95) == 0)
    #expect(WiFiSignal.percent(rssi: -90) == 0)
    #expect(WiFiSignal.percent(rssi: -60) == 50)
    #expect(WiFiSignal.percent(rssi: -30) == 100)
    #expect(WiFiSignal.percent(rssi: -20) == 100)
}

@Test func signalQualityUsesTheUsualDataThresholds() {
    #expect(WiFiSignal.quality(rssi: -26) == "Excellent")
    #expect(WiFiSignal.quality(rssi: -55) == "Excellent")
    #expect(WiFiSignal.quality(rssi: -56) == "Good")
    #expect(WiFiSignal.quality(rssi: -70) == "Fair")
    #expect(WiFiSignal.quality(rssi: -80) == "Weak")
}

@Test func standardsAndSecurityReadAsPeopleSayThem() {
    #expect(WiFiSignal.standard(phy: 4, band: .ghz2) == "Wi-Fi 4")
    #expect(WiFiSignal.standard(phy: 6, band: .ghz5) == "Wi-Fi 6")
    #expect(WiFiSignal.standard(phy: 6, band: .ghz6) == "Wi-Fi 6E")
    #expect(WiFiSignal.standard(phy: 7, band: .ghz6) == "Wi-Fi 7")
    #expect(WiFiSignal.standard(phy: 0, band: nil) == nil)
    #expect(WiFiSignal.security(4) == "WPA2 Personal")
    #expect(WiFiSignal.security(11) == "WPA3 Personal")
    #expect(WiFiSignal.security(0) == "Open")
    #expect(WiFiBand(coreWLAN: 3) == .ghz6)
    #expect(WiFiSignal.width(3) == 80)
}

@Test func scanKeepsTheStrongestRadioPerNameAndListsKnownNetworksFirst() {
    let merged = WiFiNetwork.merged([
        WiFiNetwork(name: "Cafe", rssi: -80, band: .ghz2, secure: false, known: false),
        WiFiNetwork(name: "Home", rssi: -70, band: .ghz2, secure: true, known: true),
        WiFiNetwork(name: "Home", rssi: -50, band: .ghz5, secure: true, known: true),
        WiFiNetwork(name: "Neighbour", rssi: -40, band: .ghz5, secure: true, known: false),
        WiFiNetwork(name: "", rssi: -30, band: .ghz5, secure: true, known: false)
    ])
    #expect(merged.map(\.name) == ["Home", "Neighbour", "Cafe"])
    #expect(merged.first?.band == .ghz5)
}

@Test func wifiReadingsSayWhyTheyAreMissing() {
    let none = ConnectivityReadings.wifi(nil)
    #expect(none.keys.sorted() == MonitoringCatalog.wifiIDs.sorted())
    #expect(none.values.allSatisfy { !$0.available })

    let off = ConnectivityReadings.wifi(WiFiSnapshot(powered: false))
    #expect(off["wifi.state"]?.text == "Off")
    #expect(off["wifi.signal"]?.issue == "Wi-Fi is off")
    #expect(off.keys.sorted() == MonitoringCatalog.wifiIDs.sorted())

    let idle = ConnectivityReadings.wifi(WiFiSnapshot(powered: true))
    #expect(idle["wifi.state"]?.text == "Not connected")
    #expect(idle["wifi.rssi"]?.issue == "Not connected to a network")
}

@Test func connectedWiFiWithoutLocationStillReportsTheSignal() {
    let snapshot = WiFiSnapshot(powered: true, associated: true, network: nil, rssi: -48, noise: -90, linkRate: 866,
                                channel: 36, band: .ghz5, channelWidth: 80, standard: "Wi-Fi 6", security: "WPA3 Personal",
                                address: "192.168.1.20", router: "192.168.1.1")
    let readings = ConnectivityReadings.wifi(snapshot)
    #expect(readings["wifi.state"]?.text == "Connected")
    #expect(readings["wifi.signal"]?.number == 70)
    #expect(readings["wifi.rssi"]?.number == -48)
    #expect(readings["wifi.quality"]?.text == "Excellent")
    #expect(readings["wifi.rate"]?.number == 866)
    #expect(readings["wifi.band"]?.text == "5 GHz")
    #expect(readings["wifi.network"]?.available == false)
    #expect(readings["wifi.network"]?.issue?.contains("Location") == true)
    #expect(readings.keys.sorted() == MonitoringCatalog.wifiIDs.sorted())
}

@Test func signalAndLinkRateFormatForTheMenuBar() {
    let rssi = MonitoringCatalog.base.first { $0.id == "wifi.rssi" }!
    let rate = MonitoringCatalog.base.first { $0.id == "wifi.rate" }!
    #expect(MetricFormat.string(Reading(-48), metric: rssi, compact: true) == "−48 dBm")
    #expect(MetricFormat.string(Reading(866), metric: rate, compact: true) == "866 Mb/s")
    var bare = SpriteConfiguration(); bare.showUnits = false
    #expect(MetricFormat.string(Reading(-48), metric: rssi, config: bare, compact: true) == "−48")
}

// MARK: Bluetooth

@Test func renamedAirPodsAreKnownByTheirProductID() {
    #expect(BluetoothDeviceKind.classify(name: "Dhvani’s buds", vendorApple: true, productID: 0x2027, majorClass: 4, minorClass: 6) == .airpodsPro)
    #expect(BluetoothDeviceKind.classify(name: "Studio", vendorApple: true, productID: 0x200A, majorClass: 4, minorClass: 6) == .airpodsMax)
    // A non-Apple device with a colliding product id is not taken for AirPods.
    #expect(BluetoothDeviceKind.classify(name: "WH-1000XM4", vendorApple: false, productID: 0x2027, majorClass: 4, minorClass: 6) == .headphones)
}

@Test func devicesFallBackToTheirNameThenTheirClass() {
    #expect(BluetoothDeviceKind.classify(name: "Mom's AirPods Pro", vendorApple: false, productID: nil, majorClass: 0, minorClass: 0) == .airpodsPro)
    #expect(BluetoothDeviceKind.classify(name: "Living Room", vendorApple: false, productID: nil, majorClass: 0x04, minorClass: 0x05) == .speaker)
    #expect(BluetoothDeviceKind.classify(name: "MX Master 2S", vendorApple: false, productID: nil, majorClass: 0x05, minorClass: 0x20) == .mouse)
    #expect(BluetoothDeviceKind.classify(name: "Magic Keyboard", vendorApple: false, productID: nil, majorClass: 0x05, minorClass: 0x10) == .keyboard)
    #expect(BluetoothDeviceKind.classify(name: "Magic Trackpad", vendorApple: false, productID: nil, majorClass: 0x05, minorClass: 0x20) == .trackpad)
    #expect(BluetoothDeviceKind.classify(name: "Prerak’s iPhone 17", vendorApple: false, productID: nil, majorClass: 0x02, minorClass: 0x03) == .phone)
    #expect(BluetoothDeviceKind.classify(name: "MX Master 3", vendorApple: false, productID: nil, majorClass: 0, minorClass: 0) == .mouse)
    #expect(BluetoothDeviceKind.classify(name: "dev", vendorApple: false, productID: nil, majorClass: 0, minorClass: 0) == .other)
    #expect(BluetoothDeviceKind.airpodsPro.isAudio && BluetoothDeviceKind.speaker.isAudio && !BluetoothDeviceKind.mouse.isAudio)
}

@Test func deviceSymbolsExistOnThisMac() {
    for kind in BluetoothDeviceKind.allCases { #expect(SpriteSymbols.exists(kind.symbol), "\(kind) → \(kind.symbol)") }
}

@Test func earbudsReportTheEmptierBudAndIgnoreUnreportedLevels() {
    #expect(BluetoothBattery(single: 90, left: 80, right: 60, chargingCase: 40).headline == 60)
    #expect(BluetoothBattery(single: 90).headline == 90)
    #expect(BluetoothBattery(left: 70).headline == 70)
    #expect(BluetoothBattery().headline == nil)
    #expect(BluetoothBattery.level(0) == nil)
    #expect(BluetoothBattery.level(101) == nil)
    #expect(BluetoothBattery.level(55) == 55)
}

@Test func bluetoothReadingsWaitForPermissionWithoutPretending() {
    for access in [BluetoothAccess.notDetermined, .denied] {
        let readings = ConnectivityReadings.bluetooth(BluetoothSnapshot(access: access))
        #expect(readings.keys.sorted() == MonitoringCatalog.bluetoothIDs.sorted())
        #expect(readings.values.allSatisfy { !$0.available })
    }
    let off = ConnectivityReadings.bluetooth(BluetoothSnapshot(access: .allowed, powered: false,
        devices: [BluetoothDevice(address: "a", name: "AirPods Pro", kind: .airpodsPro, connected: true, battery: .init(left: 50))]))
    #expect(off["bluetooth.state"]?.text == "Off")
    #expect(off["bluetooth.connected"]?.number == 0)
    #expect(off["bluetooth.audio"]?.issue == "Bluetooth is off")
}

@Test func connectedHeadphonesDriveTheAudioReadings() {
    let snapshot = BluetoothSnapshot(access: .allowed, powered: true, devices: [
        BluetoothDevice(address: "m", name: "MX Master 2S", kind: .mouse, connected: true, battery: .init(single: 12)),
        BluetoothDevice(address: "p", name: "Prerak’s iPhone 17", kind: .phone, connected: true),
        BluetoothDevice(address: "a", name: "AirPods Pro", kind: .airpodsPro, connected: true, battery: .init(left: 80, right: 64, chargingCase: 30)),
        BluetoothDevice(address: "w", name: "WH-1000XM4", kind: .headphones, connected: false)
    ])
    #expect(snapshot.devices.map(\.connected) == [true, true, true, false])
    let readings = ConnectivityReadings.bluetooth(snapshot)
    #expect(readings["bluetooth.state"]?.text == "On")
    #expect(readings["bluetooth.connected"]?.number == 3)
    #expect(readings["bluetooth.audio"]?.text == "AirPods Pro")
    #expect(readings["bluetooth.audioKind"]?.text == "AirPods Pro")
    #expect(readings["bluetooth.audioBattery"]?.number == 64)
    #expect(readings["bluetooth.batteryLeft"]?.number == 80)
    #expect(readings["bluetooth.batteryCase"]?.number == 30)
    #expect(readings["bluetooth.lowestBattery"]?.number == 12)
    #expect(readings["bluetooth.lowestBatteryDevice"]?.text == "MX Master 2S")
    #expect(readings.keys.sorted() == MonitoringCatalog.bluetoothIDs.sorted())
}

// MARK: Templates and drawing

@Test func connectivityTemplatesReadOnlyCatalogReadingsAndRulesHitRealNodes() {
    let ids = Set(MonitoringCatalog.base.map(\.id))
    let templates = SpriteTemplates.all.filter { $0.category == .wifi || $0.category == .bluetooth || $0.id == "network.wifi" }
    #expect(templates.count == 7)
    for template in templates {
        let config = template.make { id in MonitoringCatalog.base.first { $0.id == id } }
        let design = try! #require(config.design)
        #expect(Set(template.readingIDs).isSubset(of: ids), "\(template.id)")
        #expect(!template.readingIDs.isEmpty, "\(template.id)")
        // Pruning drops actions aimed at missing nodes; a template must lose nothing.
        var pruned = design; pruned.prune()
        #expect(pruned == design, "\(template.id)")
        #expect(config.templateID == template.id)
    }
}

@MainActor @Test func wifiBarsFollowTheSignalAndSwapWhenOff() throws {
    let template = try #require(SpriteTemplates.template("wifi.icon"))
    let design = try #require(template.make { id in MonitoringCatalog.base.first { $0.id == id } }.design)
    let strong = DesignRenderer.render(design, values: values(["wifi.signal": 90], texts: ["wifi.state": "Connected"]), height: 24)
    let weak = DesignRenderer.render(design, values: values(["wifi.signal": 10], texts: ["wifi.state": "Connected"]), height: 24)
    #expect(strong.signature != weak.signature)
    let overrides = SpriteRules.evaluate(design, values: values([:], texts: ["wifi.state": "Off"]))
    #expect(overrides.values.contains { $0.symbol == "wifi.slash" })
    let weakOverrides = SpriteRules.evaluate(design, values: values(["wifi.signal": 10], texts: ["wifi.state": "Connected"]))
    #expect(weakOverrides.values.contains { $0.color == "FF9F0A" })
}

@MainActor @Test func bluetoothDotShowsGreenForHeadphonesAndHidesWhenOff() throws {
    let template = try #require(SpriteTemplates.template("bluetooth.status"))
    let design = try #require(template.make { id in MonitoringCatalog.base.first { $0.id == id } }.design)
    let dot = try #require(design.root.flattened.first { $0.name == "Dot" })
    let listening = SpriteRules.evaluate(design, values: values(["bluetooth.connected": 1], texts: ["bluetooth.state": "On", "bluetooth.audio": "AirPods Pro"]))
    #expect(listening[dot.id]?.hidden == false && listening[dot.id]?.color == "30D158")
    let mouse = SpriteRules.evaluate(design, values: values(["bluetooth.connected": 1], texts: ["bluetooth.state": "On"]))
    #expect(mouse[dot.id]?.color == "0A84FF")
    let off = SpriteRules.evaluate(design, values: values(["bluetooth.connected": 0], texts: ["bluetooth.state": "Off", "bluetooth.audio": "AirPods Pro"]))
    #expect(off[dot.id]?.hidden == true)
    // The rune takes only its own width: narrower than a square SF Symbol slot.
    let output = DesignRenderer.render(design, values: values([:], texts: ["bluetooth.state": "On"]), height: 24)
    let rune = try #require(output.placed.first { $0.kind == .icon })
    #expect(rune.frame.width < rune.frame.height)
}

@MainActor @Test func headphonesTemplateBecomesTheDeviceWithItsBattery() throws {
    let template = try #require(SpriteTemplates.template("bluetooth.headphones"))
    let design = try #require(template.make { id in MonitoringCatalog.base.first { $0.id == id } }.design)
    let device = try #require(design.root.flattened.first { $0.name == "Device" })
    let battery = try #require(design.root.flattened.first { $0.name == "Battery" })
    let max = SpriteRules.evaluate(design, values: values(["bluetooth.audioBattery": 15], texts: ["bluetooth.audioKind": "AirPods Max", "bluetooth.state": "On"]))
    #expect(max[device.id]?.symbol == "airpodsmax")
    #expect(max[battery.id]?.color == "FF453A")
    let none = SpriteRules.evaluate(design, values: values([:], texts: ["bluetooth.state": "On"]))
    #expect(none[device.id]?.symbol == SpriteSymbols.bluetooth)
    #expect(none[battery.id]?.hidden == true)
}

@Test func networkWithWiFiKeepsTheNetworkReadoutAndAddsTheBars() throws {
    let template = try #require(SpriteTemplates.template("network.wifi"))
    #expect(template.readingIDs.contains("network.upload") && template.readingIDs.contains("network.download"))
    #expect(template.readingIDs.contains("wifi.signal"))
    let design = try #require(template.make { id in MonitoringCatalog.base.first { $0.id == id } }.design)
    #expect(design.root.children.first?.kind == .icon)
    #expect(design.root.children.first?.symbol == "wifi")
}

@Test func iconLevelCountsAsADisplayedReading() {
    let icon = DesignNode(kind: .icon, symbol: "wifi", variable: "signal")
    let design = SpriteDesign(root: .row([icon]), variables: [SpriteVariable(id: "signal", name: "Signal", source: .reading(metric: "wifi.signal"))])
    #expect(design.displayedReadingIDs == ["wifi.signal"])
}
