import Foundation
import XCTest
@testable import VoiceInk

@MainActor
final class CompanyDictionaryStoreTests: XCTestCase {
    private let profile = CompanyDictionaryProfile(userID: "00000000-0000-0000-0000-000000000009",
                                                   name: "Synthetic account", email: "synthetic@example.invalid")
    private let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func body() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
            "companyId": CompanyDictionarySnapshot.supportCompanyID, "version": "\"v1-read-active\"",
            "terms": [["term_id": "00000000-0000-0000-0000-000000000001", "canonical_spelling": "SyntheticName",
                       "spoken_forms": ["synthetic alias"], "meaning": "Preserved meaning", "kind": "term", "is_active": true,
                       "revision": 2, "updated_at": "2026-11-03T04:02:08.765Z"]],
            "total": 1, "updated_at": "2026-11-03T04:02:08.765Z", "canEdit": false])
    }

    private func prepared(_ store: FileCompanyDictionaryStore) async throws {
        let id = UUID()
        try await store.reset(to: id, order: 1)
        try await store.saveCredential(.init(sessionID: id, key: "fsak_" + String(repeating: "a", count: 43),
                                             expiresAt: checkedAt.addingTimeInterval(3_600), profile: nil))
        try await store.bindProfile(profile, sessionID: id)
        let bytes = try body()
        try await store.saveSnapshot(bytes, snapshot: FileCompanyDictionaryStore.decodeReadSnapshot(bytes),
                                     checkedAt: checkedAt, sessionID: id)
    }

    private func withDirectory(_ body: @MainActor (URL, SyntheticCompanyCredentials) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-company-store-synthetic-\(UUID().uuidString)")
        let credentials = SyntheticCompanyCredentials()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory, credentials)
    }

    func testNewStoreInstanceRevalidatesFullBoundSnapshotAndPrivatePermissions() async throws {
        try await withDirectory { directory, credentials in
            try await prepared(.init(directory: directory, credentials: credentials))
            let restarted = FileCompanyDictionaryStore(directory: directory, credentials: credentials)
            let restored = try await restarted.restore()
            XCTAssertEqual(restored.credential?.profile, profile)
            XCTAssertEqual(restored.snapshot?.terms.first?.spokenForms, ["synthetic alias"])
            XCTAssertEqual(restored.snapshot?.terms.first?.meaning, "Preserved meaning")
            let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("snapshot-v1.json").path)
            XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testDisabledManifestCannotRestoreOldKeyAndCacheAfterDeletionFailure() async throws {
        try await withDirectory { directory, credentials in
            let store = FileCompanyDictionaryStore(directory: directory, credentials: credentials)
            try await prepared(store)
            let cacheURL = directory.appendingPathComponent("snapshot-v1.json")
            let previousBytes = try Data(contentsOf: cacheURL)
            credentials.failDeletion = true
            do { try await store.reset(to: UUID(), order: 2); XCTFail("Expected the injected credential deletion failure.") }
            catch { }
            // Simulate an undeleted/restored old file: the committed disabled
            // lifecycle must still prevent a new process from using it.
            try previousBytes.write(to: cacheURL, options: .atomic)
            let restarted = FileCompanyDictionaryStore(directory: directory, credentials: credentials)
            do { _ = try await restarted.restore(); XCTFail("Cleanup failure must not return an active session.") }
            catch { }
            credentials.failDeletion = false
            let recovered = try await restarted.restore()
            XCTAssertNil(recovered.credential)
            XCTAssertNil(recovered.snapshot)
        }
    }

    func testRetiredVersionAndCrossIdentityEnvelopesCannotBeRestored() async throws {
        try await withDirectory { directory, credentials in
            try await prepared(.init(directory: directory, credentials: credentials))
            let cacheURL = directory.appendingPathComponent("snapshot-v1.json")
            let original = try Data(contentsOf: cacheURL)
            var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            envelope["userID"] = "00000000-0000-0000-0000-000000000010"
            try JSONSerialization.data(withJSONObject: envelope).write(to: cacheURL, options: .atomic)
            let wrongIdentity = try await FileCompanyDictionaryStore(directory: directory, credentials: credentials).restore()
            XCTAssertNotNil(wrongIdentity.credential)
            XCTAssertNil(wrongIdentity.snapshot)
            try original.write(to: cacheURL, options: .atomic)
            let manifestURL = directory.appendingPathComponent("lifecycle-v1.json")
            var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
            manifest["version"] = "\"v2-read-active\""
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL, options: .atomic)
            let retired = try await FileCompanyDictionaryStore(directory: directory, credentials: credentials).restore()
            XCTAssertNotNil(retired.credential)
            XCTAssertNil(retired.snapshot)
        }
    }

    func testTemporarilyUnavailableKeychainPreservesStoredMaterialButPublishesNothing() async throws {
        try await withDirectory { directory, credentials in
            try await prepared(.init(directory: directory, credentials: credentials))
            let cacheURL = directory.appendingPathComponent("snapshot-v1.json")
            let original = try Data(contentsOf: cacheURL)
            credentials.unavailable = true
            let restarted = FileCompanyDictionaryStore(directory: directory, credentials: credentials)
            do { _ = try await restarted.restore(); XCTFail("Locked storage must not produce a session.") }
            catch { }
            XCTAssertEqual(try Data(contentsOf: cacheURL), original)
            credentials.unavailable = false
            let recovered = try await restarted.restore()
            XCTAssertNotNil(recovered.credential)
            XCTAssertNotNil(recovered.snapshot)
        }
    }

    func testOlderQueuedResetCannotDeleteNewerDurableSession() async throws {
        try await withDirectory { directory, credentials in
            let store = FileCompanyDictionaryStore(directory: directory, credentials: credentials)
            let newSession = UUID()
            // Simulate actor-priority reordering: a newer issued transition has
            // already completed before the older queued transition executes.
            try await store.reset(to: newSession, order: 2)
            try await store.saveCredential(.init(sessionID: newSession, key: "fsak_" + String(repeating: "b", count: 43),
                                                 expiresAt: checkedAt.addingTimeInterval(3_600), profile: nil))
            try await store.bindProfile(profile, sessionID: newSession)
            let bytes = try body()
            try await store.saveSnapshot(bytes, snapshot: FileCompanyDictionaryStore.decodeReadSnapshot(bytes),
                                         checkedAt: checkedAt, sessionID: newSession)
            do { try await store.reset(to: UUID(), order: 1); XCTFail("An older reset must be fenced.") }
            catch CompanyDictionaryStoreError.staleSession { }
            let restored = try await FileCompanyDictionaryStore(directory: directory, credentials: credentials).restore()
            XCTAssertEqual(restored.credential?.sessionID, newSession)
            XCTAssertEqual(restored.snapshot?.terms.first?.canonicalSpelling, "SyntheticName")
        }
    }
}

private final class SyntheticCompanyCredentials: CompanyDictionaryCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var deletionFails = false
    private var isUnavailable = false
    var failDeletion: Bool {
        get { lock.lock(); defer { lock.unlock() }; return deletionFails }
        set { lock.lock(); defer { lock.unlock() }; deletionFails = newValue }
    }
    var unavailable: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isUnavailable }
        set { lock.lock(); defer { lock.unlock() }; isUnavailable = newValue }
    }
    func read() -> CompanyDictionaryCredentialRead {
        lock.lock(); defer { lock.unlock() }
        if isUnavailable { return .unavailable }
        return data.map(CompanyDictionaryCredentialRead.value) ?? .notFound
    }
    func save(_ data: Data) -> Bool { lock.lock(); defer { lock.unlock() }; self.data = data; return true }
    func delete() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !deletionFails else { return false }
        data = nil
        return true
    }
}
