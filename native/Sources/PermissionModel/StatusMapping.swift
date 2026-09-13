import AVFoundation
import Contacts
import EventKit
import Photos
import Speech
import CoreBluetooth
import CoreLocation
import Intents
import MusicKit
import UserNotifications
import ServiceManagement
import AppKit

/// Pure mappings: never read data or invoke consent. Unrecognized future values stay unknown.
public enum StatusMapping {
    public static func capture(_ value: AVAuthorizationStatus) -> AccessState {
        switch value {
        case .authorized: .granted
        case .denied: .notGranted
        case .notDetermined: .notRequested
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }
    public static func contacts(_ value: CNAuthorizationStatus) -> AccessState {
        switch value {
        case .authorized: .granted
        case .limited: .limited
        case .denied: .notGranted
        case .notDetermined: .notRequested
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }
    public static func events(_ value: EKAuthorizationStatus) -> AccessState {
        // .authorized is the deprecated alias of .fullAccess.
        switch value {
        case .fullAccess: .granted
        case .writeOnly: .writeOnly
        case .denied: .notGranted
        case .notDetermined: .notRequested
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }
    public static func photos(_ value: PHAuthorizationStatus) -> AccessState {
        switch value {
        case .authorized: .granted
        case .limited: .limited
        case .denied: .notGranted
        case .notDetermined: .notRequested
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }
    public static func speech(_ value: SFSpeechRecognizerAuthorizationStatus) -> AccessState {
        switch value {
        case .authorized: .granted
        case .denied: .notGranted
        case .notDetermined: .notRequested
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }
    public static func bluetooth(_ value: CBManagerAuthorization) -> AccessState {
        switch value {
        case .allowedAlways: .granted
        case .denied: .notGranted
        case .notDetermined: .notRequested
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }
    public static func location(_ value: CLAuthorizationStatus) -> AccessState {
        switch value {
        case .authorizedAlways, .authorizedWhenInUse: .granted
        case .denied: .notGranted
        case .notDetermined: .notRequested
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }
    public static func focus(_ value: INFocusStatusAuthorizationStatus) -> AccessState {
        switch value {
        case .authorized: .granted
        case .denied: .notGranted
        case .notDetermined: .notRequested
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }
    public static func music(_ value: MusicAuthorization.Status) -> AccessState {
        switch value {
        case .authorized: .granted
        case .denied: .notGranted
        case .notDetermined: .notRequested
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }
    public static func notifications(_ value: UNAuthorizationStatus) -> AccessState {
        switch value {
        case .authorized: .granted
        case .provisional, .ephemeral: .limited
        case .denied: .notGranted
        case .notDetermined: .notRequested
        @unknown default: .unknown
        }
    }
    public static func login(_ value: SMAppService.Status) -> AccessState {
        switch value {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }
    public static func pasteboard(_ value: NSPasteboard.AccessBehavior) -> AccessState {
        switch value {
        case .default: .pasteboardDefault
        case .ask: .pasteboardAsk
        case .alwaysAllow: .pasteboardAllow
        case .alwaysDeny: .pasteboardDeny
        @unknown default: .unknown
        }
    }
}
