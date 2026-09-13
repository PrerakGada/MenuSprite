import Testing
import Foundation
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
@testable import PermissionModel

@Test func completeCatalogWithoutDuplicates() {
    #expect(Set(PermissionCatalog.all.map(\.id)) == Set(PermissionID.allCases))
    #expect(PermissionCatalog.all.count == 36)
    #expect(Set(PermissionCatalog.all.map(\.id)).count == PermissionCatalog.all.count)
    #expect(PermissionCatalog.all.allSatisfy { !$0.purpose.isEmpty && !$0.explanation.isEmpty && !$0.usedBy.isEmpty })
}

@Test func privacyAndAppEnablementRemainSeparate() {
    #expect(PermissionCatalog.all.filter { !$0.isOtherAccess }.allSatisfy { $0.usedBy == "Not used by MenuSprite" })
    #expect(!AccessState.enabled.isGranted)
    #expect(!AccessState.notConfigured.isGranted)
    #expect(!AccessState.limited.isGranted)
    #expect(!AccessState.writeOnly.isGranted)
}

@Test func booleanChecksDoNotInventRequestHistory() {
    #expect(AccessState.preflight(false) == .notGranted)
    #expect(AccessState.preflight(false) != .notRequested)
    #expect(AccessState.preflight(true) == .granted)
}

@Test func unknownNeverOffersRequestOrBecomesDenial() {
    for permission in PermissionCatalog.all {
        #expect(!permission.canRequest(.unknown))
        #expect(!permission.canRequest(.restricted))
        #expect(!permission.canRequest(.unavailable))
        #expect(!permission.canRequest(.granted))
    }
    for id: PermissionID in [.fullDiskAccess, .localNetwork, .systemAudio, .automation, .tracking, .health, .passkeys, .pasteboard] {
        #expect(PermissionCatalog.all.first { $0.id == id }?.requestable == false)
    }
}

@Test func failedRefreshPreservesEvidenceAndTime() {
    let time = Date(timeIntervalSince1970: 100)
    let original = Observation(.limited, "Limited by OS", method: "test", checkedAt: time)
    let failed = original.failedRefresh("System service unavailable.")
    #expect(failed.state == .limited)
    #expect(failed.checkedAt == time)
    #expect(failed.stale)
    #expect(failed.detail.contains("System service unavailable"))
}

@Test func accessLevelsAndRestrictionsArePreserved() {
    // Synthetic cross-platform values test defensive mapping, not Mac availability.
    #expect(StatusMapping.contacts(CNAuthorizationStatus(rawValue: 4)!) == .limited)
    #expect(StatusMapping.contacts(.restricted) == .restricted)
    #expect(StatusMapping.events(.writeOnly) == .writeOnly)
    #expect(StatusMapping.events(.fullAccess) == .granted)
    #expect(StatusMapping.events(.restricted) == .restricted)
    #expect(StatusMapping.photos(.limited) == .limited)
    #expect(StatusMapping.photos(.restricted) == .restricted)
    #expect(StatusMapping.notifications(.provisional) == .limited)
    #expect(StatusMapping.notifications(UNAuthorizationStatus(rawValue: 4)!) == .limited)
}

@Test func neverRequestedAndDeniedMappings() {
    #expect(StatusMapping.capture(.notDetermined) == .notRequested)
    #expect(StatusMapping.capture(.denied) == .notGranted)
    #expect(StatusMapping.capture(.restricted) == .restricted)
    #expect(StatusMapping.contacts(.notDetermined) == .notRequested)
    #expect(StatusMapping.contacts(.denied) == .notGranted)
    #expect(StatusMapping.events(.notDetermined) == .notRequested)
    #expect(StatusMapping.events(.denied) == .notGranted)
    #expect(StatusMapping.photos(.notDetermined) == .notRequested)
    #expect(StatusMapping.photos(.denied) == .notGranted)
    #expect(StatusMapping.speech(.notDetermined) == .notRequested)
    #expect(StatusMapping.speech(.denied) == .notGranted)
    #expect(StatusMapping.bluetooth(.notDetermined) == .notRequested)
    #expect(StatusMapping.bluetooth(.restricted) == .restricted)
    #expect(StatusMapping.location(.notDetermined) == .notRequested)
    #expect(StatusMapping.location(.restricted) == .restricted)
    #expect(StatusMapping.focus(.notDetermined) == .notRequested)
    #expect(StatusMapping.focus(.denied) == .notGranted)
    #expect(StatusMapping.music(.notDetermined) == .notRequested)
    #expect(StatusMapping.music(.restricted) == .restricted)
    #expect(StatusMapping.notifications(.notDetermined) == .notRequested)
    #expect(StatusMapping.notifications(.denied) == .notGranted)
}

@Test func serviceStatesAreNotPrivacyGrants() {
    #expect(StatusMapping.login(.enabled) == .enabled)
    #expect(StatusMapping.login(.notRegistered) == .notRegistered)
    #expect(StatusMapping.login(.requiresApproval) == .requiresApproval)
    #expect(StatusMapping.login(.notFound) == .notFound)
}

@Test func clipboardHasBehaviorNotGenericAuthorization() {
    #expect(StatusMapping.pasteboard(.default) == .pasteboardDefault)
    #expect(StatusMapping.pasteboard(.ask) == .pasteboardAsk)
    #expect(StatusMapping.pasteboard(.alwaysAllow) == .pasteboardAllow)
    #expect(StatusMapping.pasteboard(.alwaysDeny) == .pasteboardDeny)
}

@Test func newSDKValuesStayUnknown() {
    #expect(StatusMapping.capture(AVAuthorizationStatus(rawValue: 999)!) == .unknown)
    #expect(StatusMapping.contacts(CNAuthorizationStatus(rawValue: 999)!) == .unknown)
    #expect(StatusMapping.events(EKAuthorizationStatus(rawValue: 999)!) == .unknown)
    #expect(StatusMapping.photos(PHAuthorizationStatus(rawValue: 999)!) == .unknown)
    #expect(StatusMapping.notifications(UNAuthorizationStatus(rawValue: 999)!) == .unknown)
    #expect(StatusMapping.login(SMAppService.Status(rawValue: 999)!) == .unknown)
}
