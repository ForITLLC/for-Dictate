import CoreAudio
import Foundation
import os

struct RecordingDeviceResolution {
    let deviceID: AudioDeviceID?
    let internalMicrophoneBlockedByClosedLid: Bool
    let fellBackFromClosedInternalMicrophone: Bool
}

extension AudioDeviceManager {
    func setupRecordingDeviceRouting() {
        clamshellStateMonitor = ClamshellStateMonitor { [weak self] isClosed in
            self?.handleClamshellChange(isClosed: isClosed)
        }
    }

    @discardableResult
    func beginRecordingSetup(deviceID: AudioDeviceID) -> UUID {
        recordingDeviceSession.beginSetup(deviceID: deviceID)
    }

    @discardableResult
    func recordingDidStart(deviceID: AudioDeviceID, sessionID: UUID) -> Bool {
        guard recordingDeviceSession.didStart(deviceID: deviceID, sessionID: sessionID) else {
            return false
        }
        // Default/lid/device changes during AUHAL setup must use the latest route now.
        _ = recordingDeviceSession.takeDeferredChange()
        reconcileRecordingDeviceRouting()
        return true
    }

    func isCurrentRecordingSession(_ sessionID: UUID) -> Bool {
        recordingDeviceSession.isCurrentSession(sessionID)
    }

    func isCurrent(_ request: RecordingDeviceChangeRequest) -> Bool {
        recordingDeviceSession.isCurrent(request)
    }

    @discardableResult
    func finish(
        _ request: RecordingDeviceChangeRequest, activeDeviceID: AudioDeviceID? = nil
    ) -> Bool {
        let wasCanceled = !request.lease.isValid
        guard recordingDeviceSession.finish(request, activeDeviceID: activeDeviceID) else {
            return false
        }
        if recordingDeviceSession.takeDeferredChange() != nil {
            // Re-read Core Audio rather than applying the device captured by an older callback.
            reconcileRecordingDeviceRouting(suppressingTargetOf: wasCanceled ? nil : request)
        }
        return true
    }

    func recordingDidStop() {
        recordingDeviceSession.stop()
    }

    func resolveCurrentRecordingDevice(
        excluding excludedDeviceID: AudioDeviceID? = nil
    ) -> RecordingDeviceResolution {
        let preferredCandidates = preferredRecordingDeviceIDs()
        let preferredAvailableDevice = preferredCandidates.first(where: isOperationalInputDevice)
        let internalMicrophoneBlockedByClosedLid = isClamshellClosed
            && preferredAvailableDevice.map(isInternalMicrophone) == true

        var seen = Set<AudioDeviceID>()
        let candidates = (preferredCandidates + fallbackRecordingDeviceIDs()).filter { deviceID in
            guard deviceID != excludedDeviceID else { return false }
            return seen.insert(deviceID).inserted
        }
        let resolvedDeviceID = candidates.first(where: isDeviceUsableForRecording)

        return RecordingDeviceResolution(
            deviceID: resolvedDeviceID,
            internalMicrophoneBlockedByClosedLid: internalMicrophoneBlockedByClosedLid,
            fellBackFromClosedInternalMicrophone: internalMicrophoneBlockedByClosedLid
                && resolvedDeviceID != preferredAvailableDevice
        )
    }

    func getCurrentDevice() -> AudioDeviceID {
        resolveCurrentRecordingDevice().deviceID ?? 0
    }

    func findBestAvailableDevice() -> AudioDeviceID? {
        fallbackRecordingDeviceIDs().first(where: isDeviceUsableForRecording)
    }

    func isDeviceUsableForRecording(_ deviceID: AudioDeviceID) -> Bool {
        isOperationalInputDevice(deviceID)
            && !(isClamshellClosed && isInternalMicrophone(deviceID))
    }

    private func preferredRecordingDeviceIDs() -> [AudioDeviceID] {
        switch inputMode {
        case .systemDefault:
            return getSystemDefaultDevice().map { [$0] } ?? []
        case .custom:
            let savedUID = UserDefaults.standard.selectedAudioDeviceUID ?? ""
            let savedModelUID = UserDefaults.standard.selectedAudioDeviceModelUID
            var candidates = findAvailableDevice(uid: savedUID, modelUID: savedModelUID).map { [$0.id] } ?? []
            if let selectedDeviceID, !candidates.contains(selectedDeviceID) {
                candidates.append(selectedDeviceID)
            }
            return candidates
        case .prioritized:
            return prioritizedDevices.sorted { $0.priority < $1.priority }.compactMap { device in
                findAvailableDevice(uid: device.id, modelUID: device.modelUID)?.id
            }
        }
    }

    private func fallbackRecordingDeviceIDs() -> [AudioDeviceID] {
        let internalMicrophones = availableDevices.filter { isInternalMicrophone($0.id) }.map { $0.id }
        let otherInputs = availableDevices.filter { !isInternalMicrophone($0.id) }.map { $0.id }
        return isClamshellClosed ? otherInputs + internalMicrophones : internalMicrophones + otherInputs
    }

    func isOperationalInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        availableDevices.contains { $0.id == deviceID }
    }

    private func handleClamshellChange(isClosed: Bool) {
        logger.notice("Clamshell state changed: \(isClosed ? "closed" : "open", privacy: .public)")

        guard isRecordingActive else {
            notifyDeviceChange()
            return
        }
        if inputMode == .systemDefault {
            // Reopening the lid can make the system-default microphone usable again.
            reconcileRecordingDeviceRouting()
            return
        }
        guard isClosed,
            let activeRecordingDeviceID,
            isInternalMicrophone(activeRecordingDeviceID)
        else {
            return
        }

        requestRecordingDeviceChange(reason: .closedLid)
    }

    func requestRecordingDeviceChange(reason: RecordingDeviceChangeReason) {
        requestRecordingDeviceChange(reason: reason, suppressingTargetOf: nil)
    }

    /// Reconcile actual recording state; changing mode never rewrites a personal device choice.
    func reconcileRecordingDeviceRouting() {
        reconcileRecordingDeviceRouting(suppressingTargetOf: nil)
    }

    private func reconcileRecordingDeviceRouting(
        suppressingTargetOf completedRequest: RecordingDeviceChangeRequest?
    ) {
        guard let activeDeviceID = activeRecordingDeviceID, isRecordingActive else { return }
        let reason: RecordingDeviceChangeReason
        if !isOperationalInputDevice(activeDeviceID) {
            reason = .deviceUnavailable
        } else if isClamshellClosed && isInternalMicrophone(activeDeviceID) {
            reason = .closedLid
        } else if inputMode == .systemDefault {
            reason = .systemDefaultChanged
        } else {
            return
        }
        requestRecordingDeviceChange(reason: reason, suppressingTargetOf: completedRequest)
    }

    private func requestRecordingDeviceChange(
        reason: RecordingDeviceChangeReason,
        suppressingTargetOf completedRequest: RecordingDeviceChangeRequest?
    ) {
        guard let activeDeviceID = activeRecordingDeviceID, isRecordingActive else { return }
        guard reason != .systemDefaultChanged || inputMode == .systemDefault else { return }
        let excludedDeviceID = reason == .systemDefaultChanged ? nil : activeDeviceID
        let target = resolveCurrentRecordingDevice(excluding: excludedDeviceID).deviceID
        if let completedRequest, completedRequest.fallbackDeviceID == target { return }
        guard let request = recordingDeviceSession.requestChange(to: target, reason: reason) else {
            return
        }
        NotificationCenter.default.post(
            name: .recordingDeviceChangeRequired,
            object: request
        )
    }
}
