import Foundation
import SwiftData

protocol CloudProvider: Sendable {
    var modelProvider: ModelProvider { get }
    var providerKey: String { get }
    var languageCodes: [String]? { get }
    var includesAutoDetect: Bool { get }
    var models: [CloudModel] { get }
    /// True when the provider has no batch HTTP endpoint and requires streaming for all transcription.
    var isStreamingOnly: Bool { get }

    func transcribe(
        audioData: Data, fileName: String, apiKey: String, model: String, language: String?,
        customVocabulary: [String], timeout: TimeInterval
    ) async throws -> String
    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)?
    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?)
}

extension CloudProvider {
    var isStreamingOnly: Bool { false }

    /// Streaming-only providers inherit this and get a clear error if batch is somehow attempted.
    /// Providers that support batch transcription override this with their real implementation.
    func transcribe(
        audioData: Data, fileName: String, apiKey: String, model: String, language: String?,
        customVocabulary: [String], timeout: TimeInterval
    ) async throws -> String {
        throw CloudTranscriptionError.unsupportedProvider
    }
}

enum CloudProviderRegistry {
    /// Every cloud provider the code knows. Only `allProviders` (filtered by ForITProviderPolicy) is exposed.
    private static let allKnownProviders: [any CloudProvider] = [
        GroqProvider(),
        ElevenLabsProvider(),
        DeepgramProvider(),
        MistralProvider(),
        GeminiProvider(),
        SonioxProvider(),
        SpeechmaticsProvider(),
        AssemblyAIProvider(),
        XAIProvider(),
        CartesiaProvider(),
        OpenRouterProvider(),
    ]

    /// Cloud providers approved by ForITProviderPolicy. Hidden providers are unknown to the rest of the app.
    static let allProviders: [any CloudProvider] = allKnownProviders.filter {
        ForITProviderPolicy.allowsTranscription($0.modelProvider)
    }

    /// Returns nil for a hidden provider, so saved selections that name one resolve as unavailable.
    static func provider(for modelProvider: ModelProvider) -> (any CloudProvider)? {
        allProviders.first { $0.modelProvider == modelProvider }
    }
}
