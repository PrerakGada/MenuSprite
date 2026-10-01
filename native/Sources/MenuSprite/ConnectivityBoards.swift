import AppKit
import CoreBluetooth
import CoreLocation
import SwiftUI
import SystemMonitoring

/// Which board a click opens for a Wi-Fi or Bluetooth sprite.
enum ConnectivityBoardKind { case wifi, bluetooth }

extension SpriteConfiguration {
    /// A sprite made of Bluetooth readings opens the Bluetooth board; one made of Wi-Fi readings (with or
    /// without the network rates) opens the Wi-Fi board. Readings a rule only compares count too: the
    /// Bluetooth sprite's face is an icon and a dot, with every reading behind a rule.
    var connectivityBoard: ConnectivityBoardKind? {
        let ids = metricIDs + (design?.ruleOnlyReadingIDs ?? [])
        guard !ids.isEmpty else { return nil }
        if ids.allSatisfy({ $0.hasPrefix("bluetooth.") }) { return .bluetooth }
        if ids.contains(where: { $0.hasPrefix("wifi.") }),
           ids.allSatisfy({ $0.hasPrefix("wifi.") || $0.hasPrefix("network.") }) { return .wifi }
        return nil
    }
    /// What the tooltip says a click opens.
    var boardHint: String {
        switch connectivityBoard {
        case .wifi: "click for Wi-Fi"
        case .bluetooth: "click for Bluetooth"
        case nil: opensAccountsBoard ? "click for AI accounts" : "click for readings"
        }
    }
}

/// The boards' live view of Wi-Fi and Bluetooth, read only while a board is open: every two seconds for
/// Wi-Fi, three for Bluetooth. Reads and changes run off the main thread (a scan or a connect blocks for
/// seconds); results come back here.
@MainActor
final class ConnectivityMonitor: NSObject, ObservableObject, CLLocationManagerDelegate, CBCentralManagerDelegate {
    @Published private(set) var wifi: WiFiSnapshot?
    @Published private(set) var bluetooth: BluetoothSnapshot?
    @Published private(set) var networks: [WiFiNetwork] = []
    @Published private(set) var scanning = false
    @Published private(set) var scanned = false
    /// Device addresses (or network names) with a change in flight.
    @Published private(set) var busy: Set<String> = []
    @Published var notice: String?
    @Published private(set) var location: CLAuthorizationStatus = .notDetermined

    private var kind: ConnectivityBoardKind = .wifi
    private var timer: Timer?
    private var locationManager: CLLocationManager?
    /// Held only while the Bluetooth permission prompt is up; creating it is what asks.
    private var central: CBCentralManager?

    func start(_ kind: ConnectivityBoardKind) {
        self.kind = kind
        if kind == .wifi {
            let manager = CLLocationManager()
            manager.delegate = self
            locationManager = manager
            location = manager.authorizationStatus
        }
        refresh()
        if kind == .wifi, locationAllowed { scan() }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: kind == .wifi ? 2 : 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 0.5
    }

    func stop() {
        timer?.invalidate(); timer = nil
        locationManager?.delegate = nil; locationManager = nil
    }

    func refresh() {
        switch kind {
        case .wifi:
            Task { let value = await Task.detached(priority: .utility) { ConnectivityReader.wifi() }.value; self.wifi = value }
        case .bluetooth:
            Task { let value = await Task.detached(priority: .utility) { ConnectivityReader.bluetooth() }.value; self.bluetooth = value }
        }
    }

    // MARK: Wi-Fi

    var locationAllowed: Bool { location == .authorizedAlways || location == .authorized }

    func setWiFiPower(_ on: Bool) {
        perform("wifi-power", failure: on ? "Could not turn Wi-Fi on" : "Could not turn Wi-Fi off") { try ConnectivityReader.setWiFiPower(on) }
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try ConnectivityReader.scan() } }.value
            scanning = false; scanned = true
            switch result {
            case .success(let found): networks = found
            case .failure(let error): notice = "Scan failed: \(error.localizedDescription)"
            }
        }
    }

    func join(_ name: String) {
        perform(name, failure: "Could not join “\(name)”") { try ConnectivityReader.join(name) }
    }

    func requestLocation() {
        if location == .notDetermined { locationManager?.requestWhenInUseAuthorization() }
        else { Self.openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            location = status
            refresh()
            if locationAllowed { scan() }
        }
    }

    // MARK: Bluetooth

    func requestBluetooth() {
        switch ConnectivityReader.bluetoothAccess {
        case .notDetermined: central = CBCentralManager(delegate: self, queue: .main)
        case .denied: Self.openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
        case .allowed: refresh()
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            // The answer is in; the manager was only there to ask.
            self.central?.delegate = nil; self.central = nil
            refresh()
        }
    }

    func setBluetoothPower(_ on: Bool) {
        perform("bluetooth-power", failure: on ? "Could not turn Bluetooth on" : "Could not turn Bluetooth off") { try ConnectivityReader.setBluetoothPower(on) }
    }

    func toggle(_ device: BluetoothDevice) {
        let connect = !device.connected
        perform(device.address, failure: connect ? "Could not connect \(device.name)" : "Could not disconnect \(device.name)") {
            try ConnectivityReader.setConnected(device.address, connect)
        }
    }

    // MARK: Shared

    private func perform(_ key: String, failure: String, _ work: @escaping @Sendable () throws -> Void) {
        guard !busy.contains(key) else { return }
        busy.insert(key); notice = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
            busy.remove(key)
            if case .failure(let error) = result { notice = "\(failure): \(error.localizedDescription)" }
            refresh()
            // Power changes and joins settle over a second or two; read again once they have.
            try? await Task.sleep(for: .seconds(1.5))
            refresh()
        }
    }

    static func openSettings(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Wi-Fi board

struct WiFiBoard: View {
    @ObservedObject var store: MonitoringStore
    let id: UUID
    let configure: () -> Void
    @StateObject private var monitor = ConnectivityMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Wi-Fi", systemImage: "wifi").font(.headline)
                Spacer()
                Toggle("Wi-Fi", isOn: Binding(get: { monitor.wifi?.powered ?? false }, set: { monitor.setWiFiPower($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .disabled(monitor.wifi == nil || monitor.busy.contains("wifi-power"))
                    .accessibilityIdentifier("wifi-power")
            }
            if let wifi = monitor.wifi {
                switch wifi.state {
                case .off: Text("Wi-Fi is off.").font(.system(size: 12)).foregroundStyle(.secondary)
                case .disconnected:
                    Text("Wi-Fi is on but not connected to a network.").font(.system(size: 12)).foregroundStyle(.secondary)
                case .connected: current(wifi)
                }
                if wifi.powered { Divider(); nearby(wifi) }
            } else {
                Text("Reading Wi-Fi…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let notice = monitor.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Wi-Fi Settings…") { ConnectivityMonitor.openSettings("x-apple.systempreferences:com.apple.wifi-settings-extension") }
                Spacer()
                Button("Configure…", action: configure)
            }.controlSize(.small)
        }
        .padding(16).frame(width: 360)
        .onAppear {
            monitor.start(.wifi)
            store.setSurfaceMetrics("wifi-board-\(id)", ["network.download", "network.upload"], interval: 2)
        }
        .onDisappear {
            monitor.stop()
            store.setSurfaceMetrics("wifi-board-\(id)", [])
        }
    }

    @ViewBuilder private func current(_ wifi: WiFiSnapshot) -> some View {
        let rssi = wifi.rssi ?? -100
        HStack(spacing: 12) {
            Image(systemName: "wifi", variableValue: WiFiSignal.percent(rssi: rssi) / 100)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(rssi < -75 ? Color.orange : Color.accentColor)
                .frame(width: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(wifi.network ?? "Network name hidden").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text("\(WiFiSignal.quality(rssi: rssi)) signal · \(rssi) dBm").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        if wifi.network == nil {
            HStack(alignment: .firstTextBaseline) {
                Text(monitor.location == .notDetermined
                     ? "macOS shows network names only to apps with Location access. MenuSprite never reads where you are."
                     : "Location access is off for MenuSprite, so macOS hides network names.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(monitor.location == .notDetermined ? "Allow…" : "Settings…") { monitor.requestLocation() }.controlSize(.small)
            }
        }
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            fact("Link rate", wifi.linkRate.map { "\(Int($0)) Mb/s" })
            fact("Band", [wifi.band?.rawValue, wifi.channel.map { "channel \($0)" }, wifi.channelWidth.map { "\($0) MHz" }]
                    .compactMap { $0 }.joined(separator: " · "))
            fact("Standard", wifi.standard)
            fact("Security", wifi.security)
            fact("Noise", wifi.noise.map { noise in "\(noise) dBm" + (wifi.rssi.map { " · \($0 - noise) dB above it" } ?? "") })
            fact("IP address", wifi.address)
            fact("Router", wifi.router)
        }
        HStack(spacing: 18) {
            traffic("↓", "network.download", color: Color(red: 0.19, green: 0.82, blue: 0.35))
            traffic("↑", "network.upload", color: Color(red: 1, green: 0.62, blue: 0.04))
            Spacer()
        }
    }

    @ViewBuilder private func fact(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit().textSelection(.enabled)
            }
        }
    }

    private func traffic(_ arrow: String, _ metric: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(arrow).font(.system(size: 13, weight: .bold)).foregroundStyle(color)
            Text(store.display(metric)).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }

    @ViewBuilder private func nearby(_ wifi: WiFiSnapshot) -> some View {
        HStack {
            Text("Networks").font(.system(size: 12, weight: .semibold))
            Spacer()
            if monitor.scanning { ProgressView().controlSize(.mini) }
            Button(monitor.scanned ? "Scan again" : "Scan") { monitor.scan() }
                .controlSize(.small).disabled(monitor.scanning || !monitor.locationAllowed)
        }
        if !monitor.locationAllowed {
            Text("The list needs Location access too: macOS hides every network's name without it.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if monitor.scanned && monitor.networks.isEmpty && !monitor.scanning {
            Text("No networks found.").font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(monitor.networks) { network in row(network, current: network.name == wifi.network) }
                }
            }
            .frame(maxHeight: 190)
        }
    }

    private func row(_ network: WiFiNetwork, current: Bool) -> some View {
        Button { if network.known && !current { monitor.join(network.name) } } label: {
            HStack(spacing: 8) {
                Image(systemName: "wifi", variableValue: WiFiSignal.percent(rssi: network.rssi) / 100)
                    .font(.system(size: 12)).frame(width: 18)
                Text(network.name).font(.system(size: 12, weight: current ? .semibold : .regular)).lineLimit(1)
                if let band = network.band { Text(band.rawValue).font(.system(size: 10)).foregroundStyle(.tertiary) }
                Spacer(minLength: 4)
                if monitor.busy.contains(network.name) { ProgressView().controlSize(.mini) }
                if current { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor) }
                else if network.known { Text("Join").font(.system(size: 11)).foregroundStyle(Color.accentColor) }
                if network.secure { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!network.known || current)
        .help(network.known ? (current ? "Connected" : "Join with the saved password") : "Not saved on this Mac: join it from Wi-Fi Settings")
    }
}

// MARK: - Bluetooth board

struct BluetoothBoard: View {
    @ObservedObject var store: MonitoringStore
    let id: UUID
    let configure: () -> Void
    @StateObject private var monitor = ConnectivityMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label { Text("Bluetooth") } icon: { BluetoothRune() }.font(.headline)
                Spacer()
                if monitor.bluetooth?.access == .allowed {
                    Toggle("Bluetooth", isOn: Binding(get: { monitor.bluetooth?.powered ?? false }, set: { monitor.setBluetoothPower($0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                        .disabled(monitor.busy.contains("bluetooth-power"))
                        .accessibilityIdentifier("bluetooth-power")
                }
            }
            if let bluetooth = monitor.bluetooth {
                switch bluetooth.access {
                case .notDetermined:
                    permission("MenuSprite needs Bluetooth access to see your devices, their batteries and whether Bluetooth is on. Nothing is scanned or sent anywhere.",
                               button: "Allow Bluetooth Access")
                case .denied:
                    permission("Bluetooth access is off for MenuSprite. Turn it on in Privacy & Security › Bluetooth.", button: "Open Privacy Settings…")
                case .allowed:
                    if !bluetooth.powered { Text("Bluetooth is off.").font(.system(size: 12)).foregroundStyle(.secondary) }
                    else { devices(bluetooth) }
                }
            } else {
                Text("Reading Bluetooth…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let notice = monitor.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Bluetooth Settings…") { ConnectivityMonitor.openSettings("x-apple.systempreferences:com.apple.BluetoothSettings") }
                Spacer()
                Button("Configure…", action: configure)
            }.controlSize(.small)
        }
        .padding(16).frame(width: 360)
        .onAppear { monitor.start(.bluetooth) }
        .onDisappear { monitor.stop() }
        // A sprite showing "allow access" picks the readings up at its next sample once access is granted.
        .onChange(of: monitor.bluetooth?.access) { _, _ in store.refresh() }
    }

    private func permission(_ text: String, button: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(button) { monitor.requestBluetooth() }.controlSize(.small)
        }
    }

    @ViewBuilder private func devices(_ bluetooth: BluetoothSnapshot) -> some View {
        let connected = bluetooth.connected
        let paired = bluetooth.devices.filter { !$0.connected }
        if connected.isEmpty {
            Text("Nothing connected.").font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 8) { ForEach(connected) { device in connectedRow(device) } }
        }
        if !paired.isEmpty {
            Divider()
            Text("Paired").font(.system(size: 12, weight: .semibold))
            ScrollView {
                VStack(spacing: 0) { ForEach(paired) { device in pairedRow(device) } }
            }
            .frame(maxHeight: 180)
        }
    }

    private func connectedRow(_ device: BluetoothDevice) -> some View {
        HStack(alignment: .center, spacing: 10) {
            DeviceIcon(kind: device.kind).font(.system(size: 22)).frame(width: 32)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                levels(device.battery)
            }
            Spacer(minLength: 4)
            if monitor.busy.contains(device.address) { ProgressView().controlSize(.mini) }
            Button("Disconnect") { monitor.toggle(device) }.controlSize(.small).disabled(monitor.busy.contains(device.address))
        }
    }

    @ViewBuilder private func levels(_ battery: BluetoothBattery) -> some View {
        let parts: [(String, Int)] = [("L", battery.left), ("R", battery.right), ("Case", battery.chargingCase)]
            .compactMap { label, value in value.map { (label, $0) } }
        if !parts.isEmpty {
            HStack(spacing: 10) { ForEach(parts, id: \.0) { part in BatteryLevel(label: part.0, percent: part.1) } }
        } else if let single = battery.single {
            BatteryLevel(label: nil, percent: single)
        } else {
            Text("Connected").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func pairedRow(_ device: BluetoothDevice) -> some View {
        HStack(spacing: 8) {
            DeviceIcon(kind: device.kind).font(.system(size: 13)).frame(width: 20).foregroundStyle(.secondary)
            Text(device.name).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 4)
            if monitor.busy.contains(device.address) { ProgressView().controlSize(.mini) }
            Button("Connect") { monitor.toggle(device) }
                .buttonStyle(.borderless).font(.system(size: 11)).disabled(monitor.busy.contains(device.address))
        }
        .padding(.vertical, 4)
    }
}

/// A small battery with its level: green, amber below 30%, red below 15%.
private struct BatteryLevel: View {
    let label: String?
    let percent: Int
    private var color: Color { percent < 15 ? .red : percent < 30 ? .orange : .green }
    var body: some View {
        HStack(spacing: 4) {
            if let label { Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5).stroke(Color.primary.opacity(0.35), lineWidth: 1).frame(width: 22, height: 10)
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: max(1.5, 19 * CGFloat(percent) / 100), height: 7).padding(.leading, 1.5)
            }
            Text("\(percent)%").font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label.map { "\($0) " } ?? "")battery \(percent) percent")
    }
}

/// A device's SF Symbol, or MenuSprite's Bluetooth mark for anything it cannot name.
private struct DeviceIcon: View {
    let kind: BluetoothDeviceKind
    var body: some View {
        if kind.symbol == SpriteSymbols.bluetooth { BluetoothRune() } else { Image(systemName: kind.symbol) }
    }
}

private struct BluetoothRune: View {
    var body: some View {
        if let image = SpriteSymbols.image(SpriteSymbols.bluetooth) {
            Image(nsImage: image).renderingMode(.template).resizable().aspectRatio(contentMode: .fit).frame(height: 15)
        }
    }
}
