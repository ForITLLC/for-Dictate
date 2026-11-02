import Foundation

extension Transcription {
    var preferredHistoryText: String {
        HistorySuccessPolicy.preferredText(rawText: text, enhancedText: enhancedText)
    }

    var isSuccessfulHistoryEntry: Bool {
        HistorySuccessPolicy.isSuccessful(status: transcriptionStatus, rawText: text)
            && duration.isFinite && duration >= 0
            && HistorySuccessPolicy.normalizedTimestamp(timestamp) != nil
    }

    var hasEnhancedHistoryText: Bool {
        enhancedHistoryText != nil
    }

    var historyEnhancementDetailText: String? {
        guard let enhancedText,
            !enhancedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return enhancedText
    }

    var availableHistoryAudioURL: URL? {
        guard let audioFileURL,
            let url = URL(string: audioFileURL),
            FileManager.default.fileExists(atPath: url.path)
        else {
            return nil
        }
        return url
    }

    var recordedHistoryModeIcon: ModeIcon? {
        guard let modeEmoji else { return nil }
        let value = modeEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return value.isValidEmoji ? .emoji(value) : .symbol(value)
    }

    private var enhancedHistoryText: String? {
        HistorySuccessPolicy.validatedEnhancedText(enhancedText)
    }
}
