import Dispatch
import Foundation
import SwiftData
import XCTest
@testable import VoiceInk

/// Timing observations, not latency gates. The runner retains numeric JSON in
/// swift-test.log alongside its source hashes. Fixtures never use the global
/// service/cache, standard catalog paths, user stores, audio or network.
/// These measurements do not describe the installed app or Ben's Mac.
@MainActor
final class SharedVocabularyTimingTests: XCTestCase {
    private struct Fixture {
        let name: String
        let catalog: SharedVocabularyCatalog
        let personalWords: [String]
        let catalogBytes: Int

        var expected: ResolvedVocabularySnapshot {
            SharedVocabularyResolver.resolve(catalog: catalog, preferences: .init(), personalWords: personalWords)
        }
    }

    private enum FixtureFailure: Error { case retainedService }

    private func fixtures() throws -> [Fixture] {
        // Short terms reach the count bounds; 160-byte NFC terms reach the byte
        // bounds. Counts are deterministic, with disjoint personal/shared keys.
        try [
            ("realistic_32_shared_32_personal", 32, 32, false),
            ("supported_count_bounds", SharedVocabularyLimits.catalogTerms, SharedVocabularyLimits.personalTerms, false),
            ("supported_count_and_term_byte_bounds", SharedVocabularyLimits.catalogTerms, SharedVocabularyLimits.personalTerms, true),
        ].map { scenario in
            let (name, sharedCount, personalCount, longTerms) = scenario
            func term(_ prefix: String, _ index: Int) -> String {
                let short = String(format: "%@%04d-", prefix, index)
                return longTerms ? short + String(repeating: "é", count: 77) : short
            }
            let catalog = try SharedVocabularyCatalog(
                revision: 7, terms: (0..<sharedCount).map { term("S", $0) }
            ).validated()
            let personal = (0..<personalCount).map { term("P", $0) }
            if longTerms {
                XCTAssertTrue((catalog.terms + personal).allSatisfy { $0.utf8.count == SharedVocabularyLimits.termBytes })
            }
            let encoded = try SharedVocabularyFiles.encode(catalog)
            XCTAssertLessThanOrEqual(encoded.count, SharedVocabularyLimits.fileBytes)
            return Fixture(name: name, catalog: catalog, personalWords: personal, catalogBytes: encoded.count)
        }
    }

    private func assertSnapshot(_ snapshot: ResolvedVocabularySnapshot, fixture: Fixture) {
        // Boolean comparisons keep even synthetic vocabulary out of failure text.
        XCTAssertTrue(snapshot == fixture.expected, "Resolved synthetic snapshot changed.")
        XCTAssertEqual(snapshot.revision, fixture.catalog.revision)
        XCTAssertLessThanOrEqual(snapshot.words.count, SharedVocabularyLimits.resolvedTerms)
        XCTAssertLessThanOrEqual(snapshot.words.joined(separator: ", ").utf8.count, SharedVocabularyLimits.resolvedBytes)
        XCTAssertEqual(snapshot.omittedCount, fixture.catalog.terms.count + fixture.personalWords.count - snapshot.words.count)
        XCTAssertFalse(snapshot.words.isEmpty)
        XCTAssertTrue(snapshot.words.allSatisfy { fixture.personalWords.contains($0) || fixture.catalog.terms.contains($0) })
        XCTAssertTrue(snapshot.words.first == fixture.personalWords.sorted().first, "Personal priority changed.")
        if fixture.name == "supported_count_bounds" {
            XCTAssertEqual(snapshot.words.count, SharedVocabularyLimits.resolvedTerms)
        }
        if fixture.name == "supported_count_and_term_byte_bounds" {
            // Every additional whole 160-byte term would exceed the byte budget.
            XCTAssertGreaterThan(snapshot.words.joined(separator: ", ").utf8.count + 2 + SharedVocabularyLimits.termBytes,
                                 SharedVocabularyLimits.resolvedBytes)
        }
    }

    private func assertPrompt(_ prompt: String?, snapshot: ResolvedVocabularySnapshot, original: String) throws {
        let full = try XCTUnwrap(prompt)
        let prefix = original + "\n\nImportant vocabulary: "
        XCTAssertTrue(full.hasPrefix(prefix), "Custom prompt was not preserved.")
        guard full.hasPrefix(prefix) else { return }
        let terms = String(full.dropFirst(prefix.count)).components(separatedBy: ", ")
        XCTAssertFalse(terms.isEmpty)
        XCTAssertLessThanOrEqual(terms.count, SharedVocabularyLimits.whisperTerms)
        XCTAssertLessThanOrEqual(full.utf8.count - original.utf8.count - 2, SharedVocabularyLimits.whisperHintBytes)
        XCTAssertTrue(terms.allSatisfy { snapshot.words.contains($0) }, "Hint contains a partial or unknown term.")
    }

    /// Nearest-rank percentiles of per-batch elapsed time / operations per batch.
    /// Assertions, fixture construction, JSON and filesystem work are outside the
    /// timed regions. Consumed numeric results keep each operation observable.
    private func observe(
        operation: String, fixture: Fixture, warmupBatches: Int,
        samples: Int, operationsPerSample: Int, expectedResult: Int,
        excludedWork: String, body: @MainActor () -> Int
    ) throws {
        for _ in 0..<warmupBatches {
            var consumed = 0
            for _ in 0..<operationsPerSample { consumed += body() }
            XCTAssertEqual(consumed, expectedResult * operationsPerSample)
        }
        var observations: [Double] = []
        for _ in 0..<samples {
            var consumed = 0
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<operationsPerSample { consumed += body() }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertGreaterThanOrEqual(end, start)
            XCTAssertEqual(consumed, expectedResult * operationsPerSample)
            observations.append(Double(end - start) / Double(operationsPerSample))
        }
        let ordered = observations.sorted()
        func percentile(_ fraction: Double) -> Double {
            ordered[max(0, Int((Double(ordered.count) * fraction).rounded(.up)) - 1)]
        }
        #if DEBUG
            let configuration = "debug"
        #else
            let configuration = "release"
        #endif
        #if arch(arm64)
            let architecture = "arm64"
        #elseif arch(x86_64)
            let architecture = "x86_64"
        #else
            let architecture = "other"
        #endif
        let snapshot = fixture.expected
        let report: [String: Any] = [
            "schema": "forit.dictate.vocabulary-timing.v1",
            "fixtureVersion": 1,
            "productionReferenceCommit": "e2204a2317af761a0e828d1eb7a44c37f49701d3",
            "scope": "synthetic_fixture_not_installed_app",
            "operation": operation, "scenario": fixture.name,
            "configuration": configuration, "architecture": architecture,
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "logicalProcessorCount": ProcessInfo.processInfo.processorCount,
            "clock": "DispatchTime.uptimeNanoseconds", "units": "nanoseconds_per_operation",
            "execution": "serial_main_actor_uncontended_cache",
            "storage": operation.hasPrefix("ai_cleanup") ? "in_memory_swiftdata" : "in_memory_snapshot",
            "dataOrigin": "deterministic_synthetic_fixtures",
            "storeMode": operation.hasPrefix("ai_cleanup") ? "in_memory_swiftdata" : "immutable_cache",
            "measurementOverhead": "closure_loop_and_numeric_result_count_included_no_subtraction",
            "warmupBatches": warmupBatches, "sampleCount": samples,
            "operationsPerSample": operationsPerSample,
            "percentileMethod": "nearest_rank_of_amortized_batch_samples",
            "samples": observations, "p50": percentile(0.50), "p95": percentile(0.95), "max": ordered.last!,
            "sharedTerms": fixture.catalog.terms.count, "personalTerms": fixture.personalWords.count,
            "personalOverrides": 0, "suppressedSharedTerms": 0,
            "catalogBytes": fixture.catalogBytes, "resolvedTerms": snapshot.words.count,
            "resolvedBytes": snapshot.words.joined(separator: ", ").utf8.count,
            "omittedTerms": snapshot.omittedCount,
            "excludedWork": excludedWork, "latencyPassThreshold": NSNull(),
            "acceptance": "observations_require_overall_xctest_success",
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("FORIT_VOCABULARY_TIMING " + String(decoding: data, as: UTF8.self))
    }

    func testObserveProductionCacheAndWhisperPromptTiming() throws {
        let original = "Synthetic Japanese language prompt 日本語。"
        for fixture in try fixtures() {
            let cache = SharedVocabularyCache()
            cache.replace(with: fixture.expected)
            let captured = cache.snapshot
            assertSnapshot(captured, fixture: fixture)
            let expectedPrompt = try XCTUnwrap(captured.whisperPrompt(preserving: original))
            try assertPrompt(expectedPrompt, snapshot: captured, original: original)

            try observe(operation: "cache_snapshot", fixture: fixture, warmupBatches: 5,
                        samples: 31, operationsPerSample: 250, expectedResult: captured.words.count,
                        excludedWork: "fixture_build_and_resolution_refresh_io_contention_recording_decoder_and_provider") {
                cache.snapshot.words.count
            }
            try observe(operation: "cache_snapshot_and_whisper_prompt", fixture: fixture, warmupBatches: 5,
                        samples: 31, operationsPerSample: 100, expectedResult: expectedPrompt.utf8.count,
                        excludedWork: "fixture_build_and_resolution_refresh_io_contention_recording_decoder_and_provider") {
                let snapshot = cache.snapshot
                return snapshot.whisperPrompt(preserving: original)?.utf8.count ?? 0
            }
            XCTAssertTrue(cache.snapshot == captured, "Reading a hint changed the cache.")
            try assertPrompt(cache.snapshot.whisperPrompt(preserving: original), snapshot: captured, original: original)
        }
    }

    private func withProductionService(
        fixture: Fixture,
        body: @MainActor (SharedVocabularyService, SharedVocabularyCache, ModelContext) throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictate-vocabulary-timing-synthetic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        // Filesystem setup and SwiftData inserts are never part of a timing sample.
        // An outer defer also cleans up if fixture setup fails before configuration.
        var safeToRemove = true
        defer { if safeToRemove { try? FileManager.default.removeItem(at: directory) } }
        let files = SharedVocabularyFiles(
            catalogURL: directory.appendingPathComponent("Shared/vocabulary-v1.json"),
            preferencesURL: directory.appendingPathComponent("Personal/preferences-v1.json")
        )
        try SharedVocabularyFiles.write(fixture.catalog, to: files.catalogURL)
        let schema = Schema([VocabularyWord.self])
        let configuration = ModelConfiguration(
            "SyntheticVocabularyTiming-\(UUID().uuidString)", schema: schema,
            isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for word in fixture.personalWords { context.insert(VocabularyWord(word: word)) }
        try context.save() // Before service registration: no queued didSave refresh.
        defer { context.rollback() }
        let cache = SharedVocabularyCache()
        var service: SharedVocabularyService? = SharedVocabularyService(files: files, cache: cache)
        weak var weakService = service
        service!.configure(context: context)
        // The production refresh must read committed values in its fresh context,
        // rather than leak an unsaved edit from this configured context.
        context.insert(VocabularyWord(word: "A-UNSAVED-SYNTHETIC"))
        var bodyError: Error?
        do { try body(service!, cache, context) }
        catch { bodyError = error }
        service = nil
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        await Task.yield()
        guard weakService == nil else {
            safeToRemove = false
            XCTFail("Synthetic service retained; its owned temporary files were preserved.")
            throw FixtureFailure.retainedService
        }
        if let bodyError { throw bodyError }
    }

    func testObserveProductionAICleanupPersonalRefreshTiming() async throws {
        // CustomVocabularyService.getCustomVocabulary calls this exact production
        // refresh before reading its cache. That wrapper is singleton-only and
        // would touch standard user files, so it is deliberately NOT instantiated.
        // This observes the real refresh component, not a copied fetch/resolver,
        // full AI cleanup, prompt assembly, provider latency or end-to-end use.
        for fixture in try fixtures() {
            try await withProductionService(fixture: fixture) { service, cache, context in
                assertSnapshot(cache.snapshot, fixture: fixture)
                XCTAssertNil(service.warning)
                try observe(operation: "ai_cleanup_committed_personal_refresh_and_cache_snapshot",
                            fixture: fixture, warmupBatches: 3, samples: 21, operationsPerSample: 1,
                            expectedResult: fixture.expected.words.count,
                            excludedWork: "initial_catalog_io_store_creation_inserts_singleton_wrapper_string_join_and_ai_provider") {
                    service.refreshPersonalWords(from: context)
                    return cache.snapshot.words.count
                }
                assertSnapshot(cache.snapshot, fixture: fixture)
                XCTAssertNil(service.warning)
                XCTAssertTrue(context.hasChanges, "Refresh must not save or discard the caller's unsaved changes.")
                XCTAssertFalse(cache.snapshot.words.contains("A-UNSAVED-SYNTHETIC"))
            }
        }
    }
}
