import ForITCommon
import SwiftUI

/// Settings, opened from the ForIT panel.
struct DictateSettingsView: View {
    var body: some View {
        Form {
            Section("Privacy") {
                Text("Dictation runs on this device with the speech built into iOS. Recordings are deleted as soon as they are turned into text, and no history is kept.")
            }
            ForITAboutSection()
        }
    }
}
