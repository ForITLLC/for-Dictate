import Foundation

/// Portable, user-owned catalog. Other apps may read this file without opening
/// Dictate's private SwiftData store. Updates must advance `revision`.
struct SharedVocabularyCatalog: Codable, Equatable, Sendable {
    static let formatIdentifier = "io.forit.shared-vocabulary"
    static let currentSchemaVersion = 1

    var format = Self.formatIdentifier
    var schemaVersion = Self.currentSchemaVersion
    var revision: Int
    var terms: [String]

    static let bundled = SharedVocabularyCatalog(revision: 1, terms: [
        "ForIT", "ForIT Dictate", "Tinycast", "Orca", "Azure", "Microsoft Azure",
        "Microsoft Entra ID", "Microsoft 365", "SharePoint", "OneDrive", "TestFlight",
        "App Store Connect", "SwiftUI", "SwiftData", "Whisper", "FluidAudio",
        "Apple Speech", "Core ML", "macOS", "Ollama",
    ])

    func validated() throws -> Self {
        guard format == Self.formatIdentifier, schemaVersion == Self.currentSchemaVersion else {
            throw SharedVocabularyError.unsupportedFormat
        }
        guard revision > 0, terms.count <= SharedVocabularyLimits.catalogTerms else {
            throw SharedVocabularyError.limitExceeded
        }
        var seen = Set<String>()
        let normalized = try terms.map { try SharedVocabularyResolver.validatedTerm($0) }
            .sorted()
            .filter { seen.insert(SharedVocabularyResolver.key($0)).inserted }
            .sorted { SharedVocabularyResolver.key($0) < SharedVocabularyResolver.key($1) }
        return Self(revision: revision, terms: normalized)
    }

    func addingTerm(_ input: String) throws -> Self {
        let current = try validated()
        let term = try SharedVocabularyResolver.validatedTerm(input)
        let key = SharedVocabularyResolver.key(term)
        guard !current.terms.contains(where: { SharedVocabularyResolver.key($0) == key }) else {
            throw SharedVocabularyError.duplicateSharedTerm
        }
        guard current.revision < Int.max else { throw SharedVocabularyError.revisionExhausted }
        return try Self(revision: current.revision + 1, terms: current.terms + [term]).validated()
    }
}

/// Dictate-only preferences. Never exported with the shared catalog or merged
/// into the existing personal dictionary archive.
struct SharedVocabularyPreferences: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var suppressed: [String] = []
    var overrides: [String: String] = [:]

    func validated() throws -> Self {
        guard schemaVersion == 1 else { throw SharedVocabularyError.unsupportedFormat }
        guard suppressed.count <= SharedVocabularyLimits.catalogTerms,
            overrides.count <= SharedVocabularyLimits.catalogTerms
        else { throw SharedVocabularyError.limitExceeded }
        var result = Self()
        result.suppressed = try Array(Set(suppressed.map {
            SharedVocabularyResolver.key(try SharedVocabularyResolver.validatedTerm($0))
        })).sorted()
        for source in overrides.keys.sorted() {
            let key = SharedVocabularyResolver.key(try SharedVocabularyResolver.validatedTerm(source))
            guard result.overrides[key] == nil else { throw SharedVocabularyError.conflictingOverride }
            result.overrides[key] = try SharedVocabularyResolver.validatedTerm(overrides[source]!)
        }
        return result
    }
}

enum SharedVocabularyLimits {
    static let fileBytes = 256 * 1024
    static let catalogTerms = 1_024
    static let personalTerms = 4_096
    static let termBytes = 160
    static let resolvedTerms = 256
    static let resolvedBytes = 6_000
    static let whisperTerms = 64
    static let whisperHintBytes = 768
}

struct ResolvedVocabularySnapshot: Equatable, Sendable {
    let revision: Int
    /// Personal entries first, then shared entries, each in deterministic order.
    let words: [String]
    let omittedCount: Int

    func whisperPrompt(preserving original: String?) -> String? {
        let prefix = "Important vocabulary: "
        var selected: [String] = []
        var bytes = prefix.utf8.count
        for word in words {
            let cost = word.utf8.count + (selected.isEmpty ? 0 : 2)
            guard selected.count < SharedVocabularyLimits.whisperTerms,
                bytes + cost <= SharedVocabularyLimits.whisperHintBytes
            else { continue }
            selected.append(word)
            bytes += cost
        }
        guard !selected.isEmpty else { return original }
        let hint = prefix + selected.joined(separator: ", ")
        guard let original, !original.isEmpty else { return hint }
        // Never truncate, rewrite, persist, or replace the user's language prompt.
        return original + "\n\n" + hint
    }
}

enum SharedVocabularyResolver {
    static func key(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func validatedTerm(_ value: String) throws -> String {
        let term = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !term.isEmpty, term.utf8.count <= SharedVocabularyLimits.termBytes,
            !term.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw SharedVocabularyError.invalidTerm }
        return term
    }

    static func resolve(
        catalog: SharedVocabularyCatalog,
        preferences: SharedVocabularyPreferences,
        personalWords: [String]
    ) -> ResolvedVocabularySnapshot {
        var personal: [String: String] = [:]
        for raw in personalWords.prefix(SharedVocabularyLimits.personalTerms).sorted() {
            guard let word = try? validatedTerm(raw) else { continue }
            if personal[key(word)] == nil { personal[key(word)] = word }
        }
        let suppressed = Set(preferences.suppressed.map(key))
        var shared: [String: String] = [:]
        for term in catalog.terms.sorted() {
            let source = key(term)
            guard !suppressed.contains(source), personal[source] == nil else { continue }
            let preferred = preferences.overrides[source] ?? term
            shared[key(preferred)] = preferred
        }
        // A personal word also wins when it collides with an override's output.
        let candidates = personal.keys.sorted().compactMap { personal[$0] }
            + shared.keys.sorted().filter { personal[$0] == nil }.compactMap { shared[$0] }
        var words: [String] = []
        var bytes = 0
        for term in candidates {
            let cost = term.utf8.count + (words.isEmpty ? 0 : 2)
            guard words.count < SharedVocabularyLimits.resolvedTerms,
                bytes + cost <= SharedVocabularyLimits.resolvedBytes
            else { continue }
            words.append(term)
            bytes += cost
        }
        return .init(revision: catalog.revision, words: words, omittedCount: candidates.count - words.count)
    }
}

/// Decoder threads only copy this immutable value; they never fetch SwiftData,
/// read a file, contact a server, or wait for a catalog refresh.
final class SharedVocabularyCache: @unchecked Sendable {
    static let shared = SharedVocabularyCache()
    private let lock = NSLock()
    private var value = SharedVocabularyResolver.resolve(catalog: .bundled, preferences: .init(), personalWords: [])

    var snapshot: ResolvedVocabularySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func replace(with snapshot: ResolvedVocabularySnapshot) {
        lock.lock()
        defer { lock.unlock() }
        value = snapshot
    }
}

enum SharedVocabularyError: LocalizedError {
    case unsupportedFormat, limitExceeded, invalidTerm, staleRevision, revisionConflict, conflictingOverride, unknownSharedTerm, unreadablePreferences, catalogBusy, lockUnavailable, duplicateSharedTerm, revisionExhausted, catalogChanged

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "This is not a supported ForIT shared vocabulary file."
        case .limitExceeded: "The vocabulary exceeds its supported file, revision, or entry limits."
        case .invalidTerm: "Vocabulary entries must contain 1–160 UTF-8 bytes and no control characters."
        case .staleRevision: "This catalog is older than the current shared vocabulary. Increase its revision to update it."
        case .revisionConflict: "This revision has different terms. Increase the revision before importing an update."
        case .conflictingOverride: "Multiple personal spellings refer to the same shared term."
        case .unknownSharedTerm: "Choose a term from the current shared vocabulary to override its spelling."
        case .unreadablePreferences: "Restore the unreadable personal vocabulary preferences file before changing shared-term choices. Your file has been preserved."
        case .catalogBusy: "Another app is updating shared vocabulary. Try the update again shortly."
        case .lockUnavailable: "The shared vocabulary update lock could not be opened. The catalog was not replaced."
        case .duplicateSharedTerm: "This term is already in shared vocabulary."
        case .revisionExhausted: "The shared vocabulary revision cannot advance further."
        case .catalogChanged: "Shared vocabulary changed in another app. Reload vocabulary before adding a term."
        }
    }
}

struct SharedVocabularyFiles {
    let catalogURL: URL
    let preferencesURL: URL

    static var standard: Self {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return Self(
            catalogURL: support.appendingPathComponent("ForIT/SharedVocabulary/vocabulary-v1.json"),
            preferencesURL: support.appendingPathComponent("io.forit.dictate/vocabulary-preferences-v1.json")
        )
    }

    static func readBounded(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: SharedVocabularyLimits.fileBytes + 1) ?? Data()
        guard data.count <= SharedVocabularyLimits.fileBytes else { throw SharedVocabularyError.limitExceeded }
        return data
    }

    static func decodeCatalog(_ data: Data) throws -> SharedVocabularyCatalog {
        guard data.count <= SharedVocabularyLimits.fileBytes else { throw SharedVocabularyError.limitExceeded }
        return try JSONDecoder().decode(SharedVocabularyCatalog.self, from: data).validated()
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= SharedVocabularyLimits.fileBytes else { throw SharedVocabularyError.limitExceeded }
        return data
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func checkUpdate(_ candidate: SharedVocabularyCatalog, replacing current: SharedVocabularyCatalog) throws {
        guard candidate.revision >= current.revision else { throw SharedVocabularyError.staleRevision }
        guard candidate.revision != current.revision || candidate == current else {
            throw SharedVocabularyError.revisionConflict
        }
    }

    func installCatalog(
        _ data: Data, replacing current: SharedVocabularyCatalog, requiringUnchangedCatalog: Bool = false
    ) throws -> SharedVocabularyCatalog {
        let candidate = try Self.decodeCatalog(data)
        let baseline = try current.validated()
        try Self.checkUpdate(candidate, replacing: baseline)
        // Compare and replace under one nonblocking cross-process lock. Never
        // replace an unreadable catalog, and never wait for a competing writer.
        return try SharedVocabularyCatalogLock.withExclusiveAccess(at: catalogURL) {
            if FileManager.default.fileExists(atPath: catalogURL.path) {
                let onDisk = try Self.decodeCatalog(Self.readBounded(catalogURL))
                if requiringUnchangedCatalog, onDisk != baseline { throw SharedVocabularyError.catalogChanged }
                try Self.checkUpdate(candidate, replacing: onDisk)
            } else if requiringUnchangedCatalog {
                throw SharedVocabularyError.catalogChanged
            }
            try Self.write(candidate, to: catalogURL)
            return candidate
        }
    }

    func addSharedTerm(_ input: String, to current: SharedVocabularyCatalog) throws -> SharedVocabularyCatalog {
        let candidate = try current.addingTerm(input)
        return try installCatalog(Self.encode(candidate), replacing: current, requiringUnchangedCatalog: true)
    }

    /// No mutations on failure: callers keep their last valid choices and may
    /// explicitly retry this read after the user repairs the preferences file.
    func loadPreferences() throws -> SharedVocabularyPreferences {
        let data = try Self.readBounded(preferencesURL)
        return try JSONDecoder().decode(SharedVocabularyPreferences.self, from: data).validated()
    }
}
