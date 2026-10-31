import Combine
import Foundation
import SwiftData

@MainActor
final class SharedVocabularyService: ObservableObject {
    static let shared = SharedVocabularyService()

    @Published private(set) var catalog = SharedVocabularyCatalog.bundled
    @Published private(set) var preferences = SharedVocabularyPreferences()
    @Published private(set) var warning: String?
    @Published private(set) var omittedCount = 0

    private let files: SharedVocabularyFiles
    private let cache: SharedVocabularyCache
    private weak var modelContext: ModelContext?
    private var saveObserver: NSObjectProtocol?
    private var configurationID = UUID()
    private var personalWords: [String] = []
    private var preferencesWarning: String?

    init(files: SharedVocabularyFiles = .standard, cache: SharedVocabularyCache = .shared) {
        self.files = files
        self.cache = cache
    }

    deinit {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
    }

    /// Call once after creating the app's dictionary ModelContext, before the
    /// recording services are initialized. File I/O happens here or by explicit
    /// Dictionary actions, never when constructing a transcription request.
    func configure(context: ModelContext) {
        guard modelContext !== context else { return }
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        modelContext = context
        let configurationID = UUID()
        self.configurationID = configurationID
        let containerID = ObjectIdentifier(context.container)
        // Observe every saving context in this container, including the separate
        // WordReplacementStore ModelActor used by AutoLearn. Inspect the sender
        // on its saving executor; only identities cross into the main-actor task.
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: nil
        ) { [weak self] notification in
            guard let savedContext = notification.object as? ModelContext,
                ObjectIdentifier(savedContext.container) == containerID
            else { return }
            Task { @MainActor [weak self] in
                guard let self, self.configurationID == configurationID,
                    let context = self.modelContext,
                    ObjectIdentifier(context.container) == containerID
                else { return }
                self.refreshPersonalWords(from: context)
            }
        }
        // Register before the initial read so a concurrent committed save cannot
        // fall between initial snapshot construction and observer installation.
        loadFiles()
        refreshPersonalWords(from: context)
    }

    func refreshPersonalWords(from context: ModelContext) {
        if let configured = modelContext, configured.container !== context.container { return }
        // A reused main context can contain unsaved inserts/edits and registered
        // stale models. Read committed values in a fresh, actor-confined context
        // even when another context's save caused this refresh.
        let committedContext = ModelContext(context.container)
        committedContext.autosaveEnabled = false
        var descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\VocabularyWord.word)])
        descriptor.fetchLimit = SharedVocabularyLimits.personalTerms
        descriptor.includePendingChanges = false
        do {
            personalWords = try committedContext.fetch(descriptor).map(\.word)
            publishSnapshot()
        } catch {
            // Keep the last valid personal overlay rather than silently losing
            // it when SwiftData temporarily cannot be read.
            warning = String(localized: "Personal vocabulary could not be refreshed. The last valid vocabulary is still in use.")
        }
    }

    func reloadSharedCatalog() throws {
        var firstError: Error?
        var warnings: [String] = []
        do {
            let candidate = try SharedVocabularyFiles.decodeCatalog(SharedVocabularyFiles.readBounded(files.catalogURL))
            try SharedVocabularyFiles.checkUpdate(candidate, replacing: try catalog.validated())
            catalog = candidate
        } catch {
            firstError = error
            warnings.append(String(localized: "Shared vocabulary could not be reloaded. The last valid catalog is still in use."))
        }
        // Try preference recovery independently, even if the catalog is broken.
        // A missing file is normal before the first personal choice is saved;
        // after choices existed, retain them until a valid file is restored.
        do {
            if FileManager.default.fileExists(atPath: files.preferencesURL.path) {
                preferences = try files.loadPreferences()
            } else if preferencesWarning != nil || preferences != SharedVocabularyPreferences() {
                throw SharedVocabularyError.unreadablePreferences
            }
            preferencesWarning = nil
        } catch {
            if firstError == nil { firstError = error }
            preferencesWarning = String(localized: "Personal shared-vocabulary choices could not be loaded. Restore the preferences file and reload again; the last valid choices are still in use.")
            warnings.append(preferencesWarning!)
        }
        warning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        publishSnapshot()
        if let firstError { throw firstError }
    }

    func importCatalog(_ data: Data) throws {
        catalog = try files.installCatalog(data, replacing: catalog)
        warning = preferencesWarning
        publishSnapshot()
    }

    func addSharedTerm(_ input: String) throws {
        catalog = try files.addSharedTerm(input, to: catalog)
        warning = preferencesWarning
        publishSnapshot()
    }

    func exportCatalog() throws -> Data {
        try SharedVocabularyFiles.encode(catalog.validated())
    }

    func setSuppressed(_ suppressed: Bool, term: String) throws {
        var next = preferences
        let key = SharedVocabularyResolver.key(term)
        next.suppressed.removeAll { $0 == key }
        if suppressed { next.suppressed.append(key) }
        try savePreferences(next)
    }

    func setOverride(source: String, spelling: String) throws {
        let key = SharedVocabularyResolver.key(source)
        guard catalog.terms.contains(where: { SharedVocabularyResolver.key($0) == key }) else {
            throw SharedVocabularyError.unknownSharedTerm
        }
        var next = preferences
        next.overrides[key] = try SharedVocabularyResolver.validatedTerm(spelling)
        next.suppressed.removeAll { $0 == key }
        try savePreferences(next)
    }

    func resetPersonalChoice(for term: String) throws {
        var next = preferences
        let key = SharedVocabularyResolver.key(term)
        next.suppressed.removeAll { $0 == key }
        next.overrides.removeValue(forKey: key)
        try savePreferences(next)
    }

    private func savePreferences(_ next: SharedVocabularyPreferences) throws {
        guard preferencesWarning == nil else { throw SharedVocabularyError.unreadablePreferences }
        let validated = try next.validated()
        try SharedVocabularyFiles.write(validated, to: files.preferencesURL)
        preferences = validated
        publishSnapshot()
    }

    private func loadFiles() {
        var warnings: [String] = []
        do {
            if FileManager.default.fileExists(atPath: files.catalogURL.path) {
                catalog = try SharedVocabularyFiles.decodeCatalog(SharedVocabularyFiles.readBounded(files.catalogURL))
            } else {
                // Seeding follows the same lock/revision protocol as updates.
                // A concurrent app may have created a newer catalog meanwhile.
                let bundled = try SharedVocabularyCatalog.bundled.validated()
                catalog = try files.installCatalog(SharedVocabularyFiles.encode(bundled), replacing: bundled)
            }
        } catch {
            warnings.append(String(localized: "Shared vocabulary could not be loaded. The bundled or last valid catalog is still in use; the file was not replaced."))
        }
        do {
            if FileManager.default.fileExists(atPath: files.preferencesURL.path) {
                preferences = try files.loadPreferences()
                preferencesWarning = nil
            }
        } catch {
            let message = String(localized: "Personal shared-vocabulary choices could not be loaded. Restore the preferences file before changing shared-term choices; the file was not replaced.")
            preferencesWarning = message
            warnings.append(message)
        }
        warning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
    }

    private func publishSnapshot() {
        let snapshot = SharedVocabularyResolver.resolve(
            catalog: catalog, preferences: preferences, personalWords: personalWords
        )
        if cache.snapshot != snapshot { cache.replace(with: snapshot) }
        if omittedCount != snapshot.omittedCount { omittedCount = snapshot.omittedCount }
    }
}
