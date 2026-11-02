import Foundation
import SwiftData

class CustomVocabularyService {
    static let shared = CustomVocabularyService()

    private init() {}

    @MainActor
    func getCustomVocabulary(from context: ModelContext) -> String {
        SharedVocabularyService.shared.refreshPersonalWords(from: context)
        let customWords = SharedVocabularyCache.shared.snapshot.words
        guard !customWords.isEmpty else {
            return ""
        }

        let wordsText = customWords.joined(separator: ", ")
        return "Important Vocabulary: \(wordsText)"
    }

}
