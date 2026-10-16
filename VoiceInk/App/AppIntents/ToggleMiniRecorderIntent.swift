import AppIntents
import AppKit
import Foundation

struct ToggleMiniRecorderIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle ForIT Dictate Recorder"
    static var description = IntentDescription("Start or stop the ForIT Dictate recorder for voice transcription.")

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .toggleRecorderPanel, object: nil)

        let dialog: IntentDialog = "ForIT Dictate recorder toggled"
        return .result(dialog: dialog)
    }
}

enum IntentError: Error, LocalizedError {
    case appNotAvailable
    case serviceNotAvailable

    var errorDescription: String? {
        switch self {
        case .appNotAvailable:
            return String(localized: "ForIT Dictate app is not available")
        case .serviceNotAvailable:
            return String(localized: "ForIT Dictate recording service is not available")
        }
    }
}
