import AVFoundation
import Foundation
import Speech

/// Whether the speech engine can transcribe right now.
enum SpeechReadiness: Equatable {
    case checking
    case ready(language: String)
    case needsDownload(language: String)
    case downloading(language: String)
    case unsupported
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// What turns a recorded dictation into text. One conformer today; the
/// coordinator knows only this protocol, so the engine can change without it.
protocol SpeechEngine {
    func readiness() async -> SpeechReadiness
    /// Downloads what the language needs, when it needs anything.
    func install() async -> SpeechReadiness
    func transcribe(fileAt url: URL, seconds: Double) async throws -> String
}

/// Apple's on-device speech (SpeechAnalyzer with SpeechTranscriber), the same
/// calls the Mac app's Apple Speech engine makes. The operating system owns the
/// model; this app ships none, and no audio leaves the device.
struct AppleSpeechEngine: SpeechEngine {
    enum Failure: LocalizedError {
        case languageNotSupported
        case languageNotDownloaded(String)
        case nothingRecorded
        case timedOut

        var errorDescription: String? {
            switch self {
            case .languageNotSupported:
                return "This iPhone's language is not supported for dictation."
            case .languageNotDownloaded(let language):
                return "\(language) needs a one-time download. Open ForIT Dictate to get it."
            case .nothingRecorded:
                return "Nothing was recorded."
            case .timedOut:
                return "Dictation took too long to finish. Try again."
            }
        }
    }

    private struct Language {
        let locale: Locale
        let identifier: String
        let name: String
        let transcriber: SpeechTranscriber
        let isInstalled: Bool
    }

    var preferredLocale: Locale = .current

    func readiness() async -> SpeechReadiness {
        guard let language = await language() else { return .unsupported }
        if language.isInstalled { return .ready(language: language.name) }
        switch await AssetInventory.status(forModules: [language.transcriber]) {
        case .installed: return .ready(language: language.name)
        case .supported: return .needsDownload(language: language.name)
        case .downloading: return .downloading(language: language.name)
        case .unsupported: return .unsupported
        @unknown default: return .needsDownload(language: language.name)
        }
    }

    func install() async -> SpeechReadiness {
        guard let language = await language() else { return .unsupported }
        if !language.isInstalled {
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [language.transcriber]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        await reserve(language)
        return await readiness()
    }

    func transcribe(fileAt url: URL, seconds: Double) async throws -> String {
        guard let language = await language() else { throw Failure.languageNotSupported }
        guard language.isInstalled else { throw Failure.languageNotDownloaded(language.name) }
        await reserve(language)

        let audioFile = try AVAudioFile(forReading: url)
        let transcriber = language.transcriber
        let modules: [any SpeechModule] = [transcriber]
        let analyzer = SpeechAnalyzer(modules: modules)
        let results = Task<String, Error> {
            var transcript = ""
            for try await result in transcriber.results {
                transcript += String(result.text.characters)
            }
            return transcript
        }

        // Ending the analyzer is what ends the result stream, so the limit does that itself:
        // it does not depend on anything else noticing a cancellation.
        let limit = max(20, seconds * 4 + 10)
        let started = Date()
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            results.cancel()
            await analyzer.cancelAndFinishNow()
        }
        defer { watchdog.cancel() }

        do {
            guard let lastSample = try await analyzer.analyzeSequence(from: audioFile) else {
                throw Failure.nothingRecorded
            }
            try await analyzer.finalizeAndFinish(through: lastSample)
            let text = try await results.value
            guard Date().timeIntervalSince(started) < limit else { throw Failure.timedOut }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            watchdog.cancel()
            results.cancel()
            await analyzer.cancelAndFinishNow()
            if Date().timeIntervalSince(started) >= limit { throw Failure.timedOut }
            throw error
        }
    }

    // MARK: Language

    private func language() async -> Language? {
        var supported = await SpeechTranscriber.supportedLocale(equivalentTo: preferredLocale)
        if supported == nil {
            supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        }
        guard let locale = supported else { return nil }
        let identifier = locale.identifier(.bcp47)
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        // The installed list is the truth; the inventory status can lag behind it.
        let installed = await SpeechTranscriber.installedLocales
        return Language(
            locale: locale,
            identifier: identifier,
            name: Locale.current.localizedString(forIdentifier: identifier) ?? identifier,
            transcriber: transcriber,
            isInstalled: installed.contains { $0.identifier(.bcp47) == identifier })
    }

    /// Asks the system to keep the language's assets. A refusal is not fatal: installed assets still work.
    private func reserve(_ language: Language) async {
        let reserved = await AssetInventory.reservedLocales
        guard !reserved.contains(where: { $0.identifier(.bcp47) == language.identifier }) else { return }
        _ = try? await AssetInventory.reserve(locale: language.locale)
    }
}
