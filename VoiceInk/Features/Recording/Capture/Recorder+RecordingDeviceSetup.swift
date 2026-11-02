import CoreAudio
import Foundation
import os

extension Recorder {
    func setupRecordingDeviceChangeObserver() {
        recordingDeviceChangeObserver = NotificationCenter.default.addObserver(
            forName: .recordingDeviceChangeRequired,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task {
                await self?.handleRecordingDeviceChange(notification)
            }
        }
    }

    func startHardwareRecording(
        _ recorder: CoreAudioRecorder,
        to url: URL,
        deviceID: AudioDeviceID
    ) async throws {
        let selectedChannels = deviceManager.selectedInputChannels(for: deviceID)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioSetupQueue.async {
                do {
                    try recorder.startRecording(
                        toOutputFile: url, deviceID: deviceID, selectedInputChannels: selectedChannels
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func showRecordingDeviceNotification(
        for deviceID: AudioDeviceID,
        resolution: RecordingDeviceResolution
    ) {
        guard let deviceName = deviceManager.availableDevices.first(where: { $0.id == deviceID })?.name else {
            return
        }

        if resolution.fellBackFromClosedInternalMicrophone {
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Using: %@"), deviceName),
                type: .info
            )
            return
        }

        let lastDeviceID = UserDefaults.standard.string(forKey: "lastUsedMicrophoneDeviceID")
        guard String(deviceID) != lastDeviceID else { return }
        NotificationManager.shared.showNotification(
            title: String(format: String(localized: "Using: %@"), deviceName),
            type: .info
        )
    }

    private struct DeviceSwitchOutcome {
        let activeDeviceID: AudioDeviceID
        let isCapturing: Bool
        let error: Error?
    }

    private func handleRecordingDeviceChange(_ notification: Notification) async {
        guard let request = notification.object as? RecordingDeviceChangeRequest else { return }
        guard deviceManager.isCurrent(request) else {
            _ = deviceManager.finish(request)
            return
        }
        guard let targetDeviceID = request.fallbackDeviceID else {
            // A safety fallback with no device ends capture but keeps the WAV.
            guard await finishRecordingAfterInputFailure() else { return }
            showNoFallbackNotification(reason: request.reason)
            return
        }
        guard let recorder else {
            _ = deviceManager.finish(request)
            return
        }
        let selectedChannels = deviceManager.selectedInputChannels(for: targetDeviceID)
        let outcome: DeviceSwitchOutcome? = await withCheckedContinuation { continuation in
            audioSetupQueue.async {
                // Only the thread-safe lease crosses queues, not manager state.
                guard request.lease.isValid else {
                    continuation.resume(returning: nil)
                    return
                }
                var switchError: Error?
                do {
                    try recorder.switchDevice(to: targetDeviceID, selectedInputChannels: selectedChannels)
                } catch {
                    switchError = error
                }
                continuation.resume(returning: DeviceSwitchOutcome(
                    activeDeviceID: recorder.currentDevice,
                    isCapturing: recorder.isCapturingAudio, error: switchError
                ))
            }
        }
        guard deviceManager.isCurrentRecordingSession(request.sessionID) else { return }
        guard let outcome else {
            _ = deviceManager.finish(request)
            return
        }
        guard outcome.isCapturing else {
            guard await finishRecordingAfterInputFailure() else { return }
            NotificationManager.shared.showNotification(
                title: String(localized: "Microphone input stopped. The audio already recorded has been kept."),
                type: .error, duration: 7.0
            )
            return
        }
        guard deviceManager.finish(request, activeDeviceID: outcome.activeDeviceID) else { return }
        if let error = outcome.error {
            logger.error("Failed to switch recording devices: \(error, privacy: .public)")
            NotificationManager.shared.showNotification(
                title: String(localized: "ForIT Dictate could not switch to another microphone."),
                type: .error, duration: 7.0
            )
            return
        }
        UserDefaults.standard.set(String(outcome.activeDeviceID), forKey: "lastUsedMicrophoneDeviceID")
        if let name = deviceManager.availableDevices.first(where: { $0.id == outcome.activeDeviceID })?.name {
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Switched to: %@"), name), type: .info
            )
        }
    }

    private func finishRecordingAfterInputFailure() async -> Bool {
        let failedSessionID = inputFailurePlaybackSessionID
        await stopRecording()
        guard inputFailurePlaybackSessionID == failedSessionID else { return false }
        await onAudioInputFailure?()
        return inputFailurePlaybackSessionID == failedSessionID
    }

    private func showNoFallbackNotification(reason: RecordingDeviceChangeReason) {
        let presentation = AudioInputFailurePresentation.noUsableMicrophone(
            internalMicrophoneBlockedByClosedLid: reason == .closedLid
        )
        NotificationManager.shared.showNotification(
            title: presentation.title,
            type: .error,
            duration: 7.0,
            actionButton: (presentation.actionLabel, presentation.action)
        )
    }

}
