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
        isDeviceSwitch: Bool = false
    ) {
        guard let device = deviceManager.availableDevices.first(where: { $0.id == deviceID }) else {
            return
        }

        // Core Audio object IDs can change on reconnect, or be reused for another input.
        // Compare the stable UID for every route, including closed-lid fallbacks.
        let lastDeviceUID = UserDefaults.standard.string(forKey: "lastUsedMicrophoneDeviceUID")
        guard device.uid != lastDeviceUID else { return }

        recordingDeviceNotificationTask?.cancel()
        // Let the caller finish recording startup before constructing the notification window.
        recordingDeviceNotificationTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled,
                self.deviceManager.isRecordingActive,
                self.deviceManager.activeRecordingDeviceID == deviceID
            else { return }

            let title = isDeviceSwitch ? String(localized: "Switched to: %@") : String(localized: "Using: %@")
            NotificationManager.shared.showNotification(
                title: String(format: title, device.name),
                type: .info
            )
            UserDefaults.standard.set(device.uid, forKey: "lastUsedMicrophoneDeviceUID")
            self.recordingDeviceNotificationTask = nil
        }
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
        showRecordingDeviceNotification(for: outcome.activeDeviceID, isDeviceSwitch: true)
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
