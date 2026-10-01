import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import Contacts
import CoreBluetooth
import CoreLocation
import EventKit
import HealthKit
import Intents
import MusicKit
import Photos
import ServiceManagement
import Speech
import UserNotifications
import PermissionModel
import PowerControl

@MainActor
final class PermissionStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var observations: [PermissionID: Observation] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var requestInFlight: PermissionID?
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var refreshCount = 0
    @Published var notice: String?
    @Published var search = ""
    @Published var filter: PermissionFilter = .all
    @Published var expanded: Set<PermissionID> = []

    private(set) var isVisible = false
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private var locationManager: CLLocationManager?

    func opened() {
        isVisible = true
        refresh()
    }

    func closed() {
        isVisible = false
        refreshTask?.cancel()
        refreshTask = nil
        refreshAgain = false
        isRefreshing = false
        locationManager?.delegate = nil
        locationManager = nil
    }

    func observation(for id: PermissionID) -> Observation {
        observations[id] ?? Observation(.checking, "Waiting for a status check.", method: "Not checked")
    }

    var visiblePermissions: [Permission] {
        PermissionCatalog.all.filter { permission in
            permission.matches(search.trimmingCharacters(in: .whitespacesAndNewlines)) &&
            (filter != .granted || observation(for: permission.id).state.isGranted) &&
            (filter != .used || permission.usedBy != "Not used by MenuSprite")
        }
    }

    func refresh() {
        guard isVisible else { return }
        guard !isRefreshing else { refreshAgain = true; return }
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            self.readSynchronousStatuses()
            // locationServicesEnabled can perform IPC. Do not block the UI thread.
            let globalLocation = await Task.detached(priority: .utility) { CLLocationManager.locationServicesEnabled() }.value
            guard !Task.isCancelled, self.isVisible else { return }
            let manager = self.locationManager ?? CLLocationManager()
            self.locationManager = manager
            let locationAuthorization = manager.authorizationStatus
            self.observations[.location] = Observation(StatusMapping.location(locationAuthorization),
                "The badge describes MenuSprite's app authorization. Global services may independently prevent use.",
                method: "CLLocationManager.authorizationStatus + locationServicesEnabled (no location updates)",
                resources: [.init("Global Location Services", globalLocation ? "On" : "Off"),
                            .init("MenuSprite authorization", self.locationDescription(locationAuthorization))])
            let notificationSettings = await NotificationReader.read()
            guard !Task.isCancelled, self.isVisible else { return }
            if let notificationSettings {
                self.observations[.notifications] = notificationSettings
            } else if let previous = self.observations[.notifications] {
                self.observations[.notifications] = previous.failedRefresh("Notifications did not respond within 5 seconds.")
            } else {
                self.observations[.notifications] = Observation(.unknown, "Notifications did not respond within 5 seconds. Refresh to retry.", method: "UNUserNotificationCenter timeout", stale: true)
            }
            self.lastRefresh = Date()
            self.refreshCount += 1
            self.isRefreshing = false
            self.refreshTask = nil
            if self.refreshAgain { self.refreshAgain = false; self.refresh() }
        }
    }

    private func readSynchronousStatuses() {
        func put(_ id: PermissionID, _ state: AccessState, _ detail: String, _ method: String,
                 _ resources: [ResourceStatus] = []) {
            observations[id] = Observation(state, detail, method: method, resources: resources)
        }
        put(.accessibility, .preflight(AXIsProcessTrusted()), "Effective accessibility trust for this running MenuSprite process.", "AXIsProcessTrusted (no prompt)")
        put(.inputMonitoring, .preflight(CGPreflightListenEventAccess()), "Effective input-listening access. Never requested and previously denied are not distinguishable.", "CGPreflightListenEventAccess")
        put(.screenRecording, .preflight(CGPreflightScreenCaptureAccess()), "Screen-capture preflight only. Never requested and previously denied are not distinguishable.", "CGPreflightScreenCaptureAccess", [.init("Screen recording", "Shown in the badge"), .init("System audio only", "Separate row; cannot infer from screen access")])
        put(.camera, StatusMapping.capture(AVCaptureDevice.authorizationStatus(for: .video)), "Authorization only; no camera is opened.", "AVCaptureDevice.authorizationStatus(.video)")
        put(.microphone, StatusMapping.capture(AVCaptureDevice.authorizationStatus(for: .audio)), "Authorization only; no microphone is opened.", "AVCaptureDevice.authorizationStatus(.audio)")
        put(.speech, StatusMapping.speech(SFSpeechRecognizer.authorizationStatus()), "Authorization only; no speech task is created.", "SFSpeechRecognizer.authorizationStatus")
        put(.contacts, StatusMapping.contacts(CNContactStore.authorizationStatus(for: .contacts)), "Authorization only; no contacts are fetched.", "CNContactStore.authorizationStatus(.contacts)")
        put(.calendars, StatusMapping.events(EKEventStore.authorizationStatus(for: .event)), "Full and write-only access remain distinct.", "EKEventStore.authorizationStatus(.event)")
        put(.reminders, StatusMapping.events(EKEventStore.authorizationStatus(for: .reminder)), "Authorization only; no reminders are fetched.", "EKEventStore.authorizationStatus(.reminder)")
        let photoRead = StatusMapping.photos(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        let photoAdd = StatusMapping.photos(PHPhotoLibrary.authorizationStatus(for: .addOnly))
        put(.photos, photoRead, "The badge is the read/write authorization level. Add-only permission does not imply read access.", "PHPhotoLibrary.authorizationStatus(for:)", [.init("Read/write", photoRead.label), .init("Add only", photoAdd.label)])
        put(.music, StatusMapping.music(MusicAuthorization.currentStatus), "MusicKit authorization only; no library or account lookup.", "MusicAuthorization.currentStatus")
        put(.focus, StatusMapping.focus(INFocusStatusCenter.default.authorizationStatus), "Authorization only; current Focus is not read.", "INFocusStatusCenter.authorizationStatus")
        put(.bluetooth, StatusMapping.bluetooth(CBManager.authorization), "App authorization only, independent of radio power. No Bluetooth manager or scan.", "CBManager.authorization (static)")
        put(.pasteboard, StatusMapping.pasteboard(NSPasteboard.general.accessBehavior), "Programmatic general-pasteboard access behavior. No contents are read.", "NSPasteboard.general.accessBehavior")
        put(.homeKit, .unavailable, "The HomeKit app framework is unavailable to this native macOS target.", "macOS 26.5 SDK platform availability")
        put(.motion, .unavailable, "CMMotionActivityManager is unavailable to native macOS apps.", "macOS 26.5 SDK platform availability")
        put(.tracking, .unavailable, "Apple documents native macOS tracking status as always notDetermined. There is no usable consent flow here; tracking is not implemented.", "ATTrackingManager macOS platform contract (no request)")
        put(.health, HKHealthStore.isHealthDataAvailable() ? .unavailableInBuild : .unavailable,
            "No health types or HealthKit capability are configured. Read authorization is intentionally undisclosed; write/share authorization would be per type.", "HKHealthStore.isHealthDataAvailable only")
        put(.passkeys, .unavailableInBuild, "MenuSprite has no web-browser passkey entitlement or integration. This is not a denied system grant.", "Built app capability inventory")
        for id: PermissionID in [.systemAudio, .remoteDesktop, .fullDiskAccess, .appManagement, .developerTools, .localNetwork] {
            put(id, .unknown, "No accurate general status check is available in this build. Review MenuSprite's entry in System Settings if present.", "No permission probe; system review required")
        }
        put(.filesAndFolders, .unknown, "Each resource can have different access. No filesystem probes are performed.", "No public universal folder-grant query", ["Desktop", "Documents", "Downloads", "Removable volumes", "Network volumes"].map { .init($0, "Check in System Settings · Not used") })
        put(.automation, .unknown, "No target applications or event types are configured. There is no meaningful aggregate Automation grant.", "App-owned target inventory; no Apple events sent", [.init("Target applications", "None configured")])
        put(.login, StatusMapping.login(SMAppService.mainApp.status), "Registration for this main app only; this is not a privacy grant.", "SMAppService.mainApp.status", [.init("Service", Bundle.main.bundleIdentifier ?? "Unknown identity"), .init("Settings", "System Settings → General → Login Items & Extensions")])
        let helper = PowerHelperInstall.state()
        let helperDetail: String = switch helper {
        case .on: "MenuSprite's power helper is allowed and registered with macOS. Power Controls shows its live connection."
        case .needsApproval: "Power controls are turned on, and macOS is waiting for you to allow MenuSprite under Login Items & Extensions."
        case .legacy: "An older power helper installed from Terminal is in use. Power Controls → Update power helper moves it into the app."
        case .off: "The signed power helper ships inside MenuSprite but is off. Turn on power controls only when choosing charge, fan or closed-lid controls."
        case .missing: "This copy of MenuSprite is missing its power helper. Reinstall MenuSprite to use power controls."
        }
        put(.backgroundHelpers, helper == .on || helper == .legacy ? .enabled : (helper == .needsApproval ? .requiresApproval : .notRegistered),
            helperDetail, "SMAppService.daemon status", [.init("Service", PowerIdentity.service), .init("Settings", "System Settings → General → Login Items & Extensions")])
        put(.administrator, .unknown, "Administrator approval is per operation: allowing the power helper in System Settings asks for it once. This is not a permanent global Administrator grant.", "No universal administrator grant query")
        put(.hardware, .unknown, "Charge, adapter and fan control capability is probed on Power Controls. Hardware detection, helper availability and feature activation are separate.", "No generic hardware permission exists")
        for id: PermissionID in [.selectedFiles, .keychain, .extensions] {
            put(id, .notConfigured, "This build defines no owned service, resource or integration of this type. No system grant is inferred.", "MenuSprite build inventory")
        }
    }

    func request(_ permission: Permission) {
        guard requestInFlight == nil, permission.canRequest(observation(for: permission.id).state) else { return }
        requestInFlight = permission.id
        notice = nil
        Task {
            do {
                switch permission.id {
                case .accessibility:
                    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                case .inputMonitoring: _ = CGRequestListenEventAccess()
                case .screenRecording: _ = CGRequestScreenCaptureAccess()
                case .camera: _ = await AVCaptureDevice.requestAccess(for: .video)
                case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
                case .speech:
                    _ = await withCheckedContinuation { continuation in
                        SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
                    }
                case .contacts: _ = try await CNContactStore().requestAccess(for: .contacts)
                case .calendars: _ = try await EKEventStore().requestFullAccessToEvents()
                case .reminders: _ = try await EKEventStore().requestFullAccessToReminders()
                case .photos: _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                case .notifications:
                    _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                case .location:
                    let manager = locationManager ?? CLLocationManager()
                    locationManager = manager
                    manager.delegate = self
                    manager.requestWhenInUseAuthorization()
                default: break
                }
                notice = "\(permission.name): macOS controls the result. Review the refreshed status; relaunch if System Settings asks."
            } catch {
                notice = "\(permission.name) request failed: \(error.localizedDescription)"
            }
            requestInFlight = nil
            refresh()
        }
    }

    func changeLoginRegistration() {
        guard requestInFlight == nil else { return }
        requestInFlight = .login
        Task {
            do {
                switch SMAppService.mainApp.status {
                case .enabled, .requiresApproval: try await SMAppService.mainApp.unregister()
                case .notRegistered, .notFound: try SMAppService.mainApp.register()
                @unknown default: throw CocoaError(.featureUnsupported)
                }
                notice = "Launch at login: reread the registration below. macOS may require approval in Login Items & Extensions."
            } catch { notice = "Could not change launch at login: \(error.localizedDescription)" }
            requestInFlight = nil
            refresh()
        }
    }

    func manage(_ permission: Permission) {
        if permission.id == .login {
            notice = "System Settings → General → Login Items & Extensions. Changes are checked when you return."
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        guard let destination = permission.settings else { return }
        let url = permission.id == .notifications
            ? "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
            : destination.urlString
        let path = permission.id == .notifications ? "System Settings → Notifications → MenuSprite" : destination.path
        let restartHint = [.camera, .microphone, .accessibility, .inputMonitoring, .screenRecording].contains(permission.id)
            ? " Use Quit & Reopen if macOS asks; access can remain effective until the app quits." : ""
        notice = "\(path). If the link opens the overview, navigate to this section. MenuSprite may appear only after requesting access." + restartHint
        guard let link = URL(string: url), NSWorkspace.shared.open(link) else {
            notice = "Could not open the section. Open \(path) manually."
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/System Settings.app"), configuration: .init())
            return
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.refresh() }
    }

    private func locationDescription(_ value: CLAuthorizationStatus) -> String {
        switch value {
        case .authorizedAlways: "Granted (always)"
        case .authorizedWhenInUse: "Granted (while in use)"
        default: StatusMapping.location(value).label
        }
    }
}

enum PermissionFilter: String, CaseIterable { case all = "All", granted = "Granted", used = "Used by MenuSprite" }

/// A one-shot, bounded status read. Late system replies cannot overwrite newer evidence.
private enum NotificationReader {
    private final class Reply: @unchecked Sendable {
        let lock = NSLock()
        var continuation: CheckedContinuation<Observation?, Never>?
        private var timeout: DispatchWorkItem?
        init(_ continuation: CheckedContinuation<Observation?, Never>) { self.continuation = continuation }
        func setTimeout(_ value: DispatchWorkItem) {
            lock.lock()
            timeout = value
            lock.unlock()
        }
        func finish(_ value: Observation?) {
            lock.lock()
            let pending = continuation
            let timer = timeout
            continuation = nil
            timeout = nil
            lock.unlock()
            timer?.cancel()
            pending?.resume(returning: value)
        }
    }
    static func read() async -> Observation? {
        await withCheckedContinuation { continuation in
            let reply = Reply(continuation)
            let timeout = DispatchWorkItem { reply.finish(nil) }
            reply.setTimeout(timeout)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeout)
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                func setting(_ value: UNNotificationSetting) -> String {
                    switch value {
                    case .enabled: "On"
                    case .disabled: "Off"
                    case .notSupported: "Not supported"
                    @unknown default: "Unknown"
                    }
                }
                reply.finish(Observation(StatusMapping.notifications(settings.authorizationStatus),
                    "Authorization is separate from delivery options and Focus suppression.", method: "UNUserNotificationCenter.getNotificationSettings",
                    resources: [.init("Alerts", setting(settings.alertSetting)), .init("Sounds", setting(settings.soundSetting)),
                                .init("Badges", setting(settings.badgeSetting)), .init("Notification Center", setting(settings.notificationCenterSetting)),
                                .init("Lock screen", setting(settings.lockScreenSetting))]))
            }
        }
    }
}
