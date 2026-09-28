import CoreGraphics
import Foundation

/// The Camera mirror page's measurements: a 4:3 preview that fits beside a 28-pt Stop button row
/// 10 pt below it, so the button stays inside the page in short islands too.
public enum CameraMirrorLayout {
    public static let controlsHeight: CGFloat = 28
    public static let controlsGap: CGFloat = 10

    public static func previewSize(pageWidth: CGFloat, pageHeight: CGFloat) -> CGSize {
        let height = max(0, min(pageHeight - controlsHeight - controlsGap, pageWidth * 3 / 4))
        return CGSize(width: height * 4 / 3, height: height)
    }
}

public enum CameraMirrorStatus: Sendable, Equatable {
    /// Not started: the start card shows.
    case off
    case waitingForPermission
    case starting
    case running
    case denied
    /// The session failed or was interrupted.
    case unavailable
    case noCamera

    /// Everything except the start card draws inside the preview frame.
    public var showsPreviewFrame: Bool { self != .off }
}

public enum CameraAuthorization: Sendable, Equatable {
    case authorized, notDetermined, denied
}

/// The mirror's decisions, free of AVFoundation. Every start bumps a generation; answers and
/// configurations that belong to an older generation change nothing, so a permission reply or a
/// slow start can never reopen a camera the person already stopped. Only an explicit pick records
/// the preferred camera; falling back after an unplug never does.
public struct CameraMirrorMachine: Sendable, Equatable {
    public enum Effect: Sendable, Equatable {
        case requestAccess(generation: Int)
        case configure(device: String, generation: Int)
        case stopSession
        case setPreferred(String)
    }

    public private(set) var status: CameraMirrorStatus = .off
    public private(set) var generation = 0
    public private(set) var device: String?

    public init() {}

    public var isPresented: Bool { status != .off }

    /// "Open camera" (or a retry).
    public mutating func open(authorization: CameraAuthorization, devices: [String], preferred: String?) -> [Effect] {
        var effects: [Effect] = isPresented ? [.stopSession] : []
        generation += 1
        switch authorization {
        case .denied:
            status = .denied
        case .notDetermined:
            status = .waitingForPermission
            effects.append(.requestAccess(generation: generation))
        case .authorized:
            effects += configure(devices: devices, preferred: preferred)
        }
        return effects
    }

    public mutating func accessAnswered(_ granted: Bool, generation answer: Int, devices: [String], preferred: String?) -> [Effect] {
        guard answer == generation, status == .waitingForPermission else { return [] }
        guard granted else { status = .denied; return [] }
        return configure(devices: devices, preferred: preferred)
    }

    /// The session queue finished configuring for `generation`.
    public mutating func configured(success: Bool, generation answer: Int) -> [Effect] {
        guard answer == generation, status == .starting else { return [] }
        if success { status = .running; return [] }
        status = .unavailable
        return [.stopSession]
    }

    /// A runtime error or interruption on the current session.
    public mutating func failed(generation answer: Int) -> [Effect] {
        guard answer == generation, status == .running || status == .starting else { return [] }
        status = .unavailable
        return [.stopSession]
    }

    /// Stop camera, leaving the page, or anything else that ends the mirror.
    public mutating func stop() -> [Effect] {
        guard isPresented else { return [] }
        generation += 1
        status = .off
        device = nil
        return [.stopSession]
    }

    /// The person chose a camera from the menu: switch live and remember it as preferred.
    public mutating func pick(_ id: String, devices: [String]) -> [Effect] {
        guard devices.contains(id), isPresented, status != .denied, status != .waitingForPermission else { return [] }
        generation += 1
        device = id
        status = .starting
        return [.stopSession, .setPreferred(id), .configure(device: id, generation: generation)]
    }

    /// Cameras came or went. An unplugged camera falls back to the first one left (without touching
    /// the preferred camera); with none left the page says so; a camera arriving while it says so starts.
    public mutating func devicesChanged(_ devices: [String], preferred: String?) -> [Effect] {
        switch status {
        case .noCamera where !devices.isEmpty:
            generation += 1
            return configure(devices: devices, preferred: preferred)
        case .running, .starting, .unavailable:
            guard let device, !devices.contains(device) else { return [] }
            generation += 1
            guard let fallback = devices.first else {
                status = .noCamera
                self.device = nil
                return [.stopSession]
            }
            self.device = fallback
            status = .starting
            return [.stopSession, .configure(device: fallback, generation: generation)]
        default:
            return []
        }
    }

    private mutating func configure(devices: [String], preferred: String?) -> [Effect] {
        guard let chosen = preferred.flatMap({ devices.contains($0) ? $0 : nil }) ?? devices.first else {
            status = .noCamera
            device = nil
            return []
        }
        device = chosen
        status = .starting
        return [.configure(device: chosen, generation: generation)]
    }
}
