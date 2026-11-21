#if DEBUG
import Foundation

/// The screens the device matrix photographs (ios/forit-app.json, "screens"). A Debug build
/// opens one from a launch argument:
///
///     -screenshot-scene home|listening|result|keyboard-setup|settings
///                       |keyboard|keyboard-listening|keyboard-access
///
/// Every scene is a made-up state. The microphone stays off, nothing is recorded, and the
/// speech engine is a stand-in that says the language is ready. A Release build has none of this.
enum ScreenshotScene: String {
    case home
    /// The app in front while the keyboard's dictation records.
    case listening
    /// After "Try it here": the text that was heard.
    case result
    case keyboardSetup = "keyboard-setup"
    case settings
    /// The keyboard's own view, drawn inside the app (KeyboardPreviewScene).
    case keyboard
    case keyboardListening = "keyboard-listening"
    /// The keyboard after a tap on the microphone with Full Access off.
    case keyboardAccess = "keyboard-access"

    static let current = UserDefaults.standard.string(forKey: "screenshot-scene")
        .flatMap(ScreenshotScene.init(rawValue:))

    static let sampleText = "The quarterly numbers are ready for review. I will send the summary before lunch."

    /// The line of typed text above the keyboard scenes. One short line: at the largest text
    /// size the keyboard leaves room for a single line on the smallest phone, and a longer
    /// stand-in ended in "…" there, which read as a cut-off in the contact sheet.
    static let typedText = "On my way."
}

/// Says the language is ready and hears nothing.
struct SampleSpeechEngine: SpeechEngine {
    func readiness() async -> SpeechReadiness { .ready(language: "English (United States)") }
    func install() async -> SpeechReadiness { .ready(language: "English (United States)") }
    func transcribe(fileAt url: URL, seconds: Double) async throws -> String { "" }
}
#endif
