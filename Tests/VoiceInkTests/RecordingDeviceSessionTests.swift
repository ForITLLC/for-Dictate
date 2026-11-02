import Foundation
import XCTest
@testable import VoiceInk

/// Exercises the exact Foundation-only session used by AudioDeviceManager. No recorder,
/// hardware listener, app singleton, audio file, microphone or UserDefaults is instantiated.
final class RecordingDeviceSessionTests: XCTestCase {
    private let microphoneA: UInt32 = 10
    private let microphoneB: UInt32 = 20
    private let microphoneC: UInt32 = 30

    private func readySession(on device: UInt32) -> RecordingDeviceSession {
        var session = RecordingDeviceSession()
        let id = session.beginSetup(deviceID: device)
        XCTAssertTrue(session.didStart(deviceID: device, sessionID: id))
        return session
    }

    func testSetupDefersLatestDesiredRouteUntilRecordingActuallyStarts() throws {
        var session = RecordingDeviceSession()
        let id = session.beginSetup(deviceID: microphoneA)
        XCTAssertTrue(session.isActive)
        XCTAssertFalse(session.isReady)
        XCTAssertNil(session.requestChange(to: microphoneB, reason: .systemDefaultChanged))
        XCTAssertNil(session.requestChange(to: microphoneC, reason: .systemDefaultChanged))
        XCTAssertFalse(session.isDeviceChangePending)
        XCTAssertTrue(session.didStart(deviceID: microphoneA, sessionID: id))
        let desired = try XCTUnwrap(session.takeDeferredChange())
        XCTAssertEqual(desired.deviceID, microphoneC)
        XCTAssertEqual(desired.reason, .systemDefaultChanged)
        let request = try XCTUnwrap(session.requestChange(to: desired.deviceID, reason: desired.reason))
        XCTAssertEqual(request.fallbackDeviceID, microphoneC)
        XCTAssertTrue(session.isCurrent(request))
    }

    func testSystemDefaultAlreadyActiveAndDuplicateEventsDoNotSwitch() {
        var session = readySession(on: microphoneA)
        XCTAssertNil(session.requestChange(to: microphoneA, reason: .systemDefaultChanged))
        XCTAssertNil(session.requestChange(to: microphoneA, reason: .systemDefaultChanged))
        XCTAssertFalse(session.isDeviceChangePending)
        XCTAssertEqual(session.activeDeviceID, microphoneA)
        XCTAssertNil(session.takeDeferredChange())
    }

    func testRapidDefaultChangesConvergeToNewestTargetAfterOnePendingSwitch() throws {
        var session = readySession(on: microphoneA)
        let first = try XCTUnwrap(session.requestChange(to: microphoneB, reason: .systemDefaultChanged))
        XCTAssertNil(session.requestChange(to: microphoneC, reason: .systemDefaultChanged))
        XCTAssertEqual(session.pendingRequest?.id, first.id)
        XCTAssertEqual(session.activeDeviceID, microphoneA)
        XCTAssertTrue(session.finish(first, activeDeviceID: microphoneB))
        XCTAssertEqual(session.activeDeviceID, microphoneB)
        let desired = try XCTUnwrap(session.takeDeferredChange())
        XCTAssertEqual(desired.deviceID, microphoneC)
        XCTAssertNil(session.takeDeferredChange(), "A deferred route is consumed once.")
        let final = try XCTUnwrap(session.requestChange(to: desired.deviceID, reason: desired.reason))
        XCTAssertNotEqual(first.id, final.id)
        XCTAssertTrue(session.finish(final, activeDeviceID: microphoneC))
        XCTAssertEqual(session.activeDeviceID, microphoneC)
        XCTAssertFalse(session.isDeviceChangePending)
        XCTAssertNil(session.takeDeferredChange())
    }

    func testDuplicatePendingTargetIsConsumedWithoutASecondSwitch() throws {
        var session = readySession(on: microphoneA)
        let request = try XCTUnwrap(session.requestChange(to: microphoneB, reason: .systemDefaultChanged))
        for _ in 0..<3 {
            XCTAssertNil(session.requestChange(to: microphoneB, reason: .systemDefaultChanged))
        }
        XCTAssertTrue(session.finish(request, activeDeviceID: microphoneB))
        XCTAssertNil(session.takeDeferredChange())
        XCTAssertNil(session.requestChange(to: microphoneB, reason: .systemDefaultChanged))

        // A return to the currently active input is meaningful while a different
        // hardware switch is pending: once that switch ends, route back once.
        let away = try XCTUnwrap(session.requestChange(to: microphoneC, reason: .systemDefaultChanged))
        XCTAssertNil(session.requestChange(to: microphoneB, reason: .systemDefaultChanged))
        XCTAssertTrue(session.finish(away, activeDeviceID: microphoneC))
        let returnRoute = try XCTUnwrap(session.takeDeferredChange())
        XCTAssertEqual(returnRoute.deviceID, microphoneB)
        let back = try XCTUnwrap(session.requestChange(to: returnRoute.deviceID, reason: returnRoute.reason))
        XCTAssertTrue(session.finish(back, activeDeviceID: microphoneB))
        XCTAssertNil(session.takeDeferredChange())
    }

    func testStopInvalidatesPendingLeaseAndCompletion() throws {
        var session = readySession(on: microphoneA)
        let request = try XCTUnwrap(session.requestChange(to: microphoneB, reason: .systemDefaultChanged))
        XCTAssertTrue(request.lease.isValid)
        session.stop()
        XCTAssertFalse(request.lease.isValid)
        XCTAssertFalse(session.isCurrent(request))
        XCTAssertFalse(session.finish(request, activeDeviceID: microphoneB))
        XCTAssertFalse(session.isActive)
        XCTAssertFalse(session.isReady)
        XCTAssertFalse(session.isDeviceChangePending)
        XCTAssertNil(session.activeDeviceID)
        XCTAssertNil(session.takeDeferredChange())
    }

    func testOldSessionCompletionCannotOverwriteNewRecordingOrPendingRequest() throws {
        var session = readySession(on: microphoneA)
        let old = try XCTUnwrap(session.requestChange(to: microphoneB, reason: .systemDefaultChanged))
        session.stop()
        let newID = session.beginSetup(deviceID: microphoneC)
        XCTAssertNotEqual(old.sessionID, newID)
        XCTAssertTrue(session.didStart(deviceID: microphoneC, sessionID: newID))
        let current = try XCTUnwrap(session.requestChange(to: microphoneA, reason: .systemDefaultChanged))
        XCTAssertFalse(session.finish(old, activeDeviceID: microphoneB))
        XCTAssertEqual(session.activeDeviceID, microphoneC)
        XCTAssertEqual(session.pendingRequest?.id, current.id)
        XCTAssertTrue(session.isCurrent(current))
    }

    func testStaleStartCompletionCannotMarkNewSetupReady() {
        var session = RecordingDeviceSession()
        let previous = session.beginSetup(deviceID: microphoneA)
        session.stop()
        let current = session.beginSetup(deviceID: microphoneC)
        XCTAssertFalse(session.didStart(deviceID: microphoneA, sessionID: previous))
        XCTAssertFalse(session.isReady)
        XCTAssertTrue(session.didStart(deviceID: microphoneC, sessionID: current))
        XCTAssertTrue(session.isReady)
        XCTAssertEqual(session.activeDeviceID, microphoneC)
    }

    func testCancelledDefaultLeaseCannotExecuteButCanFinishActualHardwareResult() throws {
        var session = readySession(on: microphoneA)
        let request = try XCTUnwrap(session.requestChange(to: microphoneB, reason: .systemDefaultChanged))
        XCTAssertNil(session.requestChange(to: microphoneC, reason: .systemDefaultChanged))
        session.cancelSystemDefaultChanges()
        XCTAssertFalse(request.lease.isValid)
        XCTAssertFalse(session.isCurrent(request))
        request.lease.cancel() // Cancelling an already invalid lease is harmless.
        XCTAssertFalse(request.lease.isValid)
        // A hardware switch that finished before cancellation must still report reality.
        XCTAssertTrue(session.finish(request, activeDeviceID: microphoneB))
        XCTAssertEqual(session.activeDeviceID, microphoneB)
        XCTAssertFalse(session.isDeviceChangePending)
        XCTAssertNil(session.takeDeferredChange())
    }

    func testLeavingSystemDefaultDoesNotCancelNecessaryDeviceLossFallback() throws {
        var session = readySession(on: microphoneA)
        let fallback = try XCTUnwrap(session.requestChange(to: microphoneB, reason: .deviceUnavailable))
        session.cancelSystemDefaultChanges()
        XCTAssertTrue(fallback.lease.isValid)
        XCTAssertTrue(session.isCurrent(fallback))
        XCTAssertTrue(session.finish(fallback, activeDeviceID: microphoneB))
        XCTAssertEqual(session.activeDeviceID, microphoneB)
    }

    func testReenteringFollowModeKeepsSameTargetAfterCancelledRequestFinishes() throws {
        var session = readySession(on: microphoneA)
        let cancelled = try XCTUnwrap(session.requestChange(to: microphoneB, reason: .systemDefaultChanged))
        session.cancelSystemDefaultChanges()
        XCTAssertFalse(cancelled.lease.isValid)
        XCTAssertFalse(session.isCurrent(cancelled))

        // Follow mode is selected again before the hardware queue acknowledges the
        // cancelled ticket. Its latest desired route must survive that acknowledgement.
        XCTAssertNil(session.requestChange(to: microphoneB, reason: .systemDefaultChanged))
        XCTAssertTrue(session.finish(cancelled, activeDeviceID: microphoneA))
        XCTAssertEqual(session.activeDeviceID, microphoneA)
        let desired = try XCTUnwrap(session.takeDeferredChange())
        XCTAssertEqual(desired.deviceID, microphoneB)
        XCTAssertEqual(desired.reason, .systemDefaultChanged)
        let fresh = try XCTUnwrap(session.requestChange(to: desired.deviceID, reason: desired.reason))
        XCTAssertNotEqual(fresh.id, cancelled.id)
        XCTAssertTrue(fresh.lease.isValid)
        XCTAssertTrue(session.isCurrent(fresh))
        XCTAssertFalse(cancelled.lease.isValid)
        XCTAssertTrue(session.finish(fresh, activeDeviceID: microphoneB))
        XCTAssertEqual(session.activeDeviceID, microphoneB)
        XCTAssertNil(session.takeDeferredChange())
    }

    func testFailedTargetDoesNotImmediatelyRetryTheSameDeferredTarget() throws {
        var session = readySession(on: microphoneA)
        let request = try XCTUnwrap(session.requestChange(to: microphoneB, reason: .systemDefaultChanged))
        XCTAssertNil(session.requestChange(to: microphoneB, reason: .systemDefaultChanged))
        XCTAssertTrue(session.finish(request))
        XCTAssertEqual(session.activeDeviceID, microphoneA, "Failure must not claim the rejected target became active.")
        XCTAssertFalse(session.isDeviceChangePending)
        XCTAssertNil(session.takeDeferredChange(), "A failed target cannot cause an automatic retry loop.")
    }

    func testFailureStillRetainsADifferentNewerDesiredTarget() throws {
        var session = readySession(on: microphoneA)
        let request = try XCTUnwrap(session.requestChange(to: microphoneB, reason: .systemDefaultChanged))
        XCTAssertNil(session.requestChange(to: microphoneC, reason: .systemDefaultChanged))
        XCTAssertTrue(session.finish(request))
        XCTAssertEqual(session.activeDeviceID, microphoneA)
        let desired = try XCTUnwrap(session.takeDeferredChange())
        XCTAssertEqual(desired.deviceID, microphoneC)
        let next = try XCTUnwrap(session.requestChange(to: desired.deviceID, reason: desired.reason))
        XCTAssertTrue(session.isCurrent(next))
    }

    func testMissingDefaultDoesNotInterruptCurrentInputButMissingFallbackIsExplicit() throws {
        var session = readySession(on: microphoneA)
        XCTAssertNil(session.requestChange(to: nil, reason: .systemDefaultChanged))
        XCTAssertEqual(session.activeDeviceID, microphoneA)
        let missing = try XCTUnwrap(session.requestChange(to: nil, reason: .closedLid))
        XCTAssertNil(missing.fallbackDeviceID)
        XCTAssertTrue(session.isCurrent(missing))
        XCTAssertNil(session.requestChange(to: nil, reason: .closedLid))
        XCTAssertTrue(session.finish(missing))
        XCTAssertEqual(session.activeDeviceID, microphoneA)
        XCTAssertNil(session.takeDeferredChange(), "An unavailable fallback is reported once, not retried indefinitely.")
    }
}
