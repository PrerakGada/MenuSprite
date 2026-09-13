import Foundation
import Testing
@testable import PowerControl

@Test func manualExpiryAndSleepClearOnlyTheManualSession() {
    var session = AwakeSession()
    let now = Date(timeIntervalSince1970: 100)
    session.start(duration: 10, now: now)
    session.expire(now: now.addingTimeInterval(9)); #expect(session.manual)
    session.expire(now: now.addingTimeInterval(10)); #expect(!session.manual && session.deadline == nil)
    #expect(session.pauseReason(locked:false,pauseWhenLocked:true,acOnly:false,externalPower:nil) == nil)
    session.start(duration: 10, now: now); session.sleep()
    #expect(!session.manual && session.deadline == nil)
    #expect(session.pauseReason(locked:false,pauseWhenLocked:false,acOnly:false,externalPower:true) != nil)
    session.wake()
    #expect(!session.manual && session.pauseReason(locked:false,pauseWhenLocked:false,acOnly:false,externalPower:true) == nil)
}
@Test func inactiveLockedAndUnknownPowerStatesPauseAwakeRequests() {
    var session = AwakeSession(); session.start(duration: 0)
    session.sessionActive = false
    #expect(session.pauseReason(locked:false,pauseWhenLocked:false,acOnly:false,externalPower:true) != nil)
    session.sessionActive = true
    #expect(session.pauseReason(locked:true,pauseWhenLocked:true,acOnly:false,externalPower:true) != nil)
    #expect(session.pauseReason(locked:true,pauseWhenLocked:false,acOnly:false,externalPower:true) == nil)
    for external in [false, nil] as [Bool?] {
        #expect(session.pauseReason(locked:false,pauseWhenLocked:false,acOnly:true,externalPower:external) != nil)
    }
    #expect(session.pauseReason(locked:false,pauseWhenLocked:false,acOnly:true,externalPower:true) == nil)
}
