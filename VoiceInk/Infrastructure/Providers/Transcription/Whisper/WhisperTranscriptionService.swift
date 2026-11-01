import AVFoundation
import Foundation
import os

class WhisperTranscriptionService: TranscriptionService {

    private let logger = Logger(subsystem: "io.forit.dictate", category: "WhisperTranscriptionService")
    private let modelsDirectory: URL
    private weak var modelProvider: (any WhisperModelProvider)?

    init(modelsDirectory: URL, modelProvider: (any WhisperModelProvider)? = nil) {
        self.modelsDirectory = modelsDirectory
        self.modelProvider = modelProvider
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws
        -> String
    {
        guard model.provider == .whisper else {
            throw VoiceInkEngineError.modelLoadFailed
        }

        logger.notice("Initiating local transcription for model: \(model.displayName, privacy: .public)")

        try Task.checkCancellation()
        let data = try readAudioSamples(audioURL)
        let whisperContext: WhisperContext
        let ownsContext: Bool

        // Check if the required model is already loaded in the model provider
        if let loadedContext = await loadedWhisperContext(for: model.name) {

            logger.notice("Using already loaded model: \(model.name, privacy: .public)")
            whisperContext = loadedContext
            ownsContext = false
        } else {
            // Resolve the on-disk URL using the provider's availableModels (covers imports)
            let resolvedURL: URL? = await modelProvider?.availableModels.first(where: { $0.name == model.name })?.url
            guard let modelURL = resolvedURL, FileManager.default.fileExists(atPath: modelURL.path) else {
                logger.error("❌ Model file not found for: \(model.name, privacy: .public)")
                throw VoiceInkEngineError.modelLoadFailed
            }

            logger.notice("Loading model: \(model.name, privacy: .public)")
            do {
                whisperContext = try await WhisperContext.createContext(path: modelURL.path)
                ownsContext = true
            } catch {
                logger.error("❌ Failed to load model: \(model.name, privacy: .public) - \(error, privacy: .public)")
                throw VoiceInkEngineError.modelLoadFailed
            }
        }

        // The shared C context must not yield between configuring this request,
        // decoding its audio and copying its result.
        let text = await whisperContext.transcribe(
            samples: data, language: context.language, prompt: context.whisperPrompt
        )

        // Ownership belongs to this request; provider state may have changed
        // while we awaited decoding. Never release a borrowed shared context.
        if ownsContext {
            await whisperContext.releaseResources()
        }
        try Task.checkCancellation()

        guard let text else {
            logger.error("❌ Core transcription engine failed (whisper_full).")
            throw VoiceInkEngineError.whisperCoreFailed
        }

        logger.notice("Whisper transcription completed successfully.")

        return text
    }

    @MainActor
    private func loadedWhisperContext(for modelName: String) -> WhisperContext? {
        guard let provider = modelProvider,
            provider.isModelLoaded,
            provider.loadedWhisperModel?.name == modelName
        else { return nil }
        return provider.whisperContext
    }

    private func readAudioSamples(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        let floats = stride(from: 44, to: data.count, by: 2).map {
            return data[$0..<$0 + 2].withUnsafeBytes {
                let short = Int16(littleEndian: $0.load(as: Int16.self))
                return max(-1.0, min(Float(short) / 32767.0, 1.0))
            }
        }
        return floats
    }
}
