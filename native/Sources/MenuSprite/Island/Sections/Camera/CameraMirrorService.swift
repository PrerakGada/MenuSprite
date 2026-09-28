import AppKit
import AVFoundation
import IslandKit

struct CameraChoice: Identifiable, Hashable {
    let id: String
    let name: String
}

/// A capture session crossing between the main actor and the session queue. Every change to the
/// session itself happens on that queue.
final class CameraSessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
}

/// The newest start's generation, readable from the session queue, so a configuration still queued
/// after a stop never touches the camera.
final class CameraToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func set(_ generation: Int) { lock.withLock { value = generation } }
    func isCurrent(_ generation: Int) -> Bool { lock.withLock { value == generation } }
}

/// The live mirror behind the Camera page. The session is created when the person presses Open camera
/// and destroyed when they stop it or leave the page, so the camera light and every resource go with
/// it; device and session observers exist only meanwhile. Nothing here runs at rest, and nothing asks
/// for camera access except that press. Decisions come from `CameraMirrorMachine`.
@MainActor
final class CameraMirrorService: ObservableObject {
    @Published private(set) var status: CameraMirrorStatus = .off
    @Published private(set) var cameras: [CameraChoice] = []
    @Published private(set) var currentID: String?
    /// The running session, for the preview layer.
    @Published private(set) var session: AVCaptureSession?
    @Published private(set) var access: CameraAuthorization = .notDetermined

    private var machine = CameraMirrorMachine()
    private var box: CameraSessionBox?
    private let token = CameraToken()
    private let queue = DispatchQueue(label: "in.prerakgada.MenuSprite.camera-mirror", qos: .userInitiated)
    private var deviceObservers: [NSObjectProtocol] = []
    private var sessionObservers: [NSObjectProtocol] = []
    private var promptHeld = false
    private let hold: (Bool) -> Void
    /// Renders: a fixed state and never AVFoundation.
    let preview: CameraPreviewData?
    private let headless: Bool

    init(hold: @escaping (Bool) -> Void, headless: Bool, preview: CameraPreviewData?) {
        self.hold = hold
        self.headless = headless
        self.preview = preview
        if let preview {
            status = preview.status
            cameras = preview.cameras
            currentID = preview.cameras.first?.id
            access = preview.access
        }
    }

    var currentName: String? { cameras.first { $0.id == currentID }?.name }

    // MARK: Actions

    /// Open camera (or retry). Asks for access only when the person has never answered.
    func open() {
        guard !headless else { return }
        refreshCameras()
        run(machine.open(authorization: Self.authorization(), devices: cameras.map(\.id), preferred: Self.preferredID()))
        installDeviceObservers()
    }

    func stop() {
        guard machine.isPresented else { return }
        run(machine.stop())
        removeDeviceObservers()
    }

    /// A camera chosen from the menu: switched live and remembered as the system's preferred camera.
    func pick(_ id: String) {
        guard !headless else { return }
        run(machine.pick(id, devices: cameras.map(\.id)))
    }

    /// Settings › Content › Camera mirror: reads the current answer (never asks).
    func refreshAccess() {
        guard preview == nil, !headless else { return }
        access = Self.authorization()
    }

    /// The Allow button in Settings: the only other place that may ask.
    func requestAccessFromSettings() {
        guard preview == nil, !headless else { return }
        AVCaptureDevice.requestAccess(for: .video) { @Sendable [weak self] _ in
            Task { @MainActor in self?.refreshAccess() }
        }
    }

    func openPrivacySettings() {
        guard !headless, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Effects

    private func run(_ effects: [CameraMirrorMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .requestAccess(let generation): requestAccess(generation)
            case .configure(let device, let generation): configure(device, generation: generation)
            case .stopSession: stopSession()
            case .setPreferred(let id): AVCaptureDevice.userPreferredCamera = AVCaptureDevice(uniqueID: id)
            }
        }
        status = machine.status
        currentID = machine.device
    }

    /// While the system's question is up, and for a second after, the island stays open: the prompt
    /// activating and the previous app returning must not tear the mirror down mid-question.
    private func requestAccess(_ generation: Int) {
        setPromptHold(true)
        AVCaptureDevice.requestAccess(for: .video) { @Sendable [weak self] granted in
            Task { @MainActor in self?.accessAnswered(granted, generation: generation) }
        }
    }

    private func accessAnswered(_ granted: Bool, generation: Int) {
        access = Self.authorization()
        refreshCameras()
        run(machine.accessAnswered(granted, generation: generation, devices: cameras.map(\.id), preferred: Self.preferredID()))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.setPromptHold(false)
        }
    }

    private func setPromptHold(_ on: Bool) {
        guard promptHeld != on else { return }
        promptHeld = on
        hold(on)
    }

    private func configure(_ deviceID: String, generation: Int) {
        token.set(generation)
        let box = CameraSessionBox()
        let token = token
        queue.async { [weak self] in
            guard token.isCurrent(generation) else { return }
            let session = box.session
            session.beginConfiguration()
            if session.canSetSessionPreset(.medium) { session.sessionPreset = .medium }
            var added = false
            if let device = AVCaptureDevice(uniqueID: deviceID), let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
                added = true
            }
            session.commitConfiguration()
            if added, token.isCurrent(generation) { session.startRunning() }
            let running = added && session.isRunning
            if !running { Self.tearDown(box) }
            Task { @MainActor in self?.configured(running, box: box, generation: generation) }
        }
    }

    private func configured(_ running: Bool, box: CameraSessionBox, generation: Int) {
        guard generation == machine.generation else {
            // A start that finished after a stop or a newer start: shut it without showing it.
            if running { queue.async { Self.tearDown(box) } }
            return
        }
        if running {
            self.box = box
            session = box.session
            installSessionObservers(box.session, generation: generation)
        }
        run(machine.configured(success: running, generation: generation))
    }

    private func sessionFailed(generation: Int) {
        run(machine.failed(generation: generation))
    }

    private func stopSession() {
        token.set(machine.generation)
        removeSessionObservers()
        session = nil
        guard let box else { return }
        self.box = nil
        queue.async { Self.tearDown(box) }
    }

    nonisolated private static func tearDown(_ box: CameraSessionBox) {
        let session = box.session
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        session.commitConfiguration()
    }

    // MARK: Devices and observers

    private func refreshCameras() {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                         mediaType: .video, position: .unspecified)
        cameras = discovery.devices.map { CameraChoice(id: $0.uniqueID, name: $0.localizedName) }
    }

    private func devicesChanged() {
        guard machine.isPresented else { return }
        refreshCameras()
        run(machine.devicesChanged(cameras.map(\.id), preferred: Self.preferredID()))
    }

    private func installDeviceObservers() {
        guard deviceObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            deviceObservers.append(center.addObserver(forName: name, object: nil, queue: nil) { @Sendable [weak self] _ in
                Task { @MainActor in self?.devicesChanged() }
            })
        }
    }

    private func removeDeviceObservers() {
        deviceObservers.forEach(NotificationCenter.default.removeObserver)
        deviceObservers = []
    }

    private func installSessionObservers(_ session: AVCaptureSession, generation: Int) {
        removeSessionObservers()
        let center = NotificationCenter.default
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            sessionObservers.append(center.addObserver(forName: name, object: session, queue: nil) { @Sendable [weak self] _ in
                Task { @MainActor in self?.sessionFailed(generation: generation) }
            })
        }
    }

    private func removeSessionObservers() {
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
        sessionObservers = []
    }

    static func authorization() -> CameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    private static func preferredID() -> String? { AVCaptureDevice.userPreferredCamera?.uniqueID }
}

/// Harness-only states, so the page renders without the camera or a permission check:
/// `MenuSprite --island-render <dir> --section camera --camera-preview <state>`. Headless only.
struct CameraPreviewData {
    enum State: String {
        case start, waiting, live, cameras, denied, unavailable, none
    }

    let state: State

    static func requested() -> CameraPreviewData? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--camera-preview"), arguments.indices.contains(index + 1),
              let state = State(rawValue: arguments[index + 1]) else { return nil }
        return CameraPreviewData(state: state)
    }

    var status: CameraMirrorStatus {
        switch state {
        case .start: .off
        case .waiting: .waitingForPermission
        case .live, .cameras: .running
        case .denied: .denied
        case .unavailable: .unavailable
        case .none: .noCamera
        }
    }

    var cameras: [CameraChoice] {
        switch state {
        case .cameras: [CameraChoice(id: "a", name: "MacBook Pro Camera"), CameraChoice(id: "b", name: "iPhone Camera")]
        case .live: [CameraChoice(id: "a", name: "MacBook Pro Camera")]
        default: []
        }
    }

    var access: CameraAuthorization { state == .denied ? .denied : (state == .waiting || state == .start ? .notDetermined : .authorized) }
}
