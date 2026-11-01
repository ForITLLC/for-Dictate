import Foundation

enum RecordingDeviceChangeReason: Equatable, Sendable {
    case closedLid
    case deviceUnavailable
    case systemDefaultChanged
}

/// The hardware queue may inspect this flag without reading the manager's main-thread state.
final class RecordingDeviceChangeLease: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
    }

    func cancel() {
        lock.lock()
        valid = false
        lock.unlock()
    }
}

struct RecordingDeviceChangeRequest: Sendable {
    let id: UUID
    let sessionID: UUID
    let fallbackDeviceID: UInt32?
    let reason: RecordingDeviceChangeReason
    let lease: RecordingDeviceChangeLease
}

struct RecordingDeviceChangeIntent: Equatable, Sendable {
    let deviceID: UInt32?
    let reason: RecordingDeviceChangeReason
}

/// Value state belongs to the main thread. Only the cancellation lease crosses queues.
struct RecordingDeviceSession {
    private(set) var id = UUID()
    private(set) var isActive = false
    private(set) var isReady = false
    private(set) var activeDeviceID: UInt32?
    private(set) var pendingRequest: RecordingDeviceChangeRequest?
    private var deferredChange: RecordingDeviceChangeIntent?

    var isDeviceChangePending: Bool { pendingRequest != nil }

    @discardableResult
    mutating func beginSetup(deviceID: UInt32) -> UUID {
        stop()
        isActive = true
        activeDeviceID = deviceID
        return id
    }

    @discardableResult
    mutating func didStart(deviceID: UInt32, sessionID: UUID) -> Bool {
        guard isCurrentSession(sessionID) else { return false }
        activeDeviceID = deviceID
        isReady = true
        return true
    }

    mutating func stop() {
        pendingRequest?.lease.cancel()
        self = RecordingDeviceSession()
    }

    func isCurrentSession(_ sessionID: UUID) -> Bool {
        isActive && id == sessionID
    }

    func isCurrent(_ request: RecordingDeviceChangeRequest) -> Bool {
        matches(request) && isReady && request.lease.isValid
    }

    mutating func requestChange(
        to deviceID: UInt32?, reason: RecordingDeviceChangeReason
    ) -> RecordingDeviceChangeRequest? {
        guard isActive else { return nil }
        let intent = RecordingDeviceChangeIntent(deviceID: deviceID, reason: reason)
        guard isReady, pendingRequest == nil else {
            // Keep the last desired route, including a return to the current device.
            deferredChange = intent
            return nil
        }
        guard deviceID != activeDeviceID else { return nil }
        // An unavailable default is not an instruction to leave a still-working input.
        guard reason != .systemDefaultChanged || deviceID != nil else { return nil }

        let request = RecordingDeviceChangeRequest(
            id: UUID(), sessionID: id, fallbackDeviceID: deviceID,
            reason: reason, lease: RecordingDeviceChangeLease()
        )
        pendingRequest = request
        return request
    }

    @discardableResult
    mutating func finish(
        _ request: RecordingDeviceChangeRequest, activeDeviceID: UInt32? = nil
    ) -> Bool {
        // A canceled, already-running switch can still report the actual hardware device.
        guard matches(request) else { return false }
        if let activeDeviceID { self.activeDeviceID = activeDeviceID }
        let wasCanceled = !request.lease.isValid
        request.lease.cancel()
        pendingRequest = nil
        // Do not immediately retry an unchanged failing target or repeat a no-fallback alert.
        // A newly selected follow mode may retry work canceled by the previous mode.
        if !wasCanceled && deferredChange?.deviceID == request.fallbackDeviceID {
            deferredChange = nil
        }
        return true
    }

    mutating func takeDeferredChange() -> RecordingDeviceChangeIntent? {
        defer { deferredChange = nil }
        return deferredChange
    }

    mutating func cancelSystemDefaultChanges() {
        if pendingRequest?.reason == .systemDefaultChanged {
            pendingRequest?.lease.cancel()
        }
        if deferredChange?.reason == .systemDefaultChanged {
            deferredChange = nil
        }
    }

    private func matches(_ request: RecordingDeviceChangeRequest) -> Bool {
        isCurrentSession(request.sessionID) && pendingRequest?.id == request.id
    }
}
