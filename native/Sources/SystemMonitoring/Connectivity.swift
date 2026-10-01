import Foundation

/// The Wi-Fi link and Bluetooth accessories, as plain values: what `ConnectivityReader` reads from
/// CoreWLAN and IOBluetooth, what the sampler turns into `wifi.` and `bluetooth.` readings, and what
/// the two boards draw. Everything here is pure, so the mapping is tested without a radio.
/// Spec: `docs/wifi-bluetooth.md`.

// MARK: - Wi-Fi

public struct WiFiSnapshot: Sendable, Equatable {
    public var interface: String
    public var powered: Bool
    /// Associated with a network. The name can still be missing: macOS gives it only with Location access.
    public var associated: Bool
    public var network: String?
    public var rssi: Int?
    public var noise: Int?
    /// The negotiated link rate in Mb/s, not traffic.
    public var linkRate: Double?
    public var channel: Int?
    public var band: WiFiBand?
    public var channelWidth: Int?
    public var standard: String?
    public var security: String?
    public var address: String?
    public var router: String?

    public init(interface: String = "en0", powered: Bool = false, associated: Bool = false, network: String? = nil,
                rssi: Int? = nil, noise: Int? = nil, linkRate: Double? = nil, channel: Int? = nil, band: WiFiBand? = nil,
                channelWidth: Int? = nil, standard: String? = nil, security: String? = nil, address: String? = nil, router: String? = nil) {
        self.interface = interface; self.powered = powered; self.associated = associated; self.network = network
        self.rssi = rssi; self.noise = noise; self.linkRate = linkRate; self.channel = channel; self.band = band
        self.channelWidth = channelWidth; self.standard = standard; self.security = security; self.address = address; self.router = router
    }

    public enum State: String, Sendable { case off = "Off", disconnected = "Not connected", connected = "Connected" }
    public var state: State { !powered ? .off : associated ? .connected : .disconnected }
}

public enum WiFiBand: String, Sendable, Equatable {
    case ghz2 = "2.4 GHz", ghz5 = "5 GHz", ghz6 = "6 GHz"
    /// CoreWLAN's `CWChannelBand` raw value.
    public init?(coreWLAN raw: Int) {
        switch raw { case 1: self = .ghz2; case 2: self = .ghz5; case 3: self = .ghz6; default: return nil }
    }
}

public enum WiFiSignal {
    /// RSSI as a 0–100 fill: −90 dBm and below is empty, −30 dBm and above is full. Linear in dBm, the
    /// way macOS's own bars and most scanners scale it.
    public static func percent(rssi: Int) -> Double {
        min(100, max(0, (Double(rssi) + 90) / 60 * 100))
    }
    /// The word a person would use: the usual thresholds for data (−55 / −67 / −75 dBm).
    public static func quality(rssi: Int) -> String {
        switch rssi {
        case (-55)...: "Excellent"
        case (-67)...: "Good"
        case (-75)...: "Fair"
        default: "Weak"
        }
    }
    /// CoreWLAN's `CWPHYMode` raw value as the generation people know.
    public static func standard(phy: Int, band: WiFiBand?) -> String? {
        switch phy {
        case 1: "802.11a"
        case 2: "802.11b"
        case 3: "802.11g"
        case 4: "Wi-Fi 4"
        case 5: "Wi-Fi 5"
        case 6: band == .ghz6 ? "Wi-Fi 6E" : "Wi-Fi 6"
        case 7: "Wi-Fi 7"
        default: nil
        }
    }
    /// CoreWLAN's `CWSecurity` raw value.
    public static func security(_ raw: Int) -> String? {
        switch raw {
        case 0: "Open"
        case 1: "WEP"
        case 2, 3: "WPA Personal"
        case 4, 5: "WPA2 Personal"
        case 6: "Dynamic WEP"
        case 7, 8: "WPA Enterprise"
        case 9, 10: "WPA2 Enterprise"
        case 11: "WPA3 Personal"
        case 12: "WPA3 Enterprise"
        case 13: "WPA2/WPA3 Personal"
        case 14, 15: "Enhanced Open"
        default: nil
        }
    }
    /// CoreWLAN's `CWChannelWidth` raw value in MHz.
    public static func width(_ raw: Int) -> Int? {
        switch raw { case 1: 20; case 2: 40; case 3: 80; case 4: 160; case 5: 320; default: nil }
    }
}

/// A network a scan found, for the board's list.
public struct WiFiNetwork: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var rssi: Int
    public var band: WiFiBand?
    public var secure: Bool
    /// Saved in this Mac's preferred networks, so joining needs no password.
    public var known: Bool
    public init(name: String, rssi: Int, band: WiFiBand?, secure: Bool, known: Bool) {
        self.name = name; self.rssi = rssi; self.band = band; self.secure = secure; self.known = known
    }
    /// One row per name: the strongest access point stands for it, and a stronger 5 or 6 GHz radio wins a tie.
    public static func merged(_ found: [WiFiNetwork]) -> [WiFiNetwork] {
        var best: [String: WiFiNetwork] = [:]
        for network in found where !network.name.isEmpty {
            if let held = best[network.name], held.rssi >= network.rssi { continue }
            best[network.name] = network
        }
        return best.values.sorted { ($0.known ? 1 : 0, $0.rssi) > ($1.known ? 1 : 0, $1.rssi) }
    }
}

// MARK: - Bluetooth

public enum BluetoothAccess: String, Sendable, Equatable {
    case allowed, notDetermined, denied
}

public enum BluetoothDeviceKind: String, Sendable, Equatable, CaseIterable {
    case airpodsPro, airpodsMax, airpods, beats, headphones, speaker, mouse, keyboard, trackpad, gamepad, phone, tablet, computer, watch, other

    /// The `bluetooth.audioKind` text, which sprite rules compare against.
    public var title: String {
        switch self {
        case .airpodsPro: "AirPods Pro"; case .airpodsMax: "AirPods Max"; case .airpods: "AirPods"; case .beats: "Beats"
        case .headphones: "Headphones"; case .speaker: "Speaker"; case .mouse: "Mouse"; case .keyboard: "Keyboard"
        case .trackpad: "Trackpad"; case .gamepad: "Game controller"; case .phone: "Phone"; case .tablet: "Tablet"
        case .computer: "Computer"; case .watch: "Watch"; case .other: "Device"
        }
    }
    public var symbol: String {
        switch self {
        case .airpodsPro: "airpodspro"; case .airpodsMax: "airpodsmax"; case .airpods: "airpods"; case .beats: "beats.headphones"
        case .headphones: "headphones"; case .speaker: "hifispeaker"; case .mouse: "computermouse"; case .keyboard: "keyboard"
        case .trackpad: "rectangle.and.hand.point.up.left"; case .gamepad: "gamecontroller"; case .phone: "iphone"
        case .tablet: "ipad"; case .computer: "laptopcomputer"; case .watch: "applewatch"; case .other: SpriteSymbols.bluetooth
        }
    }
    /// Something you listen through: what the green dot and the headphone battery follow.
    public var isAudio: Bool { [.airpodsPro, .airpodsMax, .airpods, .beats, .headphones, .speaker].contains(self) }

    /// Apple's product ids for AirPods and Beats, so a pair renamed "Dhvani's buds" is still drawn as AirPods Pro.
    static let appleProducts: [Int: BluetoothDeviceKind] = [
        0x2002: .airpods, 0x200F: .airpods, 0x2013: .airpods, 0x2019: .airpods, 0x201B: .airpods,
        0x200E: .airpodsPro, 0x2014: .airpodsPro, 0x2024: .airpodsPro, 0x2027: .airpodsPro,
        0x200A: .airpodsMax, 0x201F: .airpodsMax,
        0x2003: .beats, 0x2005: .beats, 0x2006: .beats, 0x2009: .beats, 0x200B: .beats, 0x200C: .beats,
        0x200D: .beats, 0x2010: .beats, 0x2011: .beats, 0x2012: .beats, 0x2016: .beats, 0x2017: .beats
    ]

    /// Product id first (it survives renaming), then the name, then the Bluetooth class of device.
    public static func classify(name: String, vendorApple: Bool, productID: Int?, majorClass: Int, minorClass: Int) -> Self {
        if vendorApple, let productID, let kind = appleProducts[productID] { return kind }
        let lower = name.lowercased()
        if lower.contains("airpods max") { return .airpodsMax }
        if lower.contains("airpods pro") { return .airpodsPro }
        if lower.contains("airpods") { return .airpods }
        if lower.contains("beats") || lower.contains("powerbeats") { return .beats }
        if lower.contains("trackpad") { return .trackpad }
        switch majorClass {
        case 0x04:
            // Audio/video: loudspeakers and portable or car audio are speakers; the rest are worn.
            return [0x05, 0x07, 0x08, 0x0A].contains(minorClass) ? .speaker : .headphones
        case 0x05:
            // Peripheral: the top two minor bits say keyboard and/or pointer, the low four a gamepad.
            let pointer = minorClass & 0x20 != 0, keys = minorClass & 0x10 != 0
            if keys { return .keyboard }
            if pointer { return lower.contains("trackpad") ? .trackpad : .mouse }
            if (minorClass & 0x0F) == 0x01 || (minorClass & 0x0F) == 0x02 { return .gamepad }
        case 0x02: return .phone
        case 0x01: return lower.contains("ipad") ? .tablet : .computer
        case 0x07: return .watch
        default: break
        }
        if lower.contains("mouse") || lower.contains("mx master") { return .mouse }
        if lower.contains("keyboard") { return .keyboard }
        if lower.contains("controller") || lower.contains("gamepad") { return .gamepad }
        if lower.contains("headphone") || lower.contains("wh-") || lower.contains("buds") { return .headphones }
        if lower.contains("speaker") || lower.contains("homepod") { return .speaker }
        if lower.contains("iphone") { return .phone }
        if lower.contains("ipad") { return .tablet }
        if lower.contains("macbook") || lower.contains("imac") || lower.contains("mac mini") { return .computer }
        if lower.contains("watch") { return .watch }
        return .other
    }
}

/// Battery levels an accessory reports, 0–100. Earbuds report each bud and the case; most else, one level.
public struct BluetoothBattery: Sendable, Equatable {
    public var single: Int?
    public var left: Int?
    public var right: Int?
    public var chargingCase: Int?
    public init(single: Int? = nil, left: Int? = nil, right: Int? = nil, chargingCase: Int? = nil) {
        self.single = single; self.left = left; self.right = right; self.chargingCase = chargingCase
    }
    /// What the accessory has left to give: the emptier bud (that is the one that stops first), else its one level.
    public var headline: Int? {
        let buds = [left, right].compactMap { $0 }
        return buds.min() ?? single
    }
    public var isEmpty: Bool { single == nil && left == nil && right == nil && chargingCase == nil }
    /// A reported level, or nil: IOBluetooth uses 0 for "not reported", and anything over 100 is not a level.
    public static func level(_ raw: Int?) -> Int? {
        guard let raw, raw > 0, raw <= 100 else { return nil }
        return raw
    }
}

public struct BluetoothDevice: Sendable, Equatable, Identifiable {
    public var id: String { address }
    public var address: String
    public var name: String
    public var kind: BluetoothDeviceKind
    public var connected: Bool
    public var battery: BluetoothBattery
    public init(address: String, name: String, kind: BluetoothDeviceKind, connected: Bool, battery: BluetoothBattery = .init()) {
        self.address = address; self.name = name; self.kind = kind; self.connected = connected; self.battery = battery
    }
}

public struct BluetoothSnapshot: Sendable, Equatable {
    public var access: BluetoothAccess
    public var powered: Bool
    /// Every paired device, connected ones first.
    public var devices: [BluetoothDevice]
    public init(access: BluetoothAccess, powered: Bool = false, devices: [BluetoothDevice] = []) {
        self.access = access; self.powered = powered
        self.devices = devices.sorted { ($0.connected ? 0 : 1, $0.name.lowercased()) < ($1.connected ? 0 : 1, $1.name.lowercased()) }
    }
    public var connected: [BluetoothDevice] { devices.filter(\.connected) }
    /// The headphones or speaker in use: the connected audio device, preferring one that reports a battery.
    public var audio: BluetoothDevice? {
        let audio = connected.filter(\.kind.isAudio)
        return audio.first { !$0.battery.isEmpty } ?? audio.first
    }
}

// MARK: - Readings

public enum ConnectivityReadings {
    public static func wifi(_ snapshot: WiFiSnapshot?, now: Date = Date()) -> [String: Reading] {
        guard let snapshot else {
            return Dictionary(uniqueKeysWithValues: MonitoringCatalog.wifiIDs.map { ($0, Reading(unavailable: "This Mac has no Wi-Fi interface", at: now)) })
        }
        var values: [String: Reading] = ["wifi.state": Reading(text: snapshot.state.rawValue, at: now)]
        let reason = snapshot.powered ? "Not connected to a network" : "Wi-Fi is off"
        func put(_ id: String, _ value: Double?) { values[id] = value.map { Reading($0, at: now) } ?? Reading(unavailable: reason, at: now) }
        func put(_ id: String, text: String?) { values[id] = text.map { Reading(text: $0, at: now) } ?? Reading(unavailable: reason, at: now) }
        guard snapshot.associated else {
            for id in MonitoringCatalog.wifiIDs where id != "wifi.state" { values[id] = Reading(unavailable: reason, at: now) }
            return values
        }
        put("wifi.signal", snapshot.rssi.map(WiFiSignal.percent))
        put("wifi.rssi", snapshot.rssi.map(Double.init))
        put("wifi.quality", text: snapshot.rssi.map(WiFiSignal.quality))
        put("wifi.noise", snapshot.noise.map(Double.init))
        put("wifi.rate", snapshot.linkRate)
        put("wifi.channel", snapshot.channel.map(Double.init))
        put("wifi.band", text: snapshot.band?.rawValue)
        put("wifi.standard", text: snapshot.standard)
        put("wifi.security", text: snapshot.security)
        put("wifi.address", text: snapshot.address)
        put("wifi.router", text: snapshot.router)
        values["wifi.network"] = snapshot.network.map { Reading(text: $0, at: now) }
            ?? Reading(unavailable: "macOS shows the network name only to apps with Location access: open the Wi-Fi board to allow it", at: now)
        return values
    }

    public static func bluetooth(_ snapshot: BluetoothSnapshot, now: Date = Date()) -> [String: Reading] {
        let ids = MonitoringCatalog.bluetoothIDs
        switch snapshot.access {
        case .notDetermined:
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, Reading(unavailable: "Bluetooth access not asked for yet: click the sprite to allow it", at: now)) })
        case .denied:
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, Reading(unavailable: "Bluetooth access is off for MenuSprite in System Settings › Privacy & Security", at: now)) })
        case .allowed: break
        }
        var values: [String: Reading] = ["bluetooth.state": Reading(text: snapshot.powered ? "On" : "Off", at: now)]
        let connected = snapshot.powered ? snapshot.connected : []
        values["bluetooth.connected"] = Reading(Double(connected.count), at: now)
        let none = snapshot.powered ? "Nothing connected" : "Bluetooth is off"
        values["bluetooth.devices"] = connected.isEmpty ? Reading(unavailable: none, at: now)
            : Reading(text: connected.map(\.name).joined(separator: ", "), at: now)

        let audio = snapshot.powered ? snapshot.audio : nil
        let noAudio = snapshot.powered ? "No headphones or speaker connected" : "Bluetooth is off"
        values["bluetooth.audio"] = audio.map { Reading(text: $0.name, at: now) } ?? Reading(unavailable: noAudio, at: now)
        values["bluetooth.audioKind"] = audio.map { Reading(text: $0.kind.title, at: now) } ?? Reading(unavailable: noAudio, at: now)
        func level(_ id: String, _ value: Int?, missing: String) {
            values[id] = value.map { Reading(Double($0), at: now) } ?? Reading(unavailable: audio == nil ? noAudio : missing, at: now)
        }
        level("bluetooth.audioBattery", audio?.battery.headline, missing: "\(audio?.name ?? "It") does not report a battery to macOS")
        level("bluetooth.batteryLeft", audio?.battery.left, missing: "No left earbud level (out of reach, or not earbuds)")
        level("bluetooth.batteryRight", audio?.battery.right, missing: "No right earbud level (out of reach, or not earbuds)")
        level("bluetooth.batteryCase", audio?.battery.chargingCase, missing: "The case reports only while a bud is in it and the lid is open")

        let reporting = connected.compactMap { device in device.battery.headline.map { (device, $0) } }
        if let lowest = reporting.min(by: { $0.1 < $1.1 }) {
            values["bluetooth.lowestBattery"] = Reading(Double(lowest.1), at: now)
            values["bluetooth.lowestBatteryDevice"] = Reading(text: lowest.0.name, at: now)
        } else {
            let reason = connected.isEmpty ? none : "No connected accessory reports a battery"
            values["bluetooth.lowestBattery"] = Reading(unavailable: reason, at: now)
            values["bluetooth.lowestBatteryDevice"] = Reading(unavailable: reason, at: now)
        }
        return values
    }
}
