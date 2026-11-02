import Foundation
import XCTest
@testable import VoiceInk

final class SharedVocabularyFileTests: XCTestCase {
    private func withFiles(_ body: (SharedVocabularyFiles) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(SharedVocabularyFiles(
            catalogURL: directory.appendingPathComponent("Shared/vocabulary-v1.json"),
            preferencesURL: directory.appendingPathComponent("Private/preferences.json")
        ))
    }

    func testExplicitUpdatePersistsCatalogButNeverChangesPersonalPreferences() throws {
        try withFiles { files in
            let original = try SharedVocabularyCatalog.bundled.validated()
            try SharedVocabularyFiles.write(original, to: files.catalogURL)
            let preferences = try SharedVocabularyPreferences(suppressed: ["ForIT"], overrides: ["Tinycast": "Tiny Cast"]).validated()
            try SharedVocabularyFiles.write(preferences, to: files.preferencesURL)
            let before = try SharedVocabularyFiles.readBounded(files.preferencesURL)
            let update = SharedVocabularyCatalog(revision: 2, terms: ["ForIT", "Tinycast", "New Term"])
            let installed = try files.installCatalog(SharedVocabularyFiles.encode(update), replacing: original)
            XCTAssertEqual(installed.revision, 2)
            XCTAssertEqual(try SharedVocabularyFiles.decodeCatalog(SharedVocabularyFiles.readBounded(files.catalogURL)), installed)
            XCTAssertEqual(try SharedVocabularyFiles.readBounded(files.preferencesURL), before)
        }
    }

    func testStaleConflictingAndCorruptUpdatesLeaveLastValidFileUntouched() throws {
        try withFiles { files in
            let current = try SharedVocabularyCatalog(revision: 4, terms: ["Current"]).validated()
            try SharedVocabularyFiles.write(current, to: files.catalogURL)
            let before = try SharedVocabularyFiles.readBounded(files.catalogURL)
            for update in [
                try SharedVocabularyFiles.encode(SharedVocabularyCatalog(revision: 3, terms: ["Old"])),
                try SharedVocabularyFiles.encode(SharedVocabularyCatalog(revision: 4, terms: ["Conflict"])),
                Data("not json".utf8),
            ] {
                XCTAssertThrowsError(try files.installCatalog(update, replacing: current))
                XCTAssertEqual(try SharedVocabularyFiles.readBounded(files.catalogURL), before)
            }
            XCTAssertEqual(try files.installCatalog(before, replacing: current), current)
        }
    }

    func testExternalNewerCatalogPreventsStaleWriter() throws {
        try withFiles { files in
            let cached = try SharedVocabularyCatalog(revision: 1, terms: ["Cached"]).validated()
            let external = try SharedVocabularyCatalog(revision: 3, terms: ["External"]).validated()
            try SharedVocabularyFiles.write(external, to: files.catalogURL)
            let candidate = SharedVocabularyCatalog(revision: 2, terms: ["Stale import"])
            XCTAssertThrowsError(try files.installCatalog(SharedVocabularyFiles.encode(candidate), replacing: cached))
            XCTAssertEqual(try SharedVocabularyFiles.decodeCatalog(SharedVocabularyFiles.readBounded(files.catalogURL)), external)
        }
    }

    func testUnreadableExistingCatalogIsPreservedForRecovery() throws {
        try withFiles { files in
            try FileManager.default.createDirectory(at: files.catalogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let corrupt = Data("{broken but preserved".utf8)
            try corrupt.write(to: files.catalogURL)
            let update = SharedVocabularyCatalog(revision: 2, terms: ["Valid"])
            XCTAssertThrowsError(try files.installCatalog(SharedVocabularyFiles.encode(update), replacing: .bundled))
            XCTAssertEqual(try SharedVocabularyFiles.readBounded(files.catalogURL), corrupt)
        }
    }

    func testBoundedFileReadRejectsOversizedInput() throws {
        try withFiles { files in
            let oversized = Data(repeating: 32, count: SharedVocabularyLimits.fileBytes + 1)
            let url = files.catalogURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("oversized.json")
            try oversized.write(to: url)
            XCTAssertThrowsError(try SharedVocabularyFiles.readBounded(url))
        }
    }

    func testBusyCooperatingWriterFailsWithoutReplacingNewerCatalog() throws {
        try withFiles { files in
            let cached = try SharedVocabularyCatalog(revision: 1, terms: ["Cached"]).validated()
            let newer = try SharedVocabularyCatalog(revision: 3, terms: ["Newer"]).validated()
            try SharedVocabularyFiles.write(newer, to: files.catalogURL)
            let bytes = try SharedVocabularyFiles.readBounded(files.catalogURL)
            let update = try SharedVocabularyFiles.encode(SharedVocabularyCatalog(revision: 4, terms: ["Update"]))
            try SharedVocabularyCatalogLock.withExclusiveAccess(at: files.catalogURL) {
                XCTAssertThrowsError(try files.installCatalog(update, replacing: cached)) { error in
                    guard let vocabularyError = error as? SharedVocabularyError,
                        case .catalogBusy = vocabularyError else {
                        return XCTFail("Expected a nonblocking busy result, received \(error)")
                    }
                }
                XCTAssertEqual(try SharedVocabularyFiles.readBounded(files.catalogURL), bytes)
                let mode = try FileManager.default.attributesOfItem(
                    atPath: files.catalogURL.appendingPathExtension("lock").path
                )[.posixPermissions] as? NSNumber
                XCTAssertEqual(mode?.intValue, 0o600)
            }
            // Releasing the first descriptor permits a subsequent managed update.
            XCTAssertEqual(try files.installCatalog(update, replacing: cached).revision, 4)
        }
    }

    func testRepairedPreferencesCanBeReloadedWithoutRestartAndRefreshSnapshot() throws {
        try withFiles { files in
            let catalog = try SharedVocabularyCatalog(revision: 1, terms: ["ForIT", "Tinycast"]).validated()
            let initial = try SharedVocabularyPreferences(suppressed: ["ForIT"]).validated()
            try SharedVocabularyFiles.write(initial, to: files.preferencesURL)
            var choices = try files.loadPreferences()
            let cache = SharedVocabularyCache()
            cache.replace(with: SharedVocabularyResolver.resolve(catalog: catalog, preferences: choices, personalWords: []))
            let lastValid = cache.snapshot
            let corrupt = Data("{broken preferences".utf8)
            try corrupt.write(to: files.preferencesURL)
            do {
                choices = try files.loadPreferences()
                XCTFail("Corrupt preferences should not load")
            } catch {
                XCTAssertEqual(choices, initial)
                XCTAssertEqual(cache.snapshot, lastValid)
                XCTAssertEqual(try SharedVocabularyFiles.readBounded(files.preferencesURL), corrupt)
            }
            let repaired = try SharedVocabularyPreferences(overrides: ["ForIT": "For IT"]).validated()
            try SharedVocabularyFiles.write(repaired, to: files.preferencesURL)
            choices = try files.loadPreferences()
            cache.replace(with: SharedVocabularyResolver.resolve(catalog: catalog, preferences: choices, personalWords: []))
            XCTAssertEqual(choices, repaired)
            XCTAssertEqual(cache.snapshot.words, ["For IT", "Tinycast"])
            XCTAssertNotEqual(cache.snapshot, lastValid)
        }
    }

    func testAddingSharedTermPersistsRevisionAndLeavesPersonalOverlayUnchanged() throws {
        try withFiles { files in
            let current = try SharedVocabularyCatalog(revision: 7, terms: ["ForIT", "Tinycast"]).validated()
            try SharedVocabularyFiles.write(current, to: files.catalogURL)
            let preferences = try SharedVocabularyPreferences(
                suppressed: ["ForIT"], overrides: ["Tinycast": "Tiny Cast"]
            ).validated()
            try SharedVocabularyFiles.write(preferences, to: files.preferencesURL)
            let personalBytes = try SharedVocabularyFiles.readBounded(files.preferencesURL)
            let personalWords = ["My personal word"]
            let updated = try files.addSharedTerm("New shared term", to: current)
            XCTAssertEqual(updated.revision, 8)
            XCTAssertEqual(Set(updated.terms), ["ForIT", "Tinycast", "New shared term"])
            XCTAssertEqual(try SharedVocabularyFiles.decodeCatalog(SharedVocabularyFiles.readBounded(files.catalogURL)), updated)
            XCTAssertEqual(try SharedVocabularyFiles.readBounded(files.preferencesURL), personalBytes)
            let resolved = SharedVocabularyResolver.resolve(
                catalog: updated, preferences: try files.loadPreferences(), personalWords: personalWords
            )
            XCTAssertEqual(resolved.words, ["My personal word", "New shared term", "Tiny Cast"])
            XCTAssertEqual(personalWords, ["My personal word"])
            let catalogBytes = try SharedVocabularyFiles.readBounded(files.catalogURL)
            XCTAssertThrowsError(try files.addSharedTerm(" NEW SHARED TERM ", to: updated))
            XCTAssertEqual(try SharedVocabularyFiles.readBounded(files.catalogURL), catalogBytes)
        }
    }

    func testAddingSharedTermRequiresReloadAfterAnotherAppChangesCatalog() throws {
        try withFiles { files in
            let displayed = try SharedVocabularyCatalog(revision: 1, terms: ["Original"]).validated()
            let external = try SharedVocabularyCatalog(revision: 2, terms: ["Original", "External"]).validated()
            try SharedVocabularyFiles.write(external, to: files.catalogURL)
            let before = try SharedVocabularyFiles.readBounded(files.catalogURL)
            XCTAssertThrowsError(try files.addSharedTerm("New", to: displayed)) { error in
                guard let vocabularyError = error as? SharedVocabularyError,
                    case .catalogChanged = vocabularyError else {
                    return XCTFail("Expected stale displayed catalog rejection, received \(error)")
                }
            }
            XCTAssertEqual(try SharedVocabularyFiles.readBounded(files.catalogURL), before)
            let reloaded = try SharedVocabularyFiles.decodeCatalog(SharedVocabularyFiles.readBounded(files.catalogURL))
            let updated = try files.addSharedTerm("New", to: reloaded)
            XCTAssertEqual(updated.revision, 3)
            XCTAssertEqual(Set(updated.terms), ["Original", "External", "New"])
        }
    }
}
