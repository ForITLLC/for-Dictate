import Foundation
import XCTest
@testable import VoiceInk

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func read() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
}

private actor CorrectionGate {
    struct Call: Equatable, Sendable {
        let text: String
        let terms: [String]
    }

    private(set) var calls: [Call] = []
    private var waiting: (count: Int, continuation: CheckedContinuation<Void, Never>)?
    private var result: CheckedContinuation<String, Never>?

    func correct(_ text: String, terms: [String]) async -> String {
        calls.append(Call(text: text, terms: terms))
        if let waiting, calls.count >= waiting.count {
            self.waiting = nil
            waiting.continuation.resume()
        }
        return await withCheckedContinuation { result = $0 }
    }

    func waitForCall(_ count: Int) async {
        guard calls.count < count else { return }
        await withCheckedContinuation { waiting = (count, $0) }
    }

    func release(_ output: String) {
        let pending = result
        result = nil
        pending?.resume(returning: output)
    }
}

/// Owned snapshots/services and explicit continuation gates only: no singleton,
/// credentials, stores, timers, network, models, OCR or target-app delivery.
@MainActor
final class RecordingVocabularyTests: XCTestCase {
    private let beforeExpiry = Date(timeIntervalSince1970: 2_000_000_000)
    private let expiry = Date(timeIntervalSince1970: 2_000_000_100)

    private func company(_ spelling: String) throws -> CompanyDictionarySnapshot {
        let timestamp = "2026-11-10T00:00:00.000Z"
        let object: [String: Any] = [
            "schemaVersion": 1, "companyId": CompanyDictionarySnapshot.supportCompanyID,
            "version": "\"synthetic-recording\"", "total": 1, "updated_at": timestamp, "canEdit": false,
            "terms": [["term_id": "10000000-0000-0000-0000-000000000001",
                       "canonical_spelling": spelling, "spoken_forms": [], "meaning": "",
                       "kind": "product", "is_active": true, "revision": 1, "updated_at": timestamp]],
        ]
        return try JSONDecoder().decode(
            CompanyDictionarySnapshot.self, from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func bound(
        local: [String] = ["Personal"], clock: Clock, lease: CompanyVocabularyLease = CompanyVocabularyLease()
    ) -> RecordingVocabulary {
        RecordingVocabulary(
            savedSnapshot: .init(
                revision: 1, words: local + ["Company"], omittedCount: 0,
                companyValidUntil: expiry, wordsWithoutCompany: local,
                omittedWithoutCompany: 0, companyLease: lease
            ), now: { clock.read() }
        )
    }

    func testPlainSavedTermsKeepPriorityDedupAndCorrection() async throws {
        let vocabulary = RecordingVocabulary(
            savedTerms: ["  OpenAI ", "Personal Name", "Café", ""],
            screenNames: ["openai", " personal\tname ", "Cafe\u{301}", "Screen Name"]
        )
        XCTAssertEqual(vocabulary.terms, ["OpenAI", "Personal Name", "Café", "Screen Name"])
        let output = try await vocabulary.correctTranscription("Open AI")
        XCTAssertEqual(output, "OpenAI", "Exercise the existing production matcher, without an ASR model.")
        XCTAssertTrue(RecordingVocabulary(savedTerms: ["A&B <C>"]).enhancementSection.contains("A&amp;B &lt;C&gt;"))
    }

    func testSignOutPublicationRevokesCapturedRecordingAndPrompt() throws {
        let cache = SharedVocabularyCache()
        let service = SharedVocabularyService(cache: cache)
        let local = cache.snapshot.words
        service.setCompanySnapshot(try company("Company Only"), validUntil: .distantFuture)
        let captured = RecordingVocabulary(savedSnapshot: cache.snapshot)
        let materialized = captured.enhancementSection
        XCTAssertTrue(captured.terms.contains("Company Only"))
        // CompanyDictionaryClient.signOut publishes this clear before any I/O.
        service.setCompanySnapshot(nil, validUntil: nil)
        XCTAssertEqual(captured.terms, local)
        XCTAssertFalse(captured.enhancementSection.contains("Company Only"))
        XCTAssertTrue(materialized.contains("Company Only"), "Already constructed payloads cannot be erased.")
    }

    func testIdenticalReplacementRevokesOldRecordingButKeepsNewPublication() throws {
        let cache = SharedVocabularyCache()
        let service = SharedVocabularyService(cache: cache)
        let local = cache.snapshot.words
        let source = try company("Company Only")
        service.setCompanySnapshot(source, validUntil: .distantFuture)
        let old = RecordingVocabulary(savedSnapshot: cache.snapshot)
        service.setCompanySnapshot(source, validUntil: .distantFuture)
        XCTAssertEqual(old.terms, local)
        XCTAssertTrue(RecordingVocabulary(savedSnapshot: cache.snapshot).terms.contains("Company Only"))
    }

    func testDifferentReplacementDoesNotMoveOldRecordingToNewAccount() throws {
        let cache = SharedVocabularyCache()
        let service = SharedVocabularyService(cache: cache)
        let local = cache.snapshot.words
        service.setCompanySnapshot(try company("First Company"), validUntil: .distantFuture)
        let old = RecordingVocabulary(savedSnapshot: cache.snapshot)
        service.setCompanySnapshot(try company("Second Company"), validUntil: .distantFuture)
        let fresh = RecordingVocabulary(savedSnapshot: cache.snapshot)
        XCTAssertEqual(old.terms, local)
        XCTAssertFalse(fresh.terms.contains("First Company"))
        XCTAssertTrue(fresh.terms.contains("Second Company"))
    }

    func testExpiryAtBoundaryUsesLocalFallbackAndEmptyPrompt() {
        let clock = Clock(beforeExpiry)
        let vocabulary = bound(clock: clock)
        let companyOnly = bound(local: [], clock: clock)
        XCTAssertEqual(vocabulary.terms, ["Personal", "Company"])
        XCTAssertFalse(companyOnly.enhancementSection.isEmpty)
        clock.set(expiry)
        XCTAssertEqual(vocabulary.terms, ["Personal"])
        XCTAssertTrue(vocabulary.enhancementSection.contains("Personal"))
        XCTAssertFalse(vocabulary.enhancementSection.contains("Company"))
        XCTAssertEqual(companyOnly.terms, [])
        XCTAssertEqual(companyOnly.enhancementSection, "")
        // The existing Whisper prompt consumer wraps the recording's current terms.
        let emptyHints = ResolvedVocabularySnapshot(revision: 0, words: companyOnly.terms, omittedCount: 0)
        XCTAssertNil(emptyHints.whisperPrompt(preserving: nil))
        XCTAssertEqual(emptyHints.whisperPrompt(preserving: "Personal prompt"), "Personal prompt")
        let fallbackHints = ResolvedVocabularySnapshot(revision: 0, words: vocabulary.terms, omittedCount: 0)
        XCTAssertEqual(fallbackHints.whisperPrompt(preserving: nil), "Important vocabulary: Personal")
    }

    func testPreparedScreenNamesKeepLeaseAndSavedPriority() async {
        let lease = CompanyVocabularyLease()
        let preparation = RecordingVocabularyPreparation(savedVocabulary: bound(clock: Clock(beforeExpiry), lease: lease))
        preparation.prepareScreenNames(in: "synthetic", language: nil, extract: { _, _ in
            ["personal", "Screen Name", "screen name"]
        })
        await preparation.waitForPreparation()
        XCTAssertEqual(preparation.current.terms, ["Personal", "Company", "Screen Name"])
        lease.invalidate()
        XCTAssertEqual(preparation.finish().terms, ["Personal", "Screen Name"])
        XCTAssertFalse(preparation.current.enhancementSection.contains("Company"))
    }

    func testRevocationDuringScreenPreparationCannotRestoreCompanyTerms() async {
        let lease = CompanyVocabularyLease()
        let gate = CorrectionGate()
        let preparation = RecordingVocabularyPreparation(savedVocabulary: bound(clock: Clock(beforeExpiry), lease: lease))
        preparation.prepareScreenNames(in: "synthetic", language: nil, extract: { _, _ in
            _ = await gate.correct("screen extraction", terms: [])
            return ["Screen Name"]
        })
        await gate.waitForCall(1)
        lease.invalidate()
        await gate.release("ready")
        await preparation.waitForPreparation()
        XCTAssertEqual(preparation.finish().terms, ["Personal", "Screen Name"])
    }

    func testRevocationDuringCorrectionDiscardsResultAndRecomputesOriginalOnce() async throws {
        let lease = CompanyVocabularyLease()
        let vocabulary = bound(clock: Clock(beforeExpiry), lease: lease)
        let gate = CorrectionGate()
        let task = Task { try await vocabulary.correctTranscription("original", using: { text, terms in
            await gate.correct(text, terms: terms)
        }) }
        await gate.waitForCall(1)
        lease.invalidate()
        await gate.release("stale company correction")
        await gate.waitForCall(2)
        await gate.release("local correction")
        let output = try await task.value
        XCTAssertEqual(output, "local correction")
        let calls = await gate.calls
        XCTAssertEqual(calls, [.init(text: "original", terms: ["Personal", "Company"]),
                               .init(text: "original", terms: ["Personal"])])
    }

    func testExpiryDuringCorrectionDiscardsResultBeforePublication() async throws {
        let clock = Clock(beforeExpiry)
        let vocabulary = bound(clock: clock)
        let gate = CorrectionGate()
        let task = Task { try await vocabulary.correctTranscription("original", using: { text, terms in
            await gate.correct(text, terms: terms)
        }) }
        await gate.waitForCall(1)
        clock.set(expiry)
        await gate.release("stale company correction")
        await gate.waitForCall(2)
        await gate.release("local correction")
        let output = try await task.value
        XCTAssertEqual(output, "local correction")
        let calls = await gate.calls
        XCTAssertEqual(calls.map(\.terms), [["Personal", "Company"], ["Personal"]])
    }

    func testRevokedCompanyOnlyCorrectionReturnsOriginalWithoutSecondPass() async throws {
        let lease = CompanyVocabularyLease()
        let vocabulary = bound(local: [], clock: Clock(beforeExpiry), lease: lease)
        let gate = CorrectionGate()
        let task = Task { try await vocabulary.correctTranscription("original", using: { text, terms in
            await gate.correct(text, terms: terms)
        }) }
        await gate.waitForCall(1)
        lease.invalidate()
        await gate.release("stale company correction")
        let output = try await task.value
        XCTAssertEqual(output, "original")
        let count = await gate.calls.count
        XCTAssertEqual(count, 1)
    }

    func testUnstableFallbackReturnsOriginalWithoutLooping() async throws {
        let clock = Clock(beforeExpiry)
        let vocabulary = bound(clock: clock)
        let gate = CorrectionGate()
        let task = Task { try await vocabulary.correctTranscription("original", using: { text, terms in
            await gate.correct(text, terms: terms)
        }) }
        await gate.waitForCall(1)
        clock.set(expiry)
        await gate.release("stale company correction")
        await gate.waitForCall(2)
        // A clock rollback changes eligibility again while the bounded retry waits.
        clock.set(beforeExpiry)
        await gate.release("unstable fallback correction")
        let output = try await task.value
        XCTAssertEqual(output, "original")
        let calls = await gate.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.map(\.text), ["original", "original"])
    }

    func testCancellationRejectsLateInitialCorrectionCallback() async {
        let lease = CompanyVocabularyLease()
        let vocabulary = bound(clock: Clock(beforeExpiry), lease: lease)
        let gate = CorrectionGate()
        let task = Task { try await vocabulary.correctTranscription("original", using: { text, terms in
            await gate.correct(text, terms: terms)
        }) }
        await gate.waitForCall(1)
        task.cancel()
        lease.invalidate()
        await gate.release("late callback")
        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate instead of publishing or retrying a late result.")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let count = await gate.calls.count
        XCTAssertEqual(count, 1)
    }

    func testCancellationRejectsLateFallbackCorrectionCallback() async {
        let lease = CompanyVocabularyLease()
        let vocabulary = bound(clock: Clock(beforeExpiry), lease: lease)
        let gate = CorrectionGate()
        let task = Task { try await vocabulary.correctTranscription("original", using: { text, terms in
            await gate.correct(text, terms: terms)
        }) }
        await gate.waitForCall(1)
        lease.invalidate()
        await gate.release("stale company correction")
        await gate.waitForCall(2)
        task.cancel()
        await gate.release("late fallback callback")
        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate from the fallback too.")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let count = await gate.calls.count
        XCTAssertEqual(count, 2)
    }

    func testStablePersonalCorrectionPublishesOnceAndEmptyVocabularySkipsWork() async throws {
        let vocabulary = RecordingVocabulary(savedTerms: ["Personal"])
        let gate = CorrectionGate()
        let task = Task { try await vocabulary.correctTranscription("original", using: { text, terms in
            await gate.correct(text, terms: terms)
        }) }
        await gate.waitForCall(1)
        await gate.release("personal correction")
        let output = try await task.value
        XCTAssertEqual(output, "personal correction")
        let count = await gate.calls.count
        XCTAssertEqual(count, 1)
        let empty = try await RecordingVocabulary().correctTranscription("original", using: { _, _ in
            XCTFail("Empty vocabulary must not start correction work.")
            return "unexpected"
        })
        XCTAssertEqual(empty, "original")
    }
}
