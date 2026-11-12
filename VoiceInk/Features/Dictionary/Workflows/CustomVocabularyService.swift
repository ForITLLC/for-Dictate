import Foundation
import SwiftData

@MainActor
final class CustomVocabularyService {
    static let shared = CustomVocabularyService()

    private init() {}

    /// Personal words first, then the shared company terms the person has not suppressed,
    /// as resolved and bounded by SharedVocabularyResolver.
    func loadSavedVocabulary(from context: ModelContext) -> RecordingVocabulary {
        SharedVocabularyService.shared.refreshPersonalWords(from: context)
        return RecordingVocabulary(savedTerms: SharedVocabularyCache.shared.snapshot.words)
    }
}
