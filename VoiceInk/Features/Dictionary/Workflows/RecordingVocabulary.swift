import Foundation
import NaturalLanguage
import os

/// Captured local vocabulary and revocable company eligibility for one recording.
struct RecordingVocabulary: Sendable {
    private static let logger = Logger(subsystem: "io.forit.dictate", category: "VocabularyCorrection")

    private let savedSnapshot: ResolvedVocabularySnapshot
    private let screenTerms: [String]
    private let now: @Sendable () -> Date

    init(savedTerms: [String] = [], screenNames: [String] = []) {
        self.init(savedSnapshot: .init(revision: 0, words: savedTerms, omittedCount: 0), screenNames: screenNames)
    }

    init(
        savedSnapshot: ResolvedVocabularySnapshot, screenNames: [String] = [],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.savedSnapshot = savedSnapshot
        screenTerms = screenNames
        self.now = now
    }

    /// Resolve each new use. Materialized provider payloads and delivered text
    /// are independent copies; invalidating a lease cannot retroactively erase them.
    var terms: [String] {
        var seen = Set<String>()
        // Saved spellings win collisions and retain priority when providers limit hints.
        return (savedSnapshot.words(at: now()) + screenTerms).compactMap { value in
            let term = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let key = term.precomposedStringWithCanonicalMapping.lowercased()
            guard !term.isEmpty, seen.insert(key).inserted else { return nil }
            return term
        }
    }

    func addingScreenNames(_ names: [String]) -> RecordingVocabulary {
        RecordingVocabulary(savedSnapshot: savedSnapshot, screenNames: screenTerms + names, now: now)
    }

    var enhancementSection: String {
        let terms = self.terms
        guard !terms.isEmpty else { return "" }
        let entries = terms.map {
            $0.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }.joined(separator: "\n")
        return """
        Use these entries as preferred spellings for clearly matching words, names, and phonetic transcription mistakes.
        <CUSTOM_VOCABULARY>
        Important Vocabulary:
        \(entries)
        </CUSTOM_VOCABULARY>
        """
    }

    /// Correct off the main actor, then check eligibility again before publication.
    func correctTranscription(_ text: String) async throws -> String {
        try await correctTranscription(text, using: { text, vocabulary in
            try await Self.correctOffMainActor(text, vocabulary: vocabulary)
        })
    }

    /// Internal async seam permits gated lifetime/cancellation tests without a model.
    func correctTranscription(
        _ text: String,
        using correct: @Sendable (String, [String]) async throws -> String
    ) async throws -> String {
        try Task.checkCancellation()
        guard !text.isEmpty else { return text }
        let vocabulary = terms
        guard !vocabulary.isEmpty else { return text }
        let output = try await correct(text, vocabulary)
        try Task.checkCancellation()
        let current = terms
        guard current != vocabulary else { return output }
        guard !current.isEmpty else { return text }

        // Retry once from the original transcript, never from stale corrected text.
        let fallback = try await correct(text, current)
        try Task.checkCancellation()
        guard terms == current else { return text }
        return fallback
    }

    private static func correctOffMainActor(_ text: String, vocabulary: [String]) async throws -> String {
        let correction = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let started = Date()
            let output = PhoneticVocabularyMatcher(vocabulary: vocabulary).correct(text)
            try Task.checkCancellation()
            Self.logger.debug(
                "Phonetic correction changed=\(output != text, privacy: .public) terms=\(vocabulary.count, privacy: .public) elapsed=\(Date().timeIntervalSince(started), format: .fixed(precision: 3), privacy: .public)s"
            )
            return output
        }
        let output = try await withTaskCancellationHandler {
            try await correction.value
        } onCancel: {
            correction.cancel()
        }
        try Task.checkCancellation()
        return output
    }

    /// Uses only the system name tagger; no downloaded model or custom name rules.
    static func screenNames(in text: String, language: String?) -> [String] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        if let language, !language.isEmpty, language != "auto",
            let code = Locale(identifier: language).language.languageCode?.identifier
        {
            let tagLanguage = NLLanguage(rawValue: code)
            if NLTagger.availableTagSchemes(for: .word, language: tagLanguage).contains(.nameType) {
                tagger.setLanguage(tagLanguage, range: text.startIndex..<text.endIndex)
            }
        }
        var names: [String] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            guard !Task.isCancelled else { return false }
            if tag == .personalName || tag == .organizationName || tag == .placeName {
                names.append(String(text[range]))
            }
            return true
        }
        return names
    }
}
