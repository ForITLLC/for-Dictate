import AppKit
import Foundation
import UniformTypeIdentifiers

/// Owns native file-panel presentation so the archive and import engine stay
/// independent of AppKit and remain directly testable.
@MainActor
enum DictionaryFilePanelService {
    static func chooseSharedVocabularyData() throws -> Data? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "Update Shared ForIT Vocabulary")
        panel.message = String(localized: "Choose a versioned shared catalog. Personal words and choices are preserved.")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try SharedVocabularyFiles.readBounded(url)
    }

    static func saveSharedVocabularyData(_ data: Data) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "ForIT_Shared_Vocabulary.json"
        panel.title = String(localized: "Export Shared ForIT Vocabulary")
        panel.message = String(localized: "Export shared terms only. Personal words and spelling choices stay in Dictate.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
    }

    static func saveDictionaryData(_ data: Data) throws -> URL? {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = "ForIT_Dictate_Dictionary.json"
        savePanel.title = String(localized: "Export Dictionary")
        savePanel.message = String(localized: "Export vocabulary and word replacements to a portable JSON file.")

        guard savePanel.runModal() == .OK, let url = savePanel.url else {
            return nil
        }

        try data.write(to: url, options: .atomic)
        return url
    }

    static func chooseDictionaryData() throws -> Data? {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.title = String(localized: "Import Dictionary")
        openPanel.message = String(localized: "Choose a ForIT Dictate dictionary JSON file.")

        guard openPanel.runModal() == .OK, let url = openPanel.url else {
            return nil
        }

        return try Data(contentsOf: url)
    }
}
