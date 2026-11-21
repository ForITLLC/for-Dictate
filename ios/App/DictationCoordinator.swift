import AVFoundation
import Foundation
import SwiftUI
import UIKit

/// Runs a dictation from start to typed text, for the keyboard and for the
/// "try it here" button in the app.
///
/// The app is the only place the microphone can live. A dictation from the
/// keyboard arrives one of two ways: the keyboard opens the app (the microphone
/// is off, and iOS turns it on only for an app on screen), or, while the
/// microphone is still on from a moment ago, the keyboard signals and the app
/// starts in the background. After each dictation the microphone stays on for
/// `readyWindow`, keeping nothing, and then turns itself off.
@MainActor
final class DictationCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case ready
        case recording
        case transcribing
    }

    /// How long the microphone stays on after a dictation, waiting for the next one.
    static let readyWindow: TimeInterval = 5 * 60
    /// A dictation left running stops itself here.
    static let longestDictation: TimeInterval = 10 * 60

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var readiness: SpeechReadiness = .checking
    /// The last thing that went wrong, in plain words. Cleared by the next dictation.
    @Published private(set) var notice: String?
    /// The text from the last "try it here" dictation. In memory only.
    @Published private(set) var trialText = ""
    /// Whether the dictation on screen was asked for by the keyboard.
    @Published private(set) var recordingForKeyboard = false
    @Published private(set) var microphoneDenied = false

    private struct Dictation {
        let id: UUID
        let fromKeyboard: Bool
        let audioURL: URL
    }

    private let audio = AudioCapture()
    private let engine: SpeechEngine
    private let store: DictationHandoffStore?
    private var signals: DarwinSignalObserver?
    private var current: Dictation?
    private var readyUntil: Date?
    private var readyTimer: Timer?
    private var limitTimer: Timer?
    private var starting = false

    init(engine: SpeechEngine = AppleSpeechEngine()) {
        self.engine = engine
        self.store = DictationHandoffStore.shared()
        audio.onEnded = { [weak self] in
            Task { @MainActor in self?.microphoneEndedUnasked() }
        }
        signals = DarwinSignalObserver([.start, .stop, .cancel]) { [weak self] signal in
            Task { @MainActor in self?.handle(signal) }
        }
        Self.removeLeftoverAudio()
        store?.removeStaleResult()
        publish()
    }

    // MARK: Language

    func refreshReadiness() async {
        readiness = await engine.readiness()
    }

    func downloadLanguage() async {
        if case .needsDownload(let language) = readiness {
            readiness = .downloading(language: language)
        }
        readiness = await engine.install()
    }

    // MARK: Entry points

    /// `io.forit.dictate://dictate?request=<uuid>`, opened by the keyboard.
    func open(_ url: URL) {
        guard let id = DictationHandoff.requestID(from: url) else { return }
        // The keyboard may have signalled first and this app already started the same request.
        guard current?.id != id else { return }
        Task { await begin(id: id, fromKeyboard: true) }
    }

    /// The button in the app.
    func toggleTrial() {
        switch phase {
        case .recording:
            finish()
        case .idle, .ready:
            Task { await begin(id: UUID(), fromKeyboard: false) }
        case .transcribing:
            break
        }
    }

    /// "Turn the microphone off" in the app.
    func turnMicrophoneOff() {
        guard phase == .ready else { return }
        endSession()
    }

    private func handle(_ signal: DictationHandoff.Signal) {
        switch signal {
        case .start:
            // Only when the microphone is already on. Otherwise the keyboard opens the app, which is the other path.
            guard phase == .ready, audio.isRunning, let request = store?.request() else { return }
            Task { await begin(id: request.id, fromKeyboard: true) }
        case .stop:
            guard phase == .recording, current?.fromKeyboard == true else { return }
            finish()
        case .cancel:
            guard phase == .recording, current?.fromKeyboard == true else { return }
            discard()
        case .changed:
            break
        }
    }

    // MARK: A dictation

    private func begin(id: UUID, fromKeyboard: Bool) async {
        guard !starting, phase == .idle || phase == .ready else { return }
        starting = true
        defer { starting = false }
        notice = nil
        if fromKeyboard { store?.clearRequest() }

        guard await microphoneAllowed() else {
            microphoneDenied = true
            fail(id: id, fromKeyboard: fromKeyboard, "ForIT Dictate needs the microphone. Turn it on in Settings, under ForIT Dictate.")
            return
        }
        microphoneDenied = false

        if !readiness.isReady { await refreshReadiness() }
        guard readiness.isReady else {
            if case .needsDownload = readiness {
                fail(id: id, fromKeyboard: fromKeyboard, "Dictation needs a one-time language download. It has started; try again in a moment.")
                await downloadLanguage()
            } else {
                fail(id: id, fromKeyboard: fromKeyboard, "Dictation is not ready on this iPhone yet. Open ForIT Dictate to see why.")
            }
            return
        }

        do {
            if !audio.isRunning {
                await waitUntilActive()
                try audio.start()
            }
            let url = Self.audioDirectory.appendingPathComponent("dictation-\(id.uuidString).wav")
            try FileManager.default.createDirectory(at: Self.audioDirectory, withIntermediateDirectories: true)
            try audio.beginCapture(to: url)
            current = Dictation(id: id, fromKeyboard: fromKeyboard, audioURL: url)
        } catch {
            if !audio.isRunning { endSession() }
            fail(id: id, fromKeyboard: fromKeyboard, "The microphone could not start. Open ForIT Dictate and try again.")
            return
        }

        readyTimer?.invalidate()
        readyUntil = nil
        recordingForKeyboard = fromKeyboard
        phase = .recording
        limitTimer?.invalidate()
        limitTimer = Timer.scheduledTimer(withTimeInterval: Self.longestDictation, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
        publish()
    }

    /// Stops recording and types (or shows) what was said.
    func finish() {
        guard phase == .recording, let dictation = current else { return }
        limitTimer?.invalidate()
        let capture = audio.endCapture()
        phase = .transcribing
        publish()

        Task {
            var text = ""
            var failure: String?
            do {
                guard let capture, capture.seconds >= 0.3 else { throw AppleSpeechEngine.Failure.nothingRecorded }
                text = DictationText.clean(try await engine.transcribe(fileAt: capture.url, seconds: capture.seconds))
                if text.isEmpty { failure = "Nothing was heard." }
            } catch {
                failure = error.localizedDescription
            }
            try? FileManager.default.removeItem(at: dictation.audioURL)
            deliver(dictation, text: text, failure: failure)
        }
    }

    private func discard() {
        guard let dictation = current else { return }
        limitTimer?.invalidate()
        _ = audio.endCapture()
        try? FileManager.default.removeItem(at: dictation.audioURL)
        settle()
    }

    private func deliver(_ dictation: Dictation, text: String, failure: String?) {
        if dictation.fromKeyboard {
            try? store?.write(DictationResult(requestID: dictation.id, text: text, failure: failure, createdAt: Date()))
        } else {
            trialText = text
        }
        notice = failure
        settle()
    }

    private func fail(id: UUID, fromKeyboard: Bool, _ message: String) {
        notice = message
        if fromKeyboard {
            try? store?.write(DictationResult(requestID: id, text: "", failure: message, createdAt: Date()))
        }
        publish()
    }

    /// Back to waiting: ready while the microphone is still on, idle when it is not.
    private func settle() {
        current = nil
        recordingForKeyboard = false
        if audio.isRunning {
            phase = .ready
            let until = Date().addingTimeInterval(Self.readyWindow)
            readyUntil = until
            readyTimer?.invalidate()
            readyTimer = Timer.scheduledTimer(withTimeInterval: Self.readyWindow, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.phase == .ready else { return }
                    self.endSession()
                }
            }
        } else {
            phase = .idle
            readyUntil = nil
        }
        publish()
    }

    private func endSession() {
        readyTimer?.invalidate()
        limitTimer?.invalidate()
        audio.stop()
        current = nil
        recordingForKeyboard = false
        readyUntil = nil
        phase = .idle
        publish()
    }

    /// A phone call or another app took the microphone. What was said so far is still transcribed.
    private func microphoneEndedUnasked() {
        readyTimer?.invalidate()
        readyUntil = nil
        switch phase {
        case .recording:
            finish()
        case .ready:
            phase = .idle
            publish()
        case .idle, .transcribing:
            break
        }
    }

    // MARK: Helpers

    /// Tells the keyboard where things stand.
    private func publish() {
        store?.removeStaleResult()
        let shared: DictationState.Phase
        switch phase {
        case .idle: shared = .idle
        case .ready: shared = .ready
        case .recording: shared = .recording
        case .transcribing: shared = .transcribing
        }
        try? store?.write(DictationState(phase: shared, requestID: current?.id, updatedAt: Date(), readyUntil: readyUntil))
        DarwinSignal.post(.changed)
    }

    private func microphoneAllowed() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }

    /// Opened by the keyboard, the app can be asked to record a moment before iOS calls it active.
    private func waitUntilActive() async {
        for _ in 0..<20 where UIApplication.shared.applicationState != .active {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private static var audioDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Dictations", isDirectory: true)
    }

    /// Audio from a dictation that was cut off by the app being closed.
    private static func removeLeftoverAudio() {
        try? FileManager.default.removeItem(at: audioDirectory)
    }
}
