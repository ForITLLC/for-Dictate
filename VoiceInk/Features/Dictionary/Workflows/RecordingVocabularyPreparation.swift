import Foundation

/// Builds optional screen vocabulary without delaying transcription or raw context capture.
@MainActor
final class RecordingVocabularyPreparation {
    private(set) var current: RecordingVocabulary
    private var preparationTask: Task<Void, Never>?
    private var isFinished = false

    init(savedVocabulary: RecordingVocabulary) {
        current = savedVocabulary
    }

    /// Called only after OCR completes. A finished run never starts new extraction.
    func prepareScreenNames(
        in text: String, language: String?,
        extract: @escaping @Sendable (String, String?) async -> [String] = {
            RecordingVocabulary.screenNames(in: $0, language: $1)
        }
    ) {
        guard !isFinished, preparationTask == nil else { return }
        let saved = current
        let extraction = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return saved }
            let names = await extract(text, language)
            guard !Task.isCancelled else { return saved }
            return saved.addingScreenNames(names)
        }

        preparationTask = Task {
            let prepared = await withTaskCancellationHandler {
                await extraction.value
            } onCancel: {
                extraction.cancel()
            }
            guard !Task.isCancelled, !isFinished else { return }
            current = prepared
        }
    }

    /// Await only from deterministic tests; recording startup/finalization never waits.
    func waitForPreparation() async {
        await preparationTask?.value
    }

    /// Freeze whatever is ready and cancel unfinished work, without waiting for it.
    @discardableResult
    func finish() -> RecordingVocabulary {
        guard !isFinished else { return current }
        isFinished = true
        preparationTask?.cancel()
        preparationTask = nil
        return current
    }
}
