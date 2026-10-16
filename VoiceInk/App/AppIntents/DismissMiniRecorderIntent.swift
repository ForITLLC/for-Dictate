import AppIntents
import AppKit
import Foundation

struct DismissMiniRecorderIntent: AppIntent {
    static var title: LocalizedStringResource = "Dismiss ForIT Dictate Recorder"
    static var description = IntentDescription("Dismiss the ForIT Dictate recorder and cancel any active recording.")

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .dismissRecorderPanel, object: nil)

        let dialog: IntentDialog = "ForIT Dictate recorder dismissed"
        return .result(dialog: dialog)
    }
}
