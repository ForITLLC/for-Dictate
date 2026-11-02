import Foundation
import SwiftData
import XCTest
@testable import VoiceInk

/// Exercises the unmodified production service using only synthetic in-memory
/// stores, an explicitly owned cache, and an explicitly owned temporary catalog.
@MainActor
final class SharedVocabularyServiceTests: XCTestCase {
    private enum SyntheticFailure: Error { case timedOut, missingRow, retainedService }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([VocabularyWord.self])
        let configuration = ModelConfiguration(
            "SyntheticVocabulary-\(UUID().uuidString)", schema: schema,
            isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    private func withService(
        _ body: @MainActor (SharedVocabularyService, SharedVocabularyCache) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictate-vocabulary-service-synthetic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let files = SharedVocabularyFiles(
            catalogURL: directory.appendingPathComponent("Shared/vocabulary-v1.json"),
            preferencesURL: directory.appendingPathComponent("Personal/preferences-v1.json")
        )
        let cache = SharedVocabularyCache()
        var service: SharedVocabularyService? = SharedVocabularyService(files: files, cache: cache)
        weak var weakService = service
        var bodyError: Error?
        do { try await body(service!, cache) }
        catch { bodyError = error }

        // Every detached save is awaited by its test. Release the service (which
        // removes its observer), then give queued weak-self callbacks a turn
        // before removing the owned files. Never use the global service/cache.
        service = nil
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        await Task.yield()
        guard weakService == nil else {
            XCTFail("Synthetic service remained alive; its temporary directory was retained for safe teardown.")
            throw SyntheticFailure.retainedService
        }
        try FileManager.default.removeItem(at: directory)
        if let bodyError { throw bodyError }
    }

    private func waitForSnapshot(
        in cache: SharedVocabularyCache,
        matching predicate: (ResolvedVocabularySnapshot) -> Bool
    ) async throws -> ResolvedVocabularySnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            let snapshot = cache.snapshot
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The vocabulary cache did not reach the expected committed synthetic state.")
        throw SyntheticFailure.timedOut
    }

    func testSeparateContextCommittedInsertEditAndDeleteRefreshCache() async throws {
        let container = try makeContainer()
        let main = ModelContext(container)
        main.autosaveEnabled = false
        try await withService { service, cache in
            service.configure(context: main)
            try await Task.detached {
                let writer = ModelContext(container)
                writer.autosaveEnabled = false
                writer.insert(VocabularyWord(word: "Synthetic learned original"))
                try writer.save()
            }.value
            _ = try await waitForSnapshot(in: cache) { $0.words.contains("Synthetic learned original") }

            // Prime the configured context's identity map before a different
            // context edits the same row; a reused fetch must not return stale text.
            let registered = try XCTUnwrap(main.fetch(FetchDescriptor<VocabularyWord>()).first)
            XCTAssertEqual(registered.word, "Synthetic learned original")
            try await Task.detached {
                let writer = ModelContext(container)
                writer.autosaveEnabled = false
                guard let row = try writer.fetch(FetchDescriptor<VocabularyWord>()).first else {
                    throw SyntheticFailure.missingRow
                }
                row.word = "Synthetic learned edit"
                try writer.save()
            }.value
            let edited = try await waitForSnapshot(in: cache) {
                $0.words.contains("Synthetic learned edit") && !$0.words.contains("Synthetic learned original")
            }
            XCTAssertTrue(edited.words.contains("Synthetic learned edit"))
            try await Task.detached {
                let writer = ModelContext(container)
                writer.autosaveEnabled = false
                guard let row = try writer.fetch(FetchDescriptor<VocabularyWord>()).first else {
                    throw SyntheticFailure.missingRow
                }
                writer.delete(row)
                try writer.save()
            }.value
            let deleted = try await waitForSnapshot(in: cache) {
                !$0.words.contains("Synthetic learned edit") && !$0.words.contains("Synthetic learned original")
            }
            XCTAssertTrue(deleted.words.contains("ForIT"))
            withExtendedLifetime(registered) {}
        }
    }

    func testUnrelatedContainerSaveIsIgnored() async throws {
        let bound = try makeContainer()
        let unrelated = try makeContainer()
        let main = ModelContext(bound)
        main.autosaveEnabled = false
        try await withService { service, cache in
            service.configure(context: main)
            // A synthetic marker makes an unwanted refresh observable even when
            // re-fetching the bound store would otherwise produce identical words.
            let marker = ResolvedVocabularySnapshot(revision: 77, words: ["Synthetic isolation marker"], omittedCount: 0)
            cache.replace(with: marker)
            let saved = expectation(description: "The unrelated context delivered didSave")
            let unrelatedID = ObjectIdentifier(unrelated)
            let observer = NotificationCenter.default.addObserver(
                forName: ModelContext.didSave, object: nil, queue: nil
            ) { notification in
                if let context = notification.object as? ModelContext,
                    ObjectIdentifier(context.container) == unrelatedID { saved.fulfill() }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            try await Task.detached {
                let writer = ModelContext(unrelated)
                writer.autosaveEnabled = false
                writer.insert(VocabularyWord(word: "Synthetic unrelated vocabulary"))
                try writer.save()
            }.value
            await fulfillment(of: [saved], timeout: 2)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(cache.snapshot, marker)

            // Prove that the observer is still live for its configured container.
            main.insert(VocabularyWord(word: "Synthetic bound verification"))
            try main.save()
            let current = try await waitForSnapshot(in: cache) { $0.words.contains("Synthetic bound verification") }
            XCTAssertFalse(current.words.contains("Synthetic unrelated vocabulary"))
        }
    }

    func testSeparateContextSaveExcludesUnsavedConfiguredContextInsertAndEdit() async throws {
        let container = try makeContainer()
        let main = ModelContext(container)
        main.autosaveEnabled = false
        let original = VocabularyWord(word: "Synthetic committed original")
        main.insert(original)
        try main.save()
        defer { main.rollback() }
        try await withService { service, cache in
            service.configure(context: main)
            XCTAssertTrue(cache.snapshot.words.contains("Synthetic committed original"))
            original.word = "Synthetic unsaved edit"
            main.insert(VocabularyWord(word: "Synthetic unsaved insert"))
            try await Task.detached {
                let writer = ModelContext(container)
                writer.autosaveEnabled = false
                writer.insert(VocabularyWord(word: "Synthetic committed background"))
                try writer.save()
            }.value
            let committed = try await waitForSnapshot(in: cache) {
                $0.words.contains("Synthetic committed original") && $0.words.contains("Synthetic committed background")
            }
            XCTAssertFalse(committed.words.contains("Synthetic unsaved edit"))
            XCTAssertFalse(committed.words.contains("Synthetic unsaved insert"))
            XCTAssertEqual(original.word, "Synthetic unsaved edit", "Refreshing must not mutate the editing context.")
        }
    }

    func testReconfigurationRejectsCallbackQueuedByPreviousContextBinding() async throws {
        let container = try makeContainer()
        let original = ModelContext(container)
        let replacement = ModelContext(container)
        original.autosaveEnabled = false
        replacement.autosaveEnabled = false
        try await withService { service, cache in
            service.configure(context: original)
            original.insert(VocabularyWord(word: "Synthetic previous binding"))
            try original.save()
            // No suspension occurs between save and reconfiguration: its old
            // MainActor callback is queued, while this test still owns the actor.
            service.configure(context: replacement)
            XCTAssertTrue(cache.snapshot.words.contains("Synthetic previous binding"))
            let marker = ResolvedVocabularySnapshot(revision: 88, words: ["Synthetic reconfiguration marker"], omittedCount: 0)
            cache.replace(with: marker)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(cache.snapshot, marker, "A queued callback from the old configuration must be ignored.")
            replacement.insert(VocabularyWord(word: "Synthetic replacement binding"))
            try replacement.save()
            _ = try await waitForSnapshot(in: cache) { $0.words.contains("Synthetic replacement binding") }
        }
    }
}
