import Foundation
import SwiftData

class LastTranscriptionService: ObservableObject {

    static func getLastTranscription(from modelContext: ModelContext) -> Transcription? {
        var descriptor = FetchDescriptor<Transcription>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        do {
            let transcriptions = try modelContext.fetch(descriptor)
            return transcriptions.first
        } catch {
            print("Could not read dictation history.")
            return nil
        }
    }

    /// Read past failed/pending rows, including all timestamp ties, instead of assuming the
    /// newest stored row is a usable dictation. Original and preferred paste share this selection.
    static func getLatestSuccessfulTranscription(from modelContext: ModelContext) -> Transcription? {
        let completed = TranscriptionStatus.completed.rawValue
        var descriptor = FetchDescriptor<Transcription>(
            predicate: #Predicate { $0.transcriptionStatus == nil || $0.transcriptionStatus == completed },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = 128
        descriptor.fetchOffset = 0
        descriptor.includePendingChanges = false
        var selected: Transcription?
        do {
            while true {
                let page = try modelContext.fetch(descriptor)
                if page.isEmpty { return selected }
                for transcription in page {
                    if let selected,
                        let selectedDate = HistorySuccessPolicy.normalizedTimestamp(selected.timestamp),
                        let currentDate = HistorySuccessPolicy.normalizedTimestamp(transcription.timestamp),
                        currentDate < selectedDate { return selected }
                    guard transcription.isSuccessfulHistoryEntry else { continue }
                    if selected == nil || HistorySuccessPolicy.precedes(
                        timestamp: transcription.timestamp, id: transcription.id.uuidString,
                        timestamp: selected!.timestamp, id: selected!.id.uuidString) {
                        selected = transcription
                    }
                }
                if page.count < 128 { return selected }
                descriptor.fetchOffset += page.count
            }
        } catch {
            print("Could not read dictation history.")
            return nil
        }
    }

    static func copyLastTranscription(from modelContext: ModelContext) {
        guard let lastTranscription = getLatestSuccessfulTranscription(from: modelContext) else {
            Task { @MainActor in
                NotificationManager.shared.showNotification(
                    title: String(localized: "No transcription available"),
                    type: .error
                )
            }
            return
        }

        let textToCopy = lastTranscription.preferredHistoryText

        let success = ClipboardManager.copyToClipboard(textToCopy)

        Task { @MainActor in
            if success {
                NotificationManager.shared.showNotification(
                    title: String(localized: "Last transcription copied"),
                    type: .success
                )
            } else {
                NotificationManager.shared.showNotification(
                    title: String(localized: "Failed to copy transcription"),
                    type: .error
                )
            }
        }
    }

    static func pasteLastTranscription(from modelContext: ModelContext) {
        guard let lastTranscription = getLatestSuccessfulTranscription(from: modelContext) else {
            Task { @MainActor in
                NotificationManager.shared.showNotification(
                    title: String(localized: "No transcription available"),
                    type: .error
                )
            }
            return
        }

        let textToPaste = lastTranscription.text

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            CursorPaster.pasteAtCursor(textToPaste)
        }
    }

    static func pasteLastEnhancement(from modelContext: ModelContext) {
        guard let lastTranscription = getLatestSuccessfulTranscription(from: modelContext) else {
            Task { @MainActor in
                NotificationManager.shared.showNotification(
                    title: String(localized: "No transcription available"),
                    type: .error
                )
            }
            return
        }

        let textToPaste = lastTranscription.preferredHistoryText

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            CursorPaster.pasteAtCursor(textToPaste)
        }
    }

    static func retryLastTranscription(
        from modelContext: ModelContext, transcriptionModelManager: TranscriptionModelManager,
        serviceRegistry: TranscriptionServiceRegistry, enhancementService: AIEnhancementService?
    ) {
        Task { @MainActor in
            guard let lastTranscription = getLastTranscription(from: modelContext),
                let audioURLString = lastTranscription.audioFileURL,
                let audioURL = URL(string: audioURLString),
                FileManager.default.fileExists(atPath: audioURL.path)
            else {
                NotificationManager.shared.showNotification(
                    title: String(localized: "Cannot retry: Audio file not found"),
                    type: .error
                )
                return
            }

            guard
                let transcriptionConfiguration = ModeRuntimeResolver.transcriptionConfiguration(
                    transcriptionModelManager: transcriptionModelManager
                )
            else {
                NotificationManager.shared.showNotification(
                    title: String(localized: "No transcription model selected"),
                    type: .error
                )
                return
            }

            let transcriptionService = AudioTranscriptionService(
                modelContext: modelContext,
                serviceRegistry: serviceRegistry,
                enhancementService: enhancementService
            )
            do {
                let result = try await transcriptionService.retranscribeAudio(
                    from: audioURL,
                    using: transcriptionConfiguration.model
                )
                let newTranscription = result.transcription

                let textToCopy = newTranscription.preferredHistoryText
                _ = ClipboardManager.copyToClipboard(textToCopy)

                if let enhancementFailure = result.enhancementFailure {
                    NotificationManager.shared.showNotification(
                        title: EnhancementFailureFormatter.transcriptionSavedMessage(
                            description: enhancementFailure
                        ),
                        type: .warning
                    )
                } else {
                    NotificationManager.shared.showNotification(
                        title: String(localized: "Copied to clipboard"),
                        type: .success
                    )
                }
            } catch {
                NotificationManager.shared.showNotification(
                    title: String(format: String(localized: "Retry failed: %@"), error.localizedDescription),
                    type: .error
                )
            }
        }
    }
}
