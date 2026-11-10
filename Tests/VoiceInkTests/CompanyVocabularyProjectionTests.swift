import Foundation
import XCTest
@testable import VoiceInk

/// Synthetic complete DTOs and explicitly owned caches only. No credentials,
/// user catalogs, SwiftData stores, network, timers or recognition models.
final class CompanyVocabularyProjectionTests: XCTestCase {
    private let timestamp = "2026-11-10T00:00:00.000Z"

    private func term(_ number: Int, _ spelling: String, active: Bool = true) -> [String: Any] {
        [
            "term_id": String(format: "10000000-0000-0000-0000-%012d", number),
            "canonical_spelling": spelling, "spoken_forms": ["spoken alias \(number)"],
            "meaning": "Synthetic explanatory metadata \(number)", "kind": "product",
            "is_active": active, "revision": number, "updated_at": timestamp,
        ]
    }

    private func company(_ terms: [[String: Any]]) throws -> CompanyDictionarySnapshot {
        let object: [String: Any] = [
            "schemaVersion": 1, "companyId": CompanyDictionarySnapshot.supportCompanyID,
            "version": "\"opaque-company-read-active\"", "terms": terms,
            "total": terms.count, "updated_at": terms.isEmpty ? NSNull() : timestamp as Any,
            "canEdit": false,
        ]
        return try JSONDecoder().decode(
            CompanyDictionarySnapshot.self, from: JSONSerialization.data(withJSONObject: object)
        )
    }

    func testAbsentUnboundAndEmptyCompanyKeepExactLocalPreferenceOrdering() throws {
        let catalog = try SharedVocabularyCatalog(
            revision: 17, terms: ["FORIT", "Hide", "zLocal", "aLocal"]
        ).validated()
        let choices = try SharedVocabularyPreferences(
            suppressed: ["hide"], overrides: ["forit": "For IT"]
        ).validated()
        let baseline = SharedVocabularyResolver.resolve(
            catalog: catalog, preferences: choices, personalWords: ["Mine"]
        )
        XCTAssertEqual(baseline.words, ["Mine", "aLocal", "For IT", "zLocal"])
        XCTAssertEqual(baseline.revision, 17)
        let unbound = SharedVocabularyResolver.resolve(
            catalog: catalog, preferences: choices, personalWords: ["Mine"],
            companySnapshot: try company([term(1, "Company")]), companyValidUntil: nil
        )
        let empty = SharedVocabularyResolver.resolve(
            catalog: catalog, preferences: choices, personalWords: ["Mine"],
            companySnapshot: try company([]), companyValidUntil: .distantFuture
        )
        XCTAssertEqual(unbound, baseline)
        XCTAssertEqual(empty, baseline)
    }

    func testCompanyTierPrecedesAlphabeticallyEarlierLocalTermsWithinBothBudgets() throws {
        let catalog = try SharedVocabularyCatalog(
            revision: 6, terms: (0..<300).map { String(format: "A%04d", $0) }
        ).validated()
        let terms = (1...300).map { term($0, String(format: "Z%04d", $0)) }
        let snapshot = SharedVocabularyResolver.resolve(
            catalog: catalog, preferences: .init(), personalWords: ["Personal"],
            companySnapshot: try company(terms), companyValidUntil: .distantFuture
        )
        XCTAssertEqual(snapshot.words.first, "Personal")
        XCTAssertEqual(Array(snapshot.words.dropFirst()), (1...255).map { String(format: "Z%04d", $0) })
        XCTAssertEqual(snapshot.omittedCount, 601 - SharedVocabularyLimits.resolvedTerms)
        XCTAssertEqual(snapshot.companyCoverage, .init(
            activeTermCount: 300, unsupportedTermCount: 0, eligibleTermCount: 300, includedTermCount: 255
        ))
        XCTAssertEqual(snapshot.companyCoverage.budgetOmittedTermCount, 45)
        XCTAssertEqual(snapshot.revision, 6, "Remote ETags must not replace the local catalog revision.")
        let original = "日本語の指示をそのまま残す。"
        let prompt = try XCTUnwrap(snapshot.whisperPrompt(preserving: original))
        XCTAssertTrue(prompt.hasPrefix(original + "\n\nImportant vocabulary: Personal, Z0001"))
        let hints = prompt.components(separatedBy: "Important vocabulary: ")[1].components(separatedBy: ", ")
        XCTAssertEqual(hints.count, SharedVocabularyLimits.whisperTerms)
        XCTAssertEqual(hints.last, "Z0063")
        XCTAssertFalse(hints.contains(where: { $0.hasPrefix("A") }))
    }

    func testExistingChoicesAndPersonalWordsWinSourceAndOutputCollisions() throws {
        let catalog = try SharedVocabularyCatalog(revision: 2, terms: ["Source", "Hidden", "Last"]).validated()
        let choices = try SharedVocabularyPreferences(
            suppressed: ["hidden"], overrides: ["product": "Personal", "source": "Azure"]
        ).validated()
        let snapshot = SharedVocabularyResolver.resolve(
            catalog: catalog, preferences: choices, personalWords: ["FORIT", "PERSONAL"],
            companySnapshot: try company([
                term(1, "forit"), term(2, "Product"), term(3, "azure"),
                term(4, "Hidden"), term(5, "Zeta"),
            ]), companyValidUntil: .distantFuture
        )
        XCTAssertEqual(snapshot.words, ["FORIT", "PERSONAL", "Azure", "Zeta", "Last"])
        XCTAssertEqual(snapshot.companyCoverage, .init(
            activeTermCount: 5, unsupportedTermCount: 0, eligibleTermCount: 1, includedTermCount: 1
        ))
        XCTAssertEqual(snapshot.companyCoverage.choiceOrCollisionExcludedTermCount, 4)
        XCTAssertEqual(choices.overrides, ["product": "Personal", "source": "Azure"])
        XCTAssertEqual(catalog.terms, ["Hidden", "Last", "Source"])
    }

    func testCanonicalCollisionUsesStableCompanyIDRegardlessOfProducerArrayOrder() throws {
        let first = term(1, "Café"), second = term(2, " CAFE\u{301} ")
        let catalog = try SharedVocabularyCatalog(revision: 1, terms: ["café", "Local"]).validated()
        let a = SharedVocabularyResolver.resolve(
            catalog: catalog, preferences: .init(), personalWords: [],
            companySnapshot: try company([second, first]), companyValidUntil: .distantFuture
        )
        let b = SharedVocabularyResolver.resolve(
            catalog: catalog, preferences: .init(), personalWords: [],
            companySnapshot: try company([first, second]), companyValidUntil: .distantFuture
        )
        // Independent publications intentionally have different revocable lease
        // identities, but their normalization and resolved content are identical.
        XCTAssertEqual(a.words, b.words)
        XCTAssertEqual(a.omittedCount, b.omittedCount)
        XCTAssertEqual(a.companyCoverage, b.companyCoverage)
        XCTAssertEqual(a.words, ["Café", "Local"])
        XCTAssertEqual(a.companyCoverage.eligibleTermCount, 1)
        XCTAssertEqual(a.companyCoverage.choiceOrCollisionExcludedTermCount, 1)
    }

    func testProjectionExcludesInactiveAndUnsupportedHintsWithoutChangingRichDTO() throws {
        let long = String(repeating: "名", count: 81) // Valid Support text, over 160 UTF-8 bytes.
        let source = try company([
            term(1, "Good"), term(2, long), term(3, "Zero\u{200B}Width"), term(4, "Inactive", active: false),
        ])
        let savedTerms = source.terms
        let projection = try XCTUnwrap(CompanyVocabularyProjection(snapshot: source, validUntil: .distantFuture))
        XCTAssertEqual(projection.activeTermCount, 3)
        XCTAssertEqual(projection.unsupportedTermCount, 2)
        let snapshot = SharedVocabularyResolver.resolve(
            catalog: .init(revision: 1, terms: ["Local"]), preferences: .init(), personalWords: [],
            companySnapshot: source, companyValidUntil: .distantFuture
        )
        XCTAssertEqual(snapshot.words, ["Good", "Local"])
        XCTAssertEqual(snapshot.companyCoverage, .init(
            activeTermCount: 3, unsupportedTermCount: 2, eligibleTermCount: 1, includedTermCount: 1
        ))
        XCTAssertEqual(snapshot.companyCoverage.omittedTermCount, 2)
        XCTAssertEqual(source.terms, savedTerms)
        XCTAssertEqual(source.terms[1].canonicalSpelling, long)
        XCTAssertEqual(source.terms[0].spokenForms, ["spoken alias 1"])
        XCTAssertEqual(source.terms[0].meaning, "Synthetic explanatory metadata 1")
        XCTAssertFalse(try XCTUnwrap(snapshot.whisperPrompt(preserving: nil)).contains("spoken alias"))
    }

    func testCapturedSnapshotAndPromptRevertAtExpiryWithoutRepublishing() throws {
        let expiry = Date(timeIntervalSince1970: 200)
        let before = expiry.addingTimeInterval(-1)
        let catalog = try SharedVocabularyCatalog(
            revision: 8, terms: (0..<300).map { String(format: "A%04d", $0) }
        ).validated()
        let baseline = SharedVocabularyResolver.resolve(catalog: catalog, preferences: .init(), personalWords: [])
        let captured = SharedVocabularyResolver.resolve(
            catalog: catalog, preferences: .init(), personalWords: [],
            companySnapshot: try company((1...300).map { term($0, String(format: "Z%04d", $0)) }),
            companyValidUntil: expiry
        )
        XCTAssertEqual(captured.words(at: before).first, "Z0001")
        XCTAssertEqual(captured.omittedCount(at: before), 600 - SharedVocabularyLimits.resolvedTerms)
        XCTAssertEqual(captured.companyCoverage(at: before).includedTermCount, SharedVocabularyLimits.resolvedTerms)
        XCTAssertEqual(captured.words(at: expiry), baseline.words)
        XCTAssertEqual(captured.companyCoverage(at: expiry), .none)
        XCTAssertEqual(captured.omittedCount(at: expiry), baseline.omittedCount)
        XCTAssertEqual(captured.words(at: expiry.addingTimeInterval(1)), baseline.words)
        let original = "Keep my prompt."
        XCTAssertTrue(try XCTUnwrap(captured.whisperPrompt(preserving: original, at: before)).contains("Z0001"))
        XCTAssertEqual(
            captured.whisperPrompt(preserving: original, at: expiry), baseline.whisperPrompt(preserving: original)
        )
        // This captured deadline is already past on any current supported Mac;
        // normal production getters, not just explicit-date test APIs, expire.
        XCTAssertEqual(captured.words, baseline.words)
        XCTAssertEqual(captured.omittedCount, baseline.omittedCount)
        XCTAssertEqual(captured.whisperPrompt(preserving: original), baseline.whisperPrompt(preserving: original))
    }

    func testCompanyUnicodeHintsRespectByteLimitsWithoutTruncatingTerms() throws {
        let spellings = (1...100).map { String(repeating: "é", count: 75) + String(format: "%03d", $0) }
        let snapshot = SharedVocabularyResolver.resolve(
            catalog: .init(revision: 1, terms: []), preferences: .init(), personalWords: [],
            companySnapshot: try company(spellings.enumerated().map { term($0.offset + 1, $0.element) }),
            companyValidUntil: .distantFuture
        )
        XCTAssertFalse(snapshot.words.isEmpty)
        XCTAssertLessThan(snapshot.words.count, spellings.count)
        XCTAssertLessThanOrEqual(snapshot.words.joined(separator: ", ").utf8.count, SharedVocabularyLimits.resolvedBytes)
        XCTAssertTrue(snapshot.words.allSatisfy { spellings.contains($0) })
        XCTAssertEqual(snapshot.companyCoverage.eligibleTermCount, spellings.count)
        XCTAssertEqual(snapshot.companyCoverage.includedTermCount, snapshot.words.count)
        XCTAssertEqual(snapshot.companyCoverage.budgetOmittedTermCount, spellings.count - snapshot.words.count)
        let hint = try XCTUnwrap(snapshot.whisperPrompt(preserving: nil))
        XCTAssertLessThanOrEqual(hint.utf8.count, SharedVocabularyLimits.whisperHintBytes)
        let hints = hint.components(separatedBy: "Important vocabulary: ")[1].components(separatedBy: ", ")
        XCTAssertTrue(hints.allSatisfy { spellings.contains($0) })
    }

    @MainActor
    func testServiceEmptyRemovalAndMissingLifetimeDoNotMutateLocalStores() throws {
        let cache = SharedVocabularyCache()
        let service = SharedVocabularyService(cache: cache)
        let localCatalog = service.catalog, localChoices = service.preferences
        let exportBefore = try service.exportCatalog()
        let source = try company([term(1, "Synthetic company-only spelling")])
        service.setCompanySnapshot(source, validUntil: .distantFuture)
        let captured = cache.snapshot
        XCTAssertTrue(captured.words.contains("Synthetic company-only spelling"))
        service.setCompanySnapshot(try company([]), validUntil: .distantFuture)
        XCTAssertFalse(cache.snapshot.words.contains("Synthetic company-only spelling"))
        XCTAssertFalse(captured.words.contains("Synthetic company-only spelling"))
        service.setCompanySnapshot(source, validUntil: nil)
        XCTAssertFalse(cache.snapshot.words.contains("Synthetic company-only spelling"))
        service.setCompanySnapshot(source, validUntil: .distantPast)
        XCTAssertFalse(cache.snapshot.words.contains("Synthetic company-only spelling"))
        service.setCompanySnapshot(nil, validUntil: nil)
        XCTAssertEqual(service.catalog, localCatalog)
        XCTAssertEqual(service.preferences, localChoices)
        XCTAssertEqual(try service.exportCatalog(), exportBefore)
        XCTAssertEqual(service.companyActiveTermCount, 0)
        XCTAssertEqual(service.companyUnsupportedTermCount, 0)
    }

    @MainActor
    func testClearRevokesCapturedReadsButCannotEraseMaterializedProviderPayload() throws {
        let cache = SharedVocabularyCache()
        let service = SharedVocabularyService(cache: cache)
        let localOnly = cache.snapshot
        service.setCompanySnapshot(try company([term(1, "Synthetic company secret")]), validUntil: .distantFuture)
        let captured = cache.snapshot
        let existingPayload = try XCTUnwrap(captured.whisperPrompt(preserving: "Original language prompt"))
        XCTAssertTrue(captured.words.contains("Synthetic company secret"))
        service.setCompanySnapshot(nil, validUntil: nil)
        XCTAssertEqual(captured.words, localOnly.words)
        XCTAssertEqual(captured.omittedCount, localOnly.omittedCount)
        XCTAssertEqual(captured.companyCoverage, .none)
        XCTAssertEqual(
            captured.whisperPrompt(preserving: "Original language prompt"),
            localOnly.whisperPrompt(preserving: "Original language prompt")
        )
        XCTAssertEqual(service.companyCoverage, .none)
        // A string or request body obtained before revocation is an independent
        // copy. Provider cancellation/account fences still belong to its caller.
        XCTAssertTrue(existingPayload.contains("Synthetic company secret"))
    }

    @MainActor
    func testIdenticalReplacementCreatesNewLeaseAndRevokesCapturedOldPublication() throws {
        let cache = SharedVocabularyCache()
        let service = SharedVocabularyService(cache: cache)
        let localOnly = cache.snapshot
        let source = try company([term(1, "Synthetic shared spelling")])
        service.setCompanySnapshot(source, validUntil: .distantFuture)
        let captured = cache.snapshot, samePublicationCopy = captured
        XCTAssertEqual(captured, samePublicationCopy)
        service.setCompanySnapshot(source, validUntil: .distantFuture)
        let replacement = cache.snapshot
        XCTAssertNotEqual(captured, replacement, "A new account/session publication must not reuse an old lease.")
        XCTAssertEqual(captured, samePublicationCopy, "Invalidation does not make equality time-dependent.")
        XCTAssertEqual(captured.words, localOnly.words)
        XCTAssertEqual(captured.companyCoverage, .none)
        XCTAssertTrue(replacement.words.contains("Synthetic shared spelling"))
        XCTAssertEqual(replacement.companyCoverage.includedTermCount, 1)
    }

    @MainActor
    func testDifferentReplacementRevokesOldHintsAndPreservesLocalFallback() throws {
        let cache = SharedVocabularyCache()
        let service = SharedVocabularyService(cache: cache)
        let localOnly = cache.snapshot
        service.setCompanySnapshot(try company([term(1, "First company spelling")]), validUntil: .distantFuture)
        let first = cache.snapshot
        service.setCompanySnapshot(try company([term(2, "Second company spelling")]), validUntil: .distantFuture)
        let second = cache.snapshot
        XCTAssertEqual(first.words, localOnly.words)
        XCTAssertFalse(second.words.contains("First company spelling"))
        XCTAssertTrue(second.words.contains("Second company spelling"))
        XCTAssertTrue(localOnly.words.allSatisfy { second.words.contains($0) })
        service.setCompanySnapshot(nil, validUntil: nil)
        XCTAssertEqual(first.words, localOnly.words)
        XCTAssertEqual(second.words, localOnly.words)
        XCTAssertEqual(cache.snapshot.words, localOnly.words)
    }

    func testCoverageIncludesUnsupportedAndChoiceExcludedTermsWithoutInventingEligibility() throws {
        let catalog = SharedVocabularyCatalog(revision: 1, terms: ["Local"])
        let unsupported = SharedVocabularyResolver.resolve(
            catalog: catalog, preferences: .init(), personalWords: [],
            companySnapshot: try company([term(1, String(repeating: "名", count: 81))]),
            companyValidUntil: .distantFuture
        )
        XCTAssertEqual(unsupported.words, ["Local"])
        XCTAssertEqual(unsupported.companyCoverage, .init(
            activeTermCount: 1, unsupportedTermCount: 1, eligibleTermCount: 0, includedTermCount: 0
        ))
        XCTAssertEqual(unsupported.companyCoverage.omittedTermCount, 1)
        let suppressed = SharedVocabularyResolver.resolve(
            catalog: catalog, preferences: .init(suppressed: ["company"]), personalWords: [],
            companySnapshot: try company([term(1, "Company")]), companyValidUntil: .distantFuture
        )
        XCTAssertEqual(suppressed.words, ["Local"])
        XCTAssertEqual(suppressed.companyCoverage.eligibleTermCount, 0)
        XCTAssertEqual(suppressed.companyCoverage.includedTermCount, 0)
        XCTAssertEqual(suppressed.companyCoverage.choiceOrCollisionExcludedTermCount, 1)
        XCTAssertEqual(suppressed.companyCoverage.budgetOmittedTermCount, 0)
    }
}
