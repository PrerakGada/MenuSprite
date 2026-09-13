import AppKit
import Combine
import QuartzCore
import PowerControl
import SystemMonitoring

@MainActor
final class EnergyBoardController: NSViewController {
    let monitoring: MonitoringStore
    let processes: MemoryBoardStore
    let power: PowerStore
    let id: UUID
    private let configure: () -> Void
    private let showPower: () -> Void
    private let close: () -> Void
    private let observationID = UUID()
    private var subscriptions: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var pending = false
    private var stopped = false
    private var lastPowerRefresh = Date.distantPast
    private var freshnessStamp: Date?
    private var staleRefresh: DispatchWorkItem?
    private var wasEnabled: Bool
    private var optionsVisible = false
    private var limitVisible = false
    private var scroll: NSScrollView!
    private(set) var document: EnergyDocumentView!
    private var limitButton: NSButton!
    private var dischargeButton: NSButton!
    private var topUpButton: NSButton!
    private var limitSlider: NSSlider!
    private var lowerStepper: NSStepper!
    private var lowerLabel: NSTextField!
    private var limitLabel: NSTextField!
    private var applyButton: NSButton!
    private var stopButton: NSButton!
    private var controlViews: [NSView] = []
    private var optionButtons: [NSButton] = []
    private var refreshButton: NSButton!
    private var prefs: UserDefaults { .standard }
    private(set) var charts: [Bool]
    private var showFlow: Bool
    private var animate: Bool
    var forceReducedMotion = false { didSet { updateContents() } }
    var isAnimating: Bool { document?.isAnimating == true }
    var controlActionsEnabled: Bool { applyButton?.isEnabled == true }
    var isStopped: Bool { stopped }
    init(monitoring: MonitoringStore, processes: MemoryBoardStore, power: PowerStore, id: UUID,
         configure: @escaping () -> Void, showPower: @escaping () -> Void, close: @escaping () -> Void) {
        self.monitoring = monitoring; self.processes = processes; self.power = power; self.id = id
        self.configure = configure; self.showPower = showPower; self.close = close
        wasEnabled = monitoring.sprites.first { $0.id == id }?.enabled == true
        charts = ["watts", "temperature", "charge"].map { UserDefaults.standard.object(forKey: "energy.chart.\($0)") as? Bool ?? true }
        showFlow = UserDefaults.standard.object(forKey: "energy.flow") as? Bool ?? true
        animate = UserDefaults.standard.object(forKey: "energy.animate") as? Bool ?? true
        super.init(nibName: nil, bundle: nil)
        processes.setIconConsumers([])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        let root = EnergyBackgroundView(frame: NSRect(x: 0, y: 0, width: 430, height: 830))
        // Draw rounded window edges directly; clipping the whole animated layer
        // tree forces a large offscreen composition surface on this OS.
        view = root
        limitButton = pill("Limit: \(power.band.upper)%", action: #selector(toggleLimit))
        dischargeButton = pill("Discharge ⊖", action: #selector(discharge))
        topUpButton = pill("Top Up ⊕", action: #selector(topUp))
        let options = NSButton(image: NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Dashboard options")!, target: self, action: #selector(toggleOptions))
        options.isBordered = false; options.toolTip = "Choose charts and motion"; options.setAccessibilityLabel("Dashboard options")
        limitButton.setAccessibilityIdentifier("energy-limit")
        dischargeButton.setAccessibilityIdentifier("energy-discharge")
        topUpButton.setAccessibilityIdentifier("energy-top-up")
        for button in [limitButton!, dischargeButton!, topUpButton!, options] { root.addSubview(button) }
        scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder; scroll.horizontalScrollElasticity = .none
        scroll.contentView.postsBoundsChangedNotifications = true
        document = EnergyDocumentView(monitoring: monitoring, processes: processes, power: power)
        scroll.documentView = document; root.addSubview(scroll)
        let powerSettings = pill(BuildFeatures.powerPageTitle, action: #selector(openPowerSettings))
        powerSettings.setAccessibilityIdentifier("energy-power-settings")
        let spriteSettings = pill("Customize", action: #selector(openSpriteSettings))
        let dismiss = pill("Close", action: #selector(dismissPanel))
        for button in [powerSettings, spriteSettings, dismiss] { root.addSubview(button) }
        for v in root.subviews { v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            limitButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14), limitButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 14), limitButton.widthAnchor.constraint(equalToConstant: 111), limitButton.heightAnchor.constraint(equalToConstant: 30),
            dischargeButton.leadingAnchor.constraint(equalTo: limitButton.trailingAnchor, constant: 8), dischargeButton.centerYAnchor.constraint(equalTo: limitButton.centerYAnchor), dischargeButton.widthAnchor.constraint(equalToConstant: 110), dischargeButton.heightAnchor.constraint(equalTo: limitButton.heightAnchor),
            topUpButton.leadingAnchor.constraint(equalTo: dischargeButton.trailingAnchor, constant: 8), topUpButton.centerYAnchor.constraint(equalTo: limitButton.centerYAnchor), topUpButton.widthAnchor.constraint(equalToConstant: 98), topUpButton.heightAnchor.constraint(equalTo: limitButton.heightAnchor),
            options.leadingAnchor.constraint(equalTo: topUpButton.trailingAnchor, constant: 8), options.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14), options.centerYAnchor.constraint(equalTo: limitButton.centerYAnchor), options.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 56), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: powerSettings.topAnchor, constant: -10),
            powerSettings.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14), powerSettings.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12), powerSettings.heightAnchor.constraint(equalToConstant: 28),
            spriteSettings.leadingAnchor.constraint(equalTo: powerSettings.trailingAnchor, constant: 8), spriteSettings.widthAnchor.constraint(equalTo: powerSettings.widthAnchor), spriteSettings.centerYAnchor.constraint(equalTo: powerSettings.centerYAnchor), spriteSettings.heightAnchor.constraint(equalTo: powerSettings.heightAnchor),
            dismiss.leadingAnchor.constraint(equalTo: spriteSettings.trailingAnchor, constant: 8), dismiss.widthAnchor.constraint(equalToConstant: 68), dismiss.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14), dismiss.centerYAnchor.constraint(equalTo: powerSettings.centerYAnchor), dismiss.heightAnchor.constraint(equalTo: powerSettings.heightAnchor)
        ])
        installControlViews()
        for publisher in [monitoring.objectWillChange.eraseToAnyPublisher(), processes.objectWillChange.eraseToAnyPublisher(), power.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] _ in self?.queueUpdate() }.store(in: &subscriptions)
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.updateAnimationVisibility() } })
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.updateAnimationVisibility() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.updateContents() } })
        power.observeBattery(observationID)
        updateContents()
    }
    override func viewDidAppear() { super.viewDidAppear(); updateAnimationVisibility() }
    override func viewDidLayout() {
        super.viewDidLayout(); guard document != nil else { return }
        document.frame.size.width = scroll.contentSize.width; updateContents()
    }
    private func pill(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false; button.controlSize = .regular; button.tag = 900
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        return button
    }
    private func installControlViews() {
        limitLabel = NSTextField(labelWithString: "")
        limitLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        limitSlider = NSSlider(value: Double(power.band.upper), minValue: 21, maxValue: 100, target: self, action: #selector(changeLimit))
        limitSlider.isContinuous = true; limitSlider.setAccessibilityLabel("MenuSprite charge limit"); limitSlider.setAccessibilityIdentifier("energy-limit-slider")
        lowerLabel = NSTextField(labelWithString: "")
        lowerLabel.font = .systemFont(ofSize: 11)
        lowerStepper = NSStepper(); lowerStepper.minValue = 20; lowerStepper.maxValue = 99
        lowerStepper.target = self; lowerStepper.action = #selector(changeLower)
        lowerStepper.setAccessibilityLabel("Resume charging below percentage")
        applyButton = pill("Apply limit", action: #selector(applyLimit))
        applyButton.setAccessibilityIdentifier("energy-apply-limit")
        stopButton = pill("Stop control", action: #selector(stopControl))
        stopButton.setAccessibilityIdentifier("energy-stop-control")
        controlViews = [limitLabel, limitSlider, lowerLabel, lowerStepper, applyButton, stopButton]
        for v in controlViews { document.addSubview(v) }
        for (index, name) in ["Power flow", "Power consumption", "Battery temperature", "Battery level", "Animate flow"].enumerated() {
            let button = NSButton(checkboxWithTitle: name, target: self, action: #selector(changeOption(_:)))
            button.tag = index; button.font = .systemFont(ofSize: 11); document.addSubview(button); optionButtons.append(button)
        }
        refreshButton = pill("Refresh readings", action: #selector(refreshReadings))
        refreshButton.setAccessibilityIdentifier("energy-refresh")
        document.addSubview(refreshButton)
    }
    private func queueUpdate() {
        guard !pending, !stopped else { return }; pending = true
        DispatchQueue.main.async { [weak self] in self?.pending = false; self?.updateContents() }
    }
    private func updateContents() {
        guard isViewLoaded, !stopped else { return }
        guard scroll.contentSize.width >= 300 else { view.needsLayout = true; return }
        let enabled = monitoring.sprites.first { $0.id == id }?.enabled == true
        if wasEnabled != enabled { wasEnabled = enabled; if enabled { processes.start() } else { processes.stop() } }
        let interval = monitoring.sprites.first { $0.id == id }?.interval ?? 2
        document.enabled = enabled; document.maximumAge = max(8, interval * 2 + 3)
        document.limitExpanded = limitVisible; document.optionsExpanded = optionsVisible
        document.chartVisibility = charts; document.showFlow = showFlow
        document.reducedMotion = forceReducedMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        limitButton.title = "\(power.snapshot.mode == .off || power.band != power.snapshot.band ? "Target" : "Limit"): \(power.band.upper)%"
        limitButton.toolTip = "MenuSprite’s saved target. It is only enforced while MenuSprite battery control is active."
        topUpButton.title = power.snapshot.mode == .topUp ? "Stop Top Up" : "Top Up ⊕"
        dischargeButton.title = power.snapshot.mode == .discharge ? "Stop Discharge" : "Discharge ⊖"
        topUpButton.contentTintColor = power.snapshot.mode == .topUp ? .systemBlue : nil
        dischargeButton.contentTintColor = power.snapshot.mode == .discharge ? .systemOrange : nil
        topUpButton.isEnabled = enabled && power.canControlBattery && power.band.valid
        dischargeButton.isEnabled = enabled && power.canControlBattery && power.band.valid && power.snapshot.dischargeSupported && (power.snapshot.mode == .discharge || (power.snapshot.percent ?? 0) > power.band.upper)
        topUpButton.toolTip = power.batteryControlReason ?? "Charge to 100% once, then return to your charge band."
        dischargeButton.toolTip = power.batteryControlReason ?? "Use the battery while connected until it reaches your limit; no artificial workload."
        limitLabel.stringValue = "Charge to \(power.band.upper)%"
        lowerLabel.stringValue = "Resume below \(power.band.lower)%"
        limitSlider.doubleValue = Double(power.band.upper)
        lowerStepper.integerValue = power.band.lower; lowerStepper.maxValue = Double(power.band.upper - 1)
        applyButton.isEnabled = enabled && power.canControlBattery && power.band.valid
        stopButton.isEnabled = !power.busy && power.snapshot.helperConnected && (power.snapshot.mode != .off || power.snapshot.recoveryPending)
        for v in controlViews { v.isHidden = !limitVisible }
        let y = document.limitOrigin
        limitLabel.frame = NSRect(x: 28, y: y + 12, width: 240, height: 20)
        limitSlider.frame = NSRect(x: 27, y: y + 40, width: max(100, document.bounds.width - 54), height: 20)
        lowerLabel.frame = NSRect(x: 28, y: y + 73, width: 150, height: 20)
        lowerStepper.frame = NSRect(x: 183, y: y + 68, width: 19, height: 26)
        applyButton.frame = NSRect(x: 28, y: y + 108, width: 120, height: 28)
        stopButton.frame = NSRect(x: 158, y: y + 108, width: 120, height: 28)
        let states = [showFlow] + charts + [animate]
        for (index, button) in optionButtons.enumerated() {
            button.isHidden = !optionsVisible; button.state = states[index] ? .on : .off
            button.frame = NSRect(x: 28 + CGFloat(index % 2) * 195, y: document.optionsOrigin + 12 + CGFloat(index / 2) * 27, width: 190, height: 23)
        }
        refreshButton.isHidden = !optionsVisible
        refreshButton.frame = NSRect(x: 223, y: document.optionsOrigin + 64, width: 162, height: 26)
        if document.frame.height != document.requiredHeight { document.frame.size.height = document.requiredHeight }
        document.updateLayers(); document.needsDisplay = true
        view.needsDisplay = true
        updateAnimationVisibility()
        if power.helperInstalled && Date().timeIntervalSince(lastPowerRefresh) > 5 {
            lastPowerRefresh = Date(); power.refreshBatteryStatus()
        }
        if let stamp = monitoring.lastSample, stamp != freshnessStamp {
            freshnessStamp = stamp; staleRefresh?.cancel()
            let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.updateContents() } }
            staleRefresh = item
            DispatchQueue.main.asyncAfter(deadline: .now() + document.maximumAge + 0.1, execute: item)
        }
    }
    private func updateAnimationVisibility() {
        guard document != nil else { return }
        let onScreen = view.window?.isVisible == true && view.window?.occlusionState.contains(.visible) == true
        document.setMotionActive(!stopped && wasEnabled && animate && onScreen && scroll.contentView.bounds.intersects(document.flowRect))
        if !stopped { processes.setIconConsumers(document.visibleIconConsumers(in: scroll.contentView.bounds)) }
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        staleRefresh?.cancel(); staleRefresh = nil
        document?.setMotionActive(false); document?.removeAnimations()
        processes.stop()
        power.stopObservingBattery(observationID); subscriptions.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
    }
    func expandLimitForValidation() { limitVisible = true; updateContents() }
    func refreshForValidation() { refreshReadings() }
    @objc private func toggleLimit() { limitVisible.toggle(); updateContents() }
    @objc private func toggleOptions() { optionsVisible.toggle(); updateContents() }
    @objc private func changeLimit() {
        power.band.upper = Int(limitSlider.doubleValue.rounded())
        power.band.lower = min(power.band.lower, power.band.upper - 1)
        power.settingsChanged(); updateContents()
    }
    @objc private func changeLower() { power.band.lower = lowerStepper.integerValue; power.settingsChanged(); updateContents() }
    @objc private func applyLimit() { power.battery(.maintain) }
    @objc private func stopControl() { power.stopBattery() }
    @objc private func topUp() { power.battery(power.snapshot.mode == .topUp ? .maintain : .topUp) }
    @objc private func discharge() { power.battery(power.snapshot.mode == .discharge ? .maintain : .discharge) }
    @objc private func changeOption(_ button: NSButton) {
        let value = button.state == .on
        switch button.tag {
        case 0: showFlow = value; prefs.set(value, forKey: "energy.flow")
        case 4: animate = value; prefs.set(value, forKey: "energy.animate")
        default: charts[button.tag - 1] = value; prefs.set(value, forKey: "energy.chart.\(["watts", "temperature", "charge"][button.tag - 1])")
        }
        updateContents()
    }
    @objc private func refreshReadings() { guard !stopped else { return }; monitoring.refresh(); power.refreshBatteryStatus(); if wasEnabled { processes.refresh() } }
    @objc private func openPowerSettings() { close(); showPower() }
    @objc private func openSpriteSettings() { configure() }
    @objc private func dismissPanel() { close() }
}

private final class EnergyBackgroundView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); bounds.fill(using: .copy)
        NSColor(calibratedWhite: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.11 : 0.985, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18).fill()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        for case let button as NSButton in subviews where button.tag == 900 {
            NSColor(calibratedWhite: dark ? 0.20 : 0.91, alpha: 1).setFill()
            NSBezierPath(roundedRect: button.frame, xRadius: 13, yRadius: 13).fill()
        }
    }
}
