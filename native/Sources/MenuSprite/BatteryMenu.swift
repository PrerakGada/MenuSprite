import AppKit
import SystemMonitoring
import PowerControl

/// The secondary-click menu on a menu-bar sprite. A battery item carries the charge
/// controls, so the limit can be turned on, moved or stopped without opening anything;
/// every other sprite gets the small sprite menu only.
///
/// Availability is reported, never assumed: when a control cannot run, the menu says
/// why in the same words the Battery & Power dashboard uses, instead of hiding it or
/// offering a button that silently does nothing.
@MainActor
final class SpriteContextMenu: NSObject, NSMenuDelegate {
    private let power: PowerStore
    private let store: MonitoringStore
    private var config: SpriteConfiguration
    private let openDashboard: () -> Void
    private let configure: () -> Void
    /// Presets in the band Prerak's own policy uses, plus the usual ceilings.
    static let presets = [50, 55, 60, 70, 80, 90, 100]

    init(power: PowerStore, store: MonitoringStore, config: SpriteConfiguration,
         openDashboard: @escaping () -> Void, configure: @escaping () -> Void) {
        self.power = power; self.store = store; self.config = config
        self.openDashboard = openDashboard; self.configure = configure
    }

    func menu(for config: SpriteConfiguration) -> NSMenu {
        self.config = config
        let menu = NSMenu()
        menu.autoenablesItems = false
        if config.isBatteryItem { addBatterySection(to: menu) }
        add(menu, "Configure sprite…", #selector(configureSprite))
        add(menu, config.enabled ? "Pause readings" : "Resume readings", #selector(togglePaused))
        add(menu, "Hide from menu bar", #selector(hideItem))
        return menu
    }

    private func addBatterySection(to menu: NSMenu) {
        let level = power.snapshot.percent.map { "Battery \($0)%" }
            ?? store.readings["battery.charge"]?.number.map { String(format: "Battery %.0f%%", $0) }
            ?? "Battery level unavailable"
        let state = store.readings["battery.state"]?.text
        add(menu, state.map { "\(level) · \($0)" } ?? level, nil)
        add(menu, power.limitStatus, nil)
        menu.addItem(.separator())
        add(menu, "Low Power Mode", #selector(toggleLowPower))?.state = power.lowPowerEnabled ? .on : .off
        if power.helperOutdated {
            add(menu, "Power helper needs reinstalling for this", nil)
            add(menu, "Copy helper install command", #selector(copyInstall))
        }
        menu.addItem(.separator())

        if let reason = power.batteryRequestReason {
            add(menu, reason, nil)
            if !power.helperInstalled && BuildFeatures.privilegedPowerControls {
                add(menu, "Copy helper install command", #selector(copyInstall))
            }
            // A charge limit and a discharge need different firmware. When only
            // the adapter switch exists, still offer the control that works.
            if power.canRequestDischarge { addDischargeItem(to: menu) }
        } else if power.usesSystemLimit {
            addSystemLimitSection(to: menu)
        } else {
            let limiting = power.snapshot.mode == .maintain
            let toggle = add(menu, "Limit charging to \(power.band.upper)%", #selector(toggleSaver))
            toggle?.state = power.saverEnabled || limiting ? .on : .off

            let limits = NSMenu()
            limits.autoenablesItems = false
            for preset in Self.presets {
                let item = NSMenuItem(title: "\(preset)%", action: #selector(chooseLimit(_:)), keyEquivalent: "")
                item.target = self; item.tag = preset
                item.state = power.band.upper == preset ? .on : .off
                limits.addItem(item)
            }
            limits.addItem(.separator())
            let custom = NSMenuItem(title: "Other…", action: #selector(showDashboard), keyEquivalent: "")
            custom.target = self; limits.addItem(custom)
            let limitItem = NSMenuItem(title: "Charge limit", action: nil, keyEquivalent: "")
            limitItem.submenu = limits
            menu.addItem(limitItem)

            let topUp = add(menu, "Top up to 100% once", #selector(topUp))
            topUp?.state = power.snapshot.mode == .topUp ? .on : .off
            if power.snapshot.dischargeSupported { addDischargeItem(to: menu) }
        }
        menu.addItem(.separator())
        add(menu, "Battery & Power…", #selector(showDashboard))
        menu.addItem(.separator())
    }

    /// macOS's own limit: a limit that holds through sleep, plus Top Up and Discharge on it.
    private func addSystemLimitSection(to menu: NSMenu) {
        let toggle = add(menu, power.saverEnabled ? "Charge limit \(power.band.upper)% · on" : "Limit charging to \(power.band.upper)%", #selector(toggleSaver))
        toggle?.state = power.saverEnabled ? .on : .off
        addLimitPresets(to: menu)
        let sailing = NSMenu(); sailing.autoenablesItems = false
        for choice in Sailing.choices {
            let item = NSMenuItem(title: choice == 0 ? "Off · exact limit" : "\(choice)% · charge below \(max(0, power.band.upper - choice))%",
                                  action: #selector(chooseSailing(_:)), keyEquivalent: "")
            item.target = self; item.tag = choice; item.state = power.sailingBand == choice ? .on : .off
            sailing.addItem(item)
        }
        let sailItem = NSMenuItem(title: power.sailingBand == 0 ? "Sailing off" : "Sailing \(power.sailingBand)%", action: nil, keyEquivalent: "")
        sailItem.submenu = sailing; menu.addItem(sailItem)
        let topUp = add(menu, power.topUpActive ? "Stop top up" : "Top up to 100% once", #selector(topUp))
        topUp?.state = power.topUpActive ? .on : .off
        topUp?.isEnabled = power.topUpActive || power.snapshot.pluggedIn == true
        let draining = power.isDraining && power.holdLevel == nil
        let discharge = add(menu, draining ? "Stop discharging (hold here)" : (power.holdLevel != nil ? "Resume discharging to \(power.band.upper)%" : "Discharge to \(power.band.upper)%"), #selector(discharge))
        discharge?.state = draining ? .on : .off
        discharge?.isEnabled = draining || power.holdLevel != nil || power.canDischargeToLimit
        if power.helperInstalled {
            let led = add(menu, "MagSafe light shows charge state", #selector(toggleLED))
            led?.state = power.ledControl ? .on : .off
        }
    }

    private func addLimitPresets(to menu: NSMenu) {
        let limits = NSMenu()
        limits.autoenablesItems = false
        for preset in Self.presets {
            let item = NSMenuItem(title: "\(preset)%", action: #selector(chooseLimit(_:)), keyEquivalent: "")
            item.target = self; item.tag = preset
            item.state = power.band.upper == preset ? .on : .off
            limits.addItem(item)
        }
        limits.addItem(.separator())
        let custom = NSMenuItem(title: "Other… (drag the line in Battery & Power)", action: #selector(showDashboard), keyEquivalent: "")
        custom.target = self; limits.addItem(custom)
        let limitItem = NSMenuItem(title: "Charge limit", action: nil, keyEquivalent: "")
        limitItem.submenu = limits
        menu.addItem(limitItem)
    }

    /// "Run on battery" reads as the action it is; the old wording described the
    /// firmware write rather than what the Mac does.
    private func addDischargeItem(to menu: NSMenu) {
        let running = power.snapshot.mode == .discharge
        let item = add(menu, running ? "Stop running on battery" : "Run on battery down to \(power.band.upper)%",
                       #selector(discharge))
        item?.state = running ? .on : .off
        item?.isEnabled = running || (power.snapshot.percent ?? 0) > power.band.upper
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector?) -> NSMenuItem? {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : self
        item.isEnabled = action != nil
        menu.addItem(item)
        return item
    }

    @objc private func toggleSaver() {
        power.setSaver(power.usesSystemLimit ? !power.saverEnabled : !(power.saverEnabled || power.snapshot.mode == .maintain))
    }
    @objc private func chooseLimit(_ sender: NSMenuItem) { power.setLimit(sender.tag) }
    @objc private func topUp() {
        if power.usesSystemLimit { power.toggleTopUp() } else { power.battery(power.snapshot.mode == .topUp ? .maintain : .topUp) }
    }
    @objc private func chooseSailing(_ sender: NSMenuItem) { power.setSailing(sender.tag) }
    @objc private func toggleLED() { power.setLEDControl(!power.ledControl) }
    @objc private func discharge() {
        if power.usesSystemLimit { power.toggleDischarge(); return }
        // Stopping a discharge must not fall back to a charge limit the firmware
        // may be unable to hold; hand control back to macOS instead.
        if power.snapshot.mode == .discharge { power.stopBattery() } else { power.battery(.discharge) }
    }
    @objc private func copyInstall() { power.copyInstallCommand() }
    @objc private func toggleLowPower() { power.toggleLowPower() }
    @objc private func showDashboard() { openDashboard() }
    @objc private func configureSprite() { configure() }
    @objc private func togglePaused() { store.setEnabled(config.id, !config.enabled) }
    @objc private func hideItem() { store.setMenuBar(config.id, false) }
}
