import Foundation
import CryptoKit

struct CompanyDictionaryProfile: Codable, Equatable, Sendable {
    let userID: String
    let name: String
    let email: String
}

struct CompanyDictionaryCredential: Codable, Equatable, Sendable {
    let sessionID: UUID
    let key: String
    let expiresAt: Date
    var profile: CompanyDictionaryProfile?

    static func validKey(_ value: String) -> Bool {
        value.utf8.count == 48
            && value.range(of: "^fsak_[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil
    }
}

enum CompanyDictionaryStoreError: Error {
    case unavailable, invalidData, staleSession, persistenceFailed, cleanupFailed, durableInvalidationFailed
}

enum CompanyDictionaryCredentialRead: Sendable {
    case value(Data), notFound, unavailable
}

/// The production implementation is used only by the serialized store actor.
/// This protocol also lets tests exercise missing/locked/save/delete failures
/// without touching a user's Keychain.
protocol CompanyDictionaryCredentialStore: Sendable {
    func read() -> CompanyDictionaryCredentialRead
    func save(_ data: Data) -> Bool
    func delete() -> Bool
}

struct CompanyDictionaryRestoration: Sendable {
    let credential: CompanyDictionaryCredential?
    let snapshot: CompanyDictionarySnapshot?
    let checkedAt: Date?
    let accessDenied: Bool
}

protocol CompanyDictionaryStore: Sendable {
    func restore() async throws -> CompanyDictionaryRestoration
    /// Write a disabled incarnation before deleting anything. A deletion failure
    /// must leave that incarnation disabled across a restart.
    /// `order` is issued monotonically by the sole in-process coordinator, so
    /// actor priority/reentrancy cannot let an older queued reset win later.
    func reset(to sessionID: UUID, order: UInt64) async throws
    func saveCredential(_ credential: CompanyDictionaryCredential) async throws
    func bindProfile(_ profile: CompanyDictionaryProfile, sessionID: UUID) async throws
    func saveSnapshot(_ body: Data, snapshot: CompanyDictionarySnapshot, checkedAt: Date,
                      sessionID: UUID) async throws
    func markChecked(_ date: Date, version: String, sessionID: UUID) async throws
    func denyAccess(sessionID: UUID) async throws
}

/// One complete cache envelope is atomically replaced. The small lifecycle
/// manifest commits exclusion/version first, so a failed body replacement cannot
/// make a previously retired snapshot eligible on the next launch.
actor FileCompanyDictionaryStore: CompanyDictionaryStore {
    static let envelopeLimit = 24 * 1_024 * 1_024
    private static let manifestLimit = 16 * 1_024
    private static let credentialLimit = 64 * 1_024
    private static let representation = "read-active"

    private enum Phase: String, Codable { case disabled, provisional, bound, accessDenied }
    private struct Manifest: Codable {
        var schema = 1
        let sessionID: UUID
        var phase: Phase
        var version: String?
    }

    private struct Envelope: Codable {
        var schema = 1
        let origin: String
        let representation: String
        let sessionID: UUID
        let userID: String
        let companyID: String
        let version: String
        let fetchedAt: Date
        var checkedAt: Date
        /// Accidental corruption detection only; not same-user authentication.
        let bodySHA256: String
        /// JSONEncoder stores Data as base64, preserving the exact accepted body.
        let body: Data
    }

    private let directory: URL
    private let credentials: any CompanyDictionaryCredentialStore
    private var manifest: Manifest?
    private var credential: CompanyDictionaryCredential?
    private var credentialPersisted = false
    private var envelope: Envelope?
    private var latestResetOrder: UInt64 = 0

    init(directory: URL, credentials: any CompanyDictionaryCredentialStore) {
        self.directory = directory
        self.credentials = credentials
    }

    static func standardDirectory(bundleID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.forit.dictate/CompanyDictionary", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
    }

    private var manifestURL: URL { directory.appendingPathComponent("lifecycle-v1.json") }
    private var snapshotURL: URL { directory.appendingPathComponent("snapshot-v1.json") }

    func restore() throws -> CompanyDictionaryRestoration {
        let disabled = CompanyDictionaryRestoration(credential: nil, snapshot: nil, checkedAt: nil, accessDenied: false)
        guard let manifestData = try readIfPresent(manifestURL, limit: Self.manifestLimit) else {
            // A key alone is not proof that this incarnation was committed.
            // Do not adopt or print an orphaned credential.
            guard credentials.delete() else { throw CompanyDictionaryStoreError.cleanupFailed }
            try removeIfPresent(snapshotURL)
            manifest = nil
            credential = nil
            credentialPersisted = false
            envelope = nil
            return disabled
        }
        let restored: Manifest
        do {
            restored = try JSONDecoder().decode(Manifest.self, from: manifestData)
            guard restored.schema == 1 else { throw CompanyDictionaryStoreError.invalidData }
        } catch {
            // A malformed lifecycle record never enables company participation.
            throw CompanyDictionaryStoreError.invalidData
        }
        manifest = restored
        envelope = nil
        credential = nil
        credentialPersisted = false
        if restored.phase == .disabled {
            let removedCredential = credentials.delete()
            var removalFailed = false
            do { try removeIfPresent(snapshotURL) } catch { removalFailed = true }
            guard removedCredential && !removalFailed else { throw CompanyDictionaryStoreError.cleanupFailed }
            return disabled
        }

        let bytes: Data
        switch credentials.read() {
        case .notFound:
            try resetFiles(to: UUID())
            return disabled
        case .unavailable:
            // A locked store is not a missing key. Keep material for a later
            // explicit retry but contribute no company words this run.
            throw CompanyDictionaryStoreError.unavailable
        case .value(let data): bytes = data
        }
        guard bytes.count <= Self.credentialLimit,
              let restoredCredential = try? JSONDecoder().decode(CompanyDictionaryCredential.self, from: bytes),
              restoredCredential.sessionID == restored.sessionID,
              CompanyDictionaryCredential.validKey(restoredCredential.key),
              restoredCredential.profile.map(Self.validProfile) ?? true
        else { throw CompanyDictionaryStoreError.invalidData }
        credential = restoredCredential
        credentialPersisted = true
        guard restored.phase == .bound, let profile = restoredCredential.profile,
              let expectedVersion = restored.version
        else {
            return .init(credential: restoredCredential, snapshot: nil, checkedAt: nil,
                         accessDenied: restored.phase == .accessDenied)
        }

        // Bad/missing/torn cache is disposable; keep the known credential and
        // fetch unconditionally. A complete response is never reconstructed from
        // partial data or merged with a previous file.
        if let bytes = try? readIfPresent(snapshotURL, limit: Self.envelopeLimit),
           let restoredEnvelope = try? JSONDecoder().decode(Envelope.self, from: bytes),
           restoredEnvelope.schema == 1,
           restoredEnvelope.origin == CompanyDictionaryRequest.origin,
           restoredEnvelope.representation == Self.representation,
           restoredEnvelope.sessionID == restored.sessionID,
           restoredEnvelope.userID == profile.userID,
           restoredEnvelope.companyID == CompanyDictionarySnapshot.supportCompanyID,
           restoredEnvelope.version == expectedVersion,
           restoredEnvelope.fetchedAt <= restoredEnvelope.checkedAt,
           restoredEnvelope.checkedAt <= restoredCredential.expiresAt,
           restoredEnvelope.body.count <= CompanyDictionaryRequest.Endpoint.dictionary.maximumBytes,
           restoredEnvelope.bodySHA256 == Self.digest(restoredEnvelope.body),
           let snapshot = try? Self.decodeReadSnapshot(restoredEnvelope.body),
           snapshot.version == expectedVersion {
            envelope = restoredEnvelope
            return .init(credential: restoredCredential, snapshot: snapshot,
                         checkedAt: restoredEnvelope.checkedAt, accessDenied: false)
        }
        return .init(credential: restoredCredential, snapshot: nil, checkedAt: nil, accessDenied: false)
    }

    func reset(to sessionID: UUID, order: UInt64) throws {
        guard order > latestResetOrder
            || (order == latestResetOrder && manifest?.sessionID == sessionID && manifest?.phase == .disabled)
        else { throw CompanyDictionaryStoreError.staleSession }
        // UUIDs distinguish durable incarnations; the order only protects calls
        // within this store/coordinator lifetime and is not an identity key.
        guard manifest?.sessionID != sessionID || manifest?.phase == .disabled else {
            throw CompanyDictionaryStoreError.staleSession
        }
        latestResetOrder = order
        try resetFiles(to: sessionID)
    }

    private func resetFiles(to sessionID: UUID) throws {
        let disabled = Manifest(sessionID: sessionID, phase: .disabled, version: nil)
        // Clear actor-held eligibility even when the filesystem is unavailable.
        manifest = disabled
        credential = nil
        credentialPersisted = false
        envelope = nil
        var markerFailed = false
        do { try write(disabled, to: manifestURL, limit: Self.manifestLimit) }
        catch { markerFailed = true }
        let removedCredential = credentials.delete()
        var removalFailed = false
        do { try removeIfPresent(snapshotURL) } catch { removalFailed = true }
        if markerFailed { throw CompanyDictionaryStoreError.durableInvalidationFailed }
        if !removedCredential || removalFailed { throw CompanyDictionaryStoreError.cleanupFailed }
    }

    func saveCredential(_ candidate: CompanyDictionaryCredential) throws {
        guard let current = manifest, current.sessionID == candidate.sessionID,
              current.phase == .disabled, CompanyDictionaryCredential.validKey(candidate.key),
              candidate.expiresAt.timeIntervalSince1970.isFinite,
              candidate.profile.map(Self.validProfile) ?? true
        else { throw CompanyDictionaryStoreError.staleSession }
        let bytes = try JSONEncoder().encode(candidate)
        guard bytes.count <= Self.credentialLimit, credentials.save(bytes) else {
            throw CompanyDictionaryStoreError.persistenceFailed
        }
        let next = Manifest(sessionID: candidate.sessionID, phase: .provisional, version: nil)
        do { try write(next, to: manifestURL, limit: Self.manifestLimit) }
        catch {
            _ = credentials.delete()
            throw CompanyDictionaryStoreError.persistenceFailed
        }
        credential = candidate
        credentialPersisted = true
        manifest = next
    }

    func bindProfile(_ profile: CompanyDictionaryProfile, sessionID: UUID) throws {
        guard let current = manifest, current.sessionID == sessionID, current.phase != .disabled,
              var candidate = credential, candidate.sessionID == sessionID, Self.validProfile(profile)
        else { throw CompanyDictionaryStoreError.staleSession }
        if let previous = candidate.profile, previous.userID != profile.userID {
            // Same key unexpectedly changing identity is not a new account.
            throw CompanyDictionaryStoreError.invalidData
        }
        candidate.profile = profile
        guard credentials.save(try JSONEncoder().encode(candidate)) else {
            throw CompanyDictionaryStoreError.persistenceFailed
        }
        let next = Manifest(sessionID: sessionID, phase: .bound, version: current.version)
        try write(next, to: manifestURL, limit: Self.manifestLimit)
        credential = candidate
        credentialPersisted = true
        manifest = next
    }

    func saveSnapshot(_ body: Data, snapshot: CompanyDictionarySnapshot, checkedAt: Date,
                      sessionID: UUID) throws {
        guard let current = manifest, current.sessionID == sessionID, current.phase != .disabled,
              let credential, credential.sessionID == sessionID, let profile = credential.profile,
              body.count <= CompanyDictionaryRequest.Endpoint.dictionary.maximumBytes,
              try Self.decodeReadSnapshot(body) == snapshot
        else { throw CompanyDictionaryStoreError.staleSession }
        let nextEnvelope = Envelope(origin: CompanyDictionaryRequest.origin, representation: Self.representation,
                                    sessionID: sessionID, userID: profile.userID,
                                    companyID: snapshot.companyID, version: snapshot.version,
                                    fetchedAt: checkedAt, checkedAt: checkedAt, bodySHA256: Self.digest(body), body: body)
        try persist(nextEnvelope)
    }

    func markChecked(_ date: Date, version: String, sessionID: UUID) throws {
        guard let current = manifest, current.sessionID == sessionID, current.phase == .bound,
              current.version == version, var candidate = envelope,
              candidate.sessionID == sessionID, candidate.version == version
        else { throw CompanyDictionaryStoreError.staleSession }
        candidate.checkedAt = date
        // A 304 can also repair a previously failed offline save using the exact
        // complete bytes retained by this actor; it need not fetch a duplicate200.
        try persist(candidate)
    }

    func denyAccess(sessionID: UUID) throws {
        guard let current = manifest, current.sessionID == sessionID, current.phase != .disabled else {
            throw CompanyDictionaryStoreError.staleSession
        }
        let denied = Manifest(sessionID: sessionID, phase: .accessDenied, version: nil)
        envelope = nil
        do { try write(denied, to: manifestURL, limit: Self.manifestLimit) }
        catch {
            // Do not leave a durable bound snapshot eligible when denial was
            // actually observed, even if the data filesystem cannot be changed.
            credentialPersisted = false
            if !credentials.delete() { throw CompanyDictionaryStoreError.durableInvalidationFailed }
            manifest = denied
            throw CompanyDictionaryStoreError.persistenceFailed
        }
        manifest = denied
        try removeIfPresent(snapshotURL)
    }

    private func persist(_ candidate: Envelope) throws {
        let next = Manifest(sessionID: candidate.sessionID, phase: .bound, version: candidate.version)
        // In-memory complete bytes remain available for a later304/storage
        // recovery even when this attempt cannot create an offline copy.
        envelope = candidate
        manifest = next
        // Commit the new expected version before replacing the body. An old
        // snapshot then fails restoration, including after a valid empty200.
        do { try write(next, to: manifestURL, limit: Self.manifestLimit) }
        catch {
            credentialPersisted = false
            // The Keychain is an independent local exclusion path when the
            // data filesystem cannot invalidate an older durable manifest.
            if !credentials.delete() { throw CompanyDictionaryStoreError.durableInvalidationFailed }
            throw CompanyDictionaryStoreError.persistenceFailed
        }
        if !credentialPersisted {
            guard let credential, credential.sessionID == candidate.sessionID,
                  credentials.save(try JSONEncoder().encode(credential))
            else { throw CompanyDictionaryStoreError.persistenceFailed }
            credentialPersisted = true
        }
        do { try write(candidate, to: snapshotURL, limit: Self.envelopeLimit) }
        catch { throw CompanyDictionaryStoreError.persistenceFailed }
    }

    static func decodeReadSnapshot(_ data: Data) throws -> CompanyDictionarySnapshot {
        let snapshot = try JSONDecoder().decode(CompanyDictionarySnapshot.self, from: data)
        guard !snapshot.canEdit, snapshot.terms.allSatisfy(\.isActive) else {
            throw CompanyDictionaryStoreError.invalidData
        }
        return snapshot
    }

    static func validProfile(_ profile: CompanyDictionaryProfile) -> Bool {
        profile.userID.utf8.count == 36
            && profile.userID != "00000000-0000-0000-0000-000000000000"
            && profile.userID.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                                    options: .regularExpression) != nil
            && profile.name.utf8.count <= 2_048 && profile.email.utf8.count <= 2_048
            && !profile.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && !profile.email.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private func ensureDirectory() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            let attributes = try manager.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw CompanyDictionaryStoreError.invalidData
            }
        } else {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func write<T: Encodable>(_ value: T, to url: URL, limit: Int) throws {
        let encoder = JSONEncoder()
        // Keep the stated base64 envelope bound independent of slash escaping.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let bytes = try encoder.encode(value)
        guard bytes.count <= limit else { throw CompanyDictionaryStoreError.invalidData }
        try ensureDirectory()
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func readIfPresent(_ url: URL, limit: Int) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? (limit + 1)) <= limit
        else { throw CompanyDictionaryStoreError.invalidData }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var bytes = Data()
        while let chunk = try file.read(upToCount: min(64 * 1_024, limit + 1 - bytes.count)), !chunk.isEmpty {
            bytes.append(chunk)
            guard bytes.count <= limit else { throw CompanyDictionaryStoreError.invalidData }
        }
        return bytes
    }

    private func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
