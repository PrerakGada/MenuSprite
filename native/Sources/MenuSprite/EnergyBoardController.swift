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
    /// Nil when the dashboard is hosted by the hub panel rather than by a sprite: there is then no
    /// sprite to pause, so the dashboard is always live and its Customize action is hidden.
    let id: UUID?
    let embedded: Bool
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
    private var ledToggle: NSButton!
    private var sailLabel: NSTextField!
    private var sailPopup: NSPopUpButton!
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
    init(monitoring: MonitoringStore, processes: MemoryBoardStore, power: PowerStore, id: UUID?,
         embedded: Bool = false,
         configure: @escaping () -> Void, showPower: @escaping () -> Void, close: @escaping () -> Void) {
        self.monitoring = monitoring; self.processes = processes; self.power = power; self.id = id
        self.embedded = embedded
        self.configure = configure; self.showPower = showPower; self.close = close
        wasEnabled = id.map { sprite in monitoring.sprites.first { $0.id == sprite }?.enabled == true } ?? true
        charts = ["watts", "temperature", "charge"].map { UserDefaults.standard.object(forKey: "energy.chart.\($0)") as? Bool ?? true }
        showFlow = UserDefaults.standard.object(forKey: "energy.flow") as? Bool ?? true
        animate = UserDefaults.standard.object(forKey: "energy.animate") as? Bool ?? true
        super.init(nibName: nil, bundle: nil)
        processes.setIconConsumers([])
    }
    required init?(coder: NSCoder) { fatalError() }
    private var spriteEnabled: Bool {
        guard let id else { return true }
        return monitoring.sprites.first { $0.id == id }?.enabled == true
    }
    override func loadView() {
        let root = EnergyBackgroundView(frame: NSRect(x: 0, y: 0, width: 430, height: 830))
        root.cornerRadius = embedded ? 0 : 18
        // Draw rounded window edges directly; clipping the whole animated layer
        // tree forces a large offscreen composition surface on this OS.
        view = root
        limitButton = pill("", action: #selector(toggleLimit))
        setLimitTitle("Limit:", "\(power.band.upper)%")
        dischargeButton = pill("Discharge", action: #selector(discharge), symbol: "minus.circle")
        topUpButton = pill("Top Up", action: #selector(topUp), symbol: "plus.circle")
        let options = pill("", action: #selector(toggleOptions), symbol: "square.grid.2x2")
        options.toolTip = "Choose charts and motion"; options.setAccessibilityLabel("Dashboard options")
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
        // The hub supplies its own footer, so an embedded dashboard keeps only the Power page link.
        spriteSettings.isHidden = embedded || id == nil
        dismiss.isHidden = embedded
        for button in [powerSettings, spriteSettings, dismiss] { root.addSubview(button) }
        for v in root.subviews { v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            // AlDente's row: the limit on the left, Discharge and Top Up pushed right, then the grid.
            limitButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14), limitButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            dischargeButton.leadingAnchor.constraint(greaterThanOrEqualTo: limitButton.trailingAnchor, constant: 8), dischargeButton.centerYAnchor.constraint(equalTo: limitButton.centerYAnchor),
            topUpButton.leadingAnchor.constraint(equalTo: dischargeButton.trailingAnchor, constant: 8), topUpButton.centerYAnchor.constraint(equalTo: limitButton.centerYAnchor),
            options.leadingAnchor.constraint(equalTo: topUpButton.trailingAnchor, constant: 8), options.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14), options.centerYAnchor.constraint(equalTo: limitButton.centerYAnchor), options.widthAnchor.constraint(equalTo: options.heightAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 52), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: powerSettings.topAnchor, constant: -10),
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
    private func pill(_ title: String, action: Selector, symbol: String? = nil) -> NSButton {
        let button = EnergyPillButton(title: title, target: self, action: action)
        button.isBordered = false; button.controlSize = .regular; button.tag = 900
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .medium))
            button.imagePosition = title.isEmpty ? .imageOnly : .imageTrailing
            button.imageHugsTitle = true
        }
        return button
    }
    /// "Limit:" bold, the value regular, as AlDente sets it.
    private func setLimitTitle(_ label: String, _ value: String) {
        let title = NSMutableAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.labelColor])
        title.append(NSAttributedString(string: " " + value, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor]))
        limitButton.attributedTitle = title
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
        ledToggle = NSButton(checkboxWithTitle: "MagSafe light: green holding · amber charging · blinks discharging", target: self, action: #selector(changeLED))
        ledToggle.font = .systemFont(ofSize: 11); ledToggle.setAccessibilityIdentifier("energy-magsafe-led")
        sailLabel = NSTextField(labelWithString: "")
        sailLabel.font = .systemFont(ofSize: 11)
        sailPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        sailPopup.addItems(withTitles: Sailing.choices.map { $0 == 0 ? "Off" : "\($0)%" })
        sailPopup.controlSize = .small; sailPopup.font = .systemFont(ofSize: 11)
        sailPopup.target = self; sailPopup.action = #selector(changeSailing)
        sailPopup.setAccessibilityLabel("Sailing band"); sailPopup.setAccessibilityIdentifier("energy-sailing")
        controlViews = [limitLabel, limitSlider, lowerLabel, lowerStepper, applyButton, stopButton, ledToggle, sailLabel, sailPopup]
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
        let enabled = spriteEnabled
        if wasEnabled != enabled { wasEnabled = enabled; if enabled { processes.start() } else { processes.stop() } }
        let interval = id.flatMap { sprite in monitoring.sprites.first { $0.id == sprite }?.interval } ?? 2
        document.enabled = enabled; document.maximumAge = max(8, interval * 2 + 3)
        document.limitExpanded = limitVisible; document.optionsExpanded = optionsVisible
        document.chartVisibility = charts; document.showFlow = showFlow
        document.reducedMotion = forceReducedMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if power.usesSystemLimit { updateSystemLimitControls(enabled) } else {
        setLimitTitle(power.snapshot.mode == .off || power.band != power.snapshot.band ? "Target:" : "Limit:", "\(power.band.upper)%")
        limitButton.toolTip = "MenuSprite’s saved target. It is only enforced while MenuSprite battery control is active."
        topUpButton.title = power.snapshot.mode == .topUp ? "Stop Top Up" : "Top Up"
        dischargeButton.title = power.snapshot.mode == .discharge ? "Stop Discharge" : "Discharge"
        topUpButton.contentTintColor = power.snapshot.mode == .topUp ? .systemBlue : nil
        dischargeButton.contentTintColor = power.snapshot.mode == .discharge ? .systemOrange : nil
        topUpButton.isEnabled = enabled && power.canControlBattery && power.band.valid
        dischargeButton.isEnabled = enabled && power.canDischarge && power.band.valid && (power.snapshot.mode == .discharge || (power.snapshot.percent ?? 0) > power.band.upper)
        topUpButton.toolTip = power.batteryControlReason ?? "Charge to 100% once, then return to your charge band."
        dischargeButton.toolTip = power.dischargeReason ?? "Use the battery while connected until it reaches your limit; no artificial workload."
        applyButton.title = "Apply limit"; stopButton.title = "Stop control"
        applyButton.isEnabled = enabled && power.canControlBattery && power.band.valid
        stopButton.isEnabled = !power.busy && power.snapshot.helperConnected && (power.snapshot.mode != .off || power.snapshot.recoveryPending)
        }
        limitLabel.stringValue = "Charge to \(power.band.upper)%"
        lowerLabel.stringValue = "Resume below \(power.band.lower)%"
        limitSlider.doubleValue = Double(power.band.upper)
        lowerStepper.integerValue = power.band.lower; lowerStepper.maxValue = Double(power.band.upper - 1)
        for v in controlViews { v.isHidden = !limitVisible }
        // macOS's limit has no resume level, and the LED needs the helper.
        lowerLabel.isHidden = !limitVisible || power.usesSystemLimit; lowerStepper.isHidden = lowerLabel.isHidden
        ledToggle.isHidden = !limitVisible || !power.usesSystemLimit
        ledToggle.state = power.ledControl ? .on : .off; ledToggle.isEnabled = power.helperInstalled
        sailLabel.isHidden = !limitVisible || !power.usesSystemLimit; sailPopup.isHidden = sailLabel.isHidden
        sailLabel.stringValue = power.sailingBand == 0 ? "Sailing off · tops up at every dip below the limit"
            : "Sailing · charges only below \(max(0, power.band.upper - power.sailingBand))%"
        if let index = Sailing.choices.firstIndex(of: power.sailingBand) { sailPopup.selectItem(at: index) }
        sailPopup.isEnabled = power.canSetLimit
        sailLabel.frame = NSRect(x: 28, y: document.limitOrigin + 72, width: max(100, document.bounds.width - 150), height: 18)
        sailPopup.frame = NSRect(x: document.bounds.width - 110, y: document.limitOrigin + 67, width: 84, height: 24)
        ledToggle.frame = NSRect(x: 26, y: document.limitOrigin + 100, width: max(100, document.bounds.width - 52), height: 22)
        let y = document.limitOrigin
        limitLabel.frame = NSRect(x: 28, y: y + 12, width: 240, height: 20)
        limitSlider.frame = NSRect(x: 27, y: y + 40, width: max(100, document.bounds.width - 54), height: 20)
        lowerLabel.frame = NSRect(x: 28, y: y + 73, width: 150, height: 20)
        lowerStepper.frame = NSRect(x: 183, y: y + 68, width: 19, height: 26)
        applyButton.frame = NSRect(x: 28, y: y + 136, width: 120, height: 28)
        stopButton.frame = NSRect(x: 158, y: y + 136, width: 120, height: 28)
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
        if power.usesSystemLimit { power.setLimit(Int(limitSlider.doubleValue.rounded())); updateContents(); return }
        power.band.upper = Int(limitSlider.doubleValue.rounded())
        power.band.lower = min(power.band.lower, power.band.upper - 1)
        power.settingsChanged(); updateContents()
    }
    @objc private func changeLower() { power.band.lower = lowerStepper.integerValue; power.settingsChanged(); updateContents() }
    @objc private func applyLimit() { power.usesSystemLimit ? power.setLimit(power.band.upper) : power.battery(.maintain) }
    @objc private func stopControl() { power.usesSystemLimit ? power.setSaver(false) : power.stopBattery() }
    @objc private func topUp() {
        if power.usesSystemLimit { power.toggleTopUp() } else { power.battery(power.snapshot.mode == .topUp ? .maintain : .topUp) }
    }
    @objc private func discharge() {
        if power.usesSystemLimit { power.toggleDischarge() }
        else if power.snapshot.mode == .discharge { power.stopBattery() } else { power.runOnBattery() }
    }
    @objc private func changeSailing() { power.setSailing(Sailing.choices[max(0, sailPopup.indexOfSelectedItem)]) }
    @objc private func changeLED() { power.setLEDControl(ledToggle.state == .on) }
    /// macOS's own limit: the buttons act on it directly and say what macOS is doing.
    private func updateSystemLimitControls(_ enabled: Bool) {
        let draining = power.isDraining && power.holdLevel == nil
        setLimitTitle("Limit:", power.saverEnabled ? "\(power.band.upper)%" : "off")
        limitButton.toolTip = "macOS holds this limit, through sleep and even with MenuSprite quit. Drag the line on the battery bar to change it."
        topUpButton.title = power.topUpActive ? "Stop Top Up" : "Top Up"
        dischargeButton.title = draining ? "Stop Discharge" : "Discharge"
        topUpButton.contentTintColor = power.topUpActive ? .systemBlue : nil
        dischargeButton.contentTintColor = draining ? .systemOrange : (power.holdLevel != nil ? .systemYellow : nil)
        topUpButton.isEnabled = enabled && power.canSetLimit && (power.topUpActive || power.snapshot.pluggedIn == true)
        dischargeButton.isEnabled = enabled && power.canSetLimit && (draining || power.holdLevel != nil || power.canDischargeToLimit)
        topUpButton.toolTip = power.batteryControlReason ?? "Charge to 100% once. Your \(power.band.upper)% limit returns when you unplug."
        dischargeButton.toolTip = power.batteryControlReason ?? (draining
            ? "macOS is running the Mac from the battery down to \(power.band.upper)%. Stop to hold the current level."
            : "Run from the battery, cable connected, down to \(power.band.upper)%. No artificial workload.")
        applyButton.title = "Apply limit"; stopButton.title = "Turn limit off"
        applyButton.isEnabled = enabled && power.canSetLimit
        stopButton.isEnabled = enabled && power.canSetLimit && power.saverEnabled
        limitSlider.isContinuous = false
    }
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
    var cornerRadius: CGFloat = 18
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); bounds.fill(using: .copy)
        NSColor(calibratedWhite: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.11 : 0.985, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // Glass capsules: a faint wash and a hairline edge.
        for case let button as NSButton in subviews where button.tag == 900 && !button.isHidden {
            let path = NSBezierPath(roundedRect: button.frame, xRadius: button.frame.height / 2, yRadius: button.frame.height / 2)
            NSColor(calibratedWhite: dark ? 1 : 0, alpha: dark ? 0.07 : 0.045).setFill(); path.fill()
            NSColor(calibratedWhite: dark ? 1 : 0, alpha: dark ? 0.16 : 0.12).setStroke(); path.lineWidth = 1; path.stroke()
        }
    }
}

/// A capsule button sized to its title and icon, 30 pt tall.
private final class EnergyPillButton: NSButton {
    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: title.isEmpty && attributedTitle.length == 0 ? 30 : size.width + 26, height: 30)
    }
}
