import Foundation

/// Shared by history actions and the launcher export. No model objects or UI side effects.
enum HistorySuccessPolicy {
    static func precedes(timestamp lhsDate: Date, id lhsID: String, timestamp rhsDate: Date, id rhsID: String) -> Bool {
        guard let lhs = timestampMilliseconds(lhsDate), let rhs = timestampMilliseconds(rhsDate) else {
            return lhsDate == rhsDate ? lhsID.lowercased() < rhsID.lowercased() : lhsDate > rhsDate
        }
        return lhs == rhs ? lhsID.lowercased() < rhsID.lowercased() : lhs > rhs
    }

    /// The wire timestamp has millisecond precision. Floor before formatting, so rows within
    /// the same wire millisecond use the same UUID tiebreak everywhere, including app actions.
    static func normalizedTimestamp(_ date: Date) -> Date? {
        guard let milliseconds = timestampMilliseconds(date) else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    static func timestampMilliseconds(_ date: Date) -> Int64? {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= -62_135_596_800, seconds < 253_402_300_799 else { return nil }
        return Int64(floor(seconds * 1_000))
    }

    static func isSuccessful(status: String?, rawText: String) -> Bool {
        // Rows predating the status attribute have nil status. An unknown non-nil status
        // is not evidence of success, and a failed enhancement cannot turn failed audio into success.
        guard status == nil || status == "completed" else { return false }
        let content = trimmedContent(rawText)
        guard !content.isEmpty else { return false }
        let normalized = normalizedPrefix(content)
        guard !canceledTexts.contains(normalized) else { return false }
        return !failurePrefixes.contains { normalized.hasPrefix($0) }
    }

    static func preferredText(rawText: String, enhancedText: String?) -> String {
        validatedEnhancedText(enhancedText) ?? rawText
    }

    static func validatedEnhancedText(_ enhancedText: String?) -> String? {
        guard let enhancedText else { return nil }
        let content = trimmedContent(enhancedText)
        guard !content.isEmpty else { return nil }
        let normalized = normalizedPrefix(content)
        guard
            !failurePrefixes.contains(where: { normalized.hasPrefix($0) }),
            !canceledTexts.contains(normalized)
        else { return nil }
        return enhancedText
    }

    private static func trimmedContent(_ text: String) -> Substring {
        guard let first = text.firstIndex(where: { !$0.isWhitespace }),
            let last = text.lastIndex(where: { !$0.isWhitespace }) else { return text[text.endIndex...] }
        return text[first...last]
    }

    private static func normalizedPrefix(_ text: Substring) -> String {
        // A transcript can be arbitrarily large. Placeholder recognition needs only a short
        // prefix, and must not allocate a lowercased copy of the complete dictation.
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.prefix(512))
        return String(scalars).lowercased()
    }

    private static let bundles: [Bundle] = [Bundle.main] + Bundle.main.localizations.compactMap {
        Bundle.main.path(forResource: $0, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    private static let failurePrefixes: [String] = {
        ["Enhancement failed: %@", "Transcription Failed: %@"].flatMap { key in
            ([key] + bundles.map { $0.localizedString(forKey: key, value: key, table: nil) })
                .compactMap { format -> String? in
                    guard let placeholder = format.range(of: "%@") else { return nil }
                    let prefix = format[..<placeholder.lowerBound]
                        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    return prefix.isEmpty ? nil : prefix
                }
        }
    }()

    private static let canceledTexts: Set<String> = {
        let key = "The transcription was canceled."
        return Set(([key] + bundles.map { $0.localizedString(forKey: key, value: key, table: nil) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    }()
}
