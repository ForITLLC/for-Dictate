import Foundation

/// ForIT Dictate keeps dictated text on the Mac: no cloud speech-to-text or AI provider is approved for it
/// (ForIT Dispatch, 2026-10-16). The cloud providers' code stays, hidden. To approve one, add it here.
enum ForITProviderPolicy {
    /// Cloud transcription providers shown and usable. Local providers are always allowed.
    static let approvedCloudTranscriptionProviders: Set<ModelProvider> = []
    /// AI enhancement providers shown and usable. Not .localCLI: its templates (claude, codex, copilot) send the
    /// transcript to a cloud model.
    static let approvedEnhancementProviders: Set<AIProvider> = [.ollama, .voiceInkRefine]
    /// User-defined cloud endpoints (custom transcription models and the custom AI provider).
    static let allowsCustomCloudEndpoints = false

    /// Note shown where the cloud provider list used to be.
    static let cloudProvidersOffNote = "ForIT Dictate keeps dictation on this Mac; cloud providers are turned off."

    /// Transcription providers that run on this Mac. Never filtered.
    static let localTranscriptionProviders: Set<ModelProvider> = [.whisper, .fluidAudio, .transcribeCpp, .nativeApple]

    /// Enhancement provider used when nothing saved or selected is approved.
    static let fallbackEnhancementProvider: AIProvider = .voiceInkRefine

    static func allowsTranscription(_ provider: ModelProvider) -> Bool {
        if localTranscriptionProviders.contains(provider) { return true }
        if provider == .custom { return allowsCustomCloudEndpoints }
        return approvedCloudTranscriptionProviders.contains(provider)
    }

    static func allowsEnhancement(_ provider: AIProvider) -> Bool {
        if provider == .custom { return allowsCustomCloudEndpoints }
        return approvedEnhancementProviders.contains(provider)
    }

    /// Ollama is local only while its server is on this Mac, so a base URL naming another host is refused.
    static func allowsOllamaServer(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    /// Approved enhancement providers that need an API key, i.e. the cloud ones.
    static var hasApprovedCloudEnhancementProviders: Bool {
        approvedEnhancementProviders.contains { $0.requiresAPIKey && $0 != .custom }
    }

    /// True when the Model Catalog's Cloud tab has anything to show.
    static var hasApprovedCloudProviders: Bool {
        !approvedCloudTranscriptionProviders.isEmpty || hasApprovedCloudEnhancementProviders
    }
}
