import Foundation
import SwiftData
import XCTest
@testable import VoiceInk

/// Runs without the app executable: every container is in-memory, every endpoint is under a
/// newly created synthetic temporary directory, and no user Application Support path is used.
@MainActor
final class TinycastHistoryExporterTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Transcription.self])
        let configuration = ModelConfiguration("SyntheticHistory-\(UUID().uuidString)", schema: schema,
                                               isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: configuration)
    }

    private func withExporter(
        _ body: @MainActor (TinycastHistoryExporter, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-exporter-synthetic-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let exporter = TinycastHistoryExporter(baseDirectory: root, debounceInterval: .milliseconds(20))
        let snapshot = root.appendingPathComponent("io.forit.dictate/Integrations/Tinycast/history-v1.json")
        do {
            try await body(exporter, snapshot)
            await exporter.stop()
            try FileManager.default.removeItem(at: root)
        } catch {
            await exporter.stop()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func waitForSnapshot(
        at url: URL, timeout: Duration = .seconds(5),
        matching predicate: ([[String: Any]]) -> Bool
    ) async throws -> (Data, [[String: Any]]) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let data = try? Data(contentsOf: url),
                let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                envelope["schemaVersion"] as? Int == 1,
                let entries = envelope["entries"] as? [[String: Any]], predicate(entries) {
                return (data, entries)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Synthetic history export did not reach the expected committed state within its deadline.")
        throw SyntheticTimeout.expired
    }

    private enum SyntheticTimeout: Error { case expired }

    func testBackgroundContextSaveEditAndDeleteRefreshActualSnapshot() async throws {
        let container = try makeContainer()
        let id = UUID(uuidString: "12345678-1234-4234-8234-123456789012")!
        try await withExporter { exporter, snapshot in
            exporter.start(container: container)
            _ = try await waitForSnapshot(at: snapshot) { $0.isEmpty }

            try await Task.detached {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                let row = Transcription(text: "Synthetic original", duration: 2,
                                        enhancedText: "Synthetic preferred", audioFileURL: "file:///synthetic/private.wav",
                                        aiRequestSystemMessage: "Synthetic private prompt", transcriptionStatus: .completed)
                row.id = id
                context.insert(row)
                try context.save()
            }.value
            let initial = try await waitForSnapshot(at: snapshot) {
                $0.count == 1 && $0.first?["id"] as? String == id.uuidString.lowercased()
                    && $0.first?["text"] as? String == "Synthetic preferred"
            }
            XCTAssertEqual(initial.1.first?["rawText"] as? String, "Synthetic original")
            XCTAssertEqual(Set(try XCTUnwrap(initial.1.first).keys), ["id", "timestamp", "text", "rawText", "duration"])
            XCTAssertFalse(String(decoding: initial.0, as: UTF8.self).contains("Synthetic private prompt"))
            XCTAssertFalse(String(decoding: initial.0, as: UTF8.self).contains("private.wav"))

            try await Task.detached {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                let row = try XCTUnwrap(context.fetch(FetchDescriptor<Transcription>()).first { $0.id == id })
                row.text = "Synthetic committed edit"
                row.enhancedText = nil
                try context.save()
            }.value
            _ = try await waitForSnapshot(at: snapshot) {
                $0.count == 1 && $0.first?["text"] as? String == "Synthetic committed edit"
                    && $0.first?["rawText"] as? String == "Synthetic committed edit"
            }

            try await Task.detached {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                let row = try XCTUnwrap(context.fetch(FetchDescriptor<Transcription>()).first { $0.id == id })
                context.delete(row)
                try context.save()
            }.value
            let deleted = try await waitForSnapshot(at: snapshot) { $0.isEmpty }
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: deleted.0) as? [String: Any])
            XCTAssertEqual(envelope["truncated"] as? Bool, false)
        }
    }

    func testUnrelatedContainerSaveDoesNotRefreshBoundSnapshot() async throws {
        let bound = try makeContainer()
        let unrelated = try makeContainer()
        try await withExporter { exporter, snapshot in
            exporter.start(container: bound)
            let initial = try await waitForSnapshot(at: snapshot) { $0.isEmpty }
            let observedSave = expectation(description: "The unrelated context really delivered didSave")
            let unrelatedIdentity = ObjectIdentifier(unrelated)
            let token = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) {
                notification in
                if let context = notification.object as? ModelContext,
                    ObjectIdentifier(context.container) == unrelatedIdentity { observedSave.fulfill() }
            }
            defer { NotificationCenter.default.removeObserver(token) }
            try await Task.detached {
                let context = ModelContext(unrelated)
                context.autosaveEnabled = false
                context.insert(Transcription(text: "Synthetic unrelated record", duration: 1, transcriptionStatus: .completed))
                try context.save()
            }.value
            await fulfillment(of: [observedSave], timeout: 2)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(try Data(contentsOf: snapshot), initial.0,
                           "An unrelated successful save must not rewrite the bound container's export.")
        }
    }

    func testUnsavedRowsStayPrivateWhenAnotherContextCommits() async throws {
        let container = try makeContainer()
        let unsaved = ModelContext(container)
        unsaved.autosaveEnabled = false
        unsaved.insert(Transcription(text: "Synthetic unsaved row", duration: 1, transcriptionStatus: .completed))
        try await withExporter { exporter, snapshot in
            exporter.start(container: container)
            _ = try await waitForSnapshot(at: snapshot) { $0.isEmpty }
            try await Task.detached {
                let committed = ModelContext(container)
                committed.autosaveEnabled = false
                committed.insert(Transcription(text: "Synthetic committed row", duration: 1, transcriptionStatus: .completed))
                try committed.save()
            }.value
            let result = try await waitForSnapshot(at: snapshot) {
                $0.count == 1 && $0.first?["text"] as? String == "Synthetic committed row"
            }
            XCTAssertFalse(String(decoding: result.0, as: UTF8.self).contains("Synthetic unsaved row"))
        }
        unsaved.rollback()
    }
}
