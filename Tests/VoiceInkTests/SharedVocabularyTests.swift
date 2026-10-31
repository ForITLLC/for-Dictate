import Foundation
import XCTest
@testable import VoiceInk

final class SharedVocabularyTests: XCTestCase {
    func testBundledCatalogProvidesUsefulTerms() throws {
        let catalog = try SharedVocabularyCatalog.bundled.validated()
        XCTAssertTrue(catalog.terms.contains("ForIT"))
        XCTAssertTrue(catalog.terms.contains("Tinycast"))
        XCTAssertTrue(catalog.terms.contains("Microsoft Entra ID"))
        XCTAssertGreaterThan(catalog.terms.count, 10)
    }

    func testPersonalWordsWinEvenWhenSharedSpellingIsSuppressed() throws {
        let catalog = try SharedVocabularyCatalog(revision: 1, terms: ["ForIT", "Shared"]).validated()
        let preferences = try SharedVocabularyPreferences(suppressed: [" FORIT "]).validated()
        let snapshot = SharedVocabularyResolver.resolve(
            catalog: catalog, preferences: preferences, personalWords: ["forit", "Personal"]
        )
        XCTAssertEqual(snapshot.words, ["forit", "Personal", "Shared"])
    }

    func testOverrideAndSuppressionSurviveCatalogUpdateWithoutMutatingPersonalWords() throws {
        let preferences = try SharedVocabularyPreferences(
            suppressed: ["Hide"], overrides: ["ForIT": "For IT"]
        ).validated()
        let catalog = try SharedVocabularyCatalog(revision: 2, terms: ["ForIT", "Hide", "New"]).validated()
        let personal = ["Personal"]
        let snapshot = SharedVocabularyResolver.resolve(catalog: catalog, preferences: preferences, personalWords: personal)
        XCTAssertEqual(snapshot.words, ["Personal", "For IT", "New"])
        XCTAssertEqual(snapshot.revision, 2)
        XCTAssertEqual(personal, ["Personal"])
    }

    func testPersonalSpellingWinsOverOverrideOutputAndSource() throws {
        let catalog = try SharedVocabularyCatalog(revision: 1, terms: ["ForIT", "Shared"]).validated()
        let preferences = try SharedVocabularyPreferences(overrides: ["shared": "personal", "forit": "For IT"]).validated()
        let snapshot = SharedVocabularyResolver.resolve(
            catalog: catalog, preferences: preferences, personalWords: ["PERSONAL", "forit"]
        )
        XCTAssertEqual(snapshot.words, ["forit", "PERSONAL"])
    }

    func testNormalizationAndOrderAreDeterministic() throws {
        let input = [" cafe\u{301} ", "Café", "ForIT", "FORIT", "Beta"]
        let first = try SharedVocabularyCatalog(revision: 1, terms: input).validated()
        let second = try SharedVocabularyCatalog(revision: 1, terms: Array(input.reversed())).validated()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.terms.count, 3)
        let a = SharedVocabularyResolver.resolve(catalog: first, preferences: .init(), personalWords: ["z", "A"])
        let b = SharedVocabularyResolver.resolve(catalog: second, preferences: .init(), personalWords: ["A", "z"])
        XCTAssertEqual(a, b)
        XCTAssertEqual(Array(a.words.prefix(2)), ["A", "z"])
    }

    func testInvalidSchemasRevisionsAndTermsAreRejected() throws {
        var catalog = SharedVocabularyCatalog.bundled
        catalog.schemaVersion = 2
        XCTAssertThrowsError(try catalog.validated())
        catalog = .bundled
        catalog.revision = 0
        XCTAssertThrowsError(try catalog.validated())
        for term in [" ", "line\nbreak", String(repeating: "é", count: 81)] {
            XCTAssertThrowsError(try SharedVocabularyCatalog(revision: 1, terms: [term]).validated())
        }
        XCTAssertThrowsError(try SharedVocabularyFiles.decodeCatalog(Data("{broken".utf8)))
    }

    func testCatalogAndByteLimitsAreEnforcedBeforeDecoding() {
        XCTAssertThrowsError(try SharedVocabularyCatalog(
            revision: 1, terms: Array(repeating: "term", count: SharedVocabularyLimits.catalogTerms + 1)
        ).validated())
        XCTAssertThrowsError(try SharedVocabularyFiles.decodeCatalog(
            Data(repeating: 32, count: SharedVocabularyLimits.fileBytes + 1)
        ))
    }

    func testPersonalPreferenceValidationRejectsAmbiguousOverrides() throws {
        let preferences = try SharedVocabularyPreferences(suppressed: ["FORIT", " forit "]).validated()
        XCTAssertEqual(preferences.suppressed, ["forit"])
        XCTAssertThrowsError(try SharedVocabularyPreferences(overrides: ["ForIT": "A", "FORIT": "B"]).validated())
        var invalid = SharedVocabularyPreferences()
        invalid.schemaVersion = 2
        XCTAssertThrowsError(try invalid.validated())
    }

    func testResolvedBudgetPrioritizesPersonalWords() throws {
        let catalog = try SharedVocabularyCatalog(
            revision: 1, terms: (0..<500).map { String(format: "Shared%04d", $0) }
        ).validated()
        let snapshot = SharedVocabularyResolver.resolve(
            catalog: catalog, preferences: .init(), personalWords: ["My personal name"]
        )
        XCTAssertEqual(snapshot.words.first, "My personal name")
        XCTAssertEqual(snapshot.words.count, SharedVocabularyLimits.resolvedTerms)
        XCTAssertLessThanOrEqual(snapshot.words.joined(separator: ", ").utf8.count, SharedVocabularyLimits.resolvedBytes)
        XCTAssertEqual(snapshot.omittedCount, 501 - SharedVocabularyLimits.resolvedTerms)
    }

    func testWhisperPromptPreservesLanguageAndCustomPromptVerbatim() throws {
        let snapshot = ResolvedVocabularySnapshot(revision: 1, words: ["ForIT", "Tinycast"], omittedCount: 0)
        let original = "日本語のカスタム指示。\n  Keep my exact punctuation!  "
        XCTAssertEqual(snapshot.whisperPrompt(preserving: original), original + "\n\nImportant vocabulary: ForIT, Tinycast")
        XCTAssertEqual(snapshot.whisperPrompt(preserving: nil), "Important vocabulary: ForIT, Tinycast")
        let empty = ResolvedVocabularySnapshot(revision: 1, words: [], omittedCount: 0)
        XCTAssertNil(empty.whisperPrompt(preserving: nil))
        XCTAssertEqual(empty.whisperPrompt(preserving: original), original)
    }

    func testWhisperHintBudgetKeepsWholeUnicodeTerms() throws {
        let terms = (0..<200).map { "名前\($0)" + String(repeating: "é", count: 20) }
        let snapshot = ResolvedVocabularySnapshot(revision: 1, words: terms, omittedCount: 0)
        let hint = try XCTUnwrap(snapshot.whisperPrompt(preserving: nil))
        XCTAssertLessThanOrEqual(hint.utf8.count, SharedVocabularyLimits.whisperHintBytes)
        let selected = hint.replacingOccurrences(of: "Important vocabulary: ", with: "").components(separatedBy: ", ")
        XCTAssertLessThanOrEqual(selected.count, SharedVocabularyLimits.whisperTerms)
        XCTAssertFalse(selected.isEmpty)
        XCTAssertTrue(selected.allSatisfy { terms.contains($0) })
    }

    func testCapturedSnapshotDoesNotChangeWhenCacheUpdates() {
        let cache = SharedVocabularyCache()
        let captured = cache.snapshot
        let replacement = ResolvedVocabularySnapshot(revision: 2, words: ["Updated"], omittedCount: 0)
        cache.replace(with: replacement)
        XCTAssertEqual(cache.snapshot, replacement)
        XCTAssertEqual(captured.revision, 1)
        XCTAssertTrue(captured.words.contains("ForIT"))
    }

    func testAddingSharedTermAdvancesRevisionPreservesTermsAndRejectsDuplicate() throws {
        let catalog = try SharedVocabularyCatalog(revision: 7, terms: ["ForIT", "Tinycast"]).validated()
        let next = try catalog.addingTerm(" Cafe\u{301} ")
        XCTAssertEqual(next.revision, 8)
        XCTAssertEqual(Set(next.terms), ["ForIT", "Tinycast", "Café"])
        XCTAssertEqual(catalog.revision, 7)
        XCTAssertEqual(catalog.terms.count, 2)
        XCTAssertThrowsError(try next.addingTerm(" cafe\u{301} "))
        XCTAssertThrowsError(try next.addingTerm(" forit "))
        XCTAssertEqual(next.revision, 8)
        XCTAssertEqual(next.terms.count, 3)
    }

    func testSharedTermAdditionRejectsRevisionOverflowAndCatalogLimit() throws {
        let exhausted = SharedVocabularyCatalog(revision: Int.max, terms: ["Existing"])
        XCTAssertThrowsError(try exhausted.addingTerm("New"))
        XCTAssertEqual(exhausted.revision, Int.max)
        let full = SharedVocabularyCatalog(
            revision: 1, terms: (0..<SharedVocabularyLimits.catalogTerms).map { "Term\($0)" }
        )
        XCTAssertThrowsError(try full.addingTerm("One more"))
        XCTAssertEqual(full.terms.count, SharedVocabularyLimits.catalogTerms)
    }
}
