import ForITCommon
import SwiftUI
import UIKit

/// The steps, in words. iOS tells an app neither whether its keyboard is added
/// nor whether Full Access is on, so this screen shows no checkmarks.
struct KeyboardSetupView: View {
    @Environment(\.openURL) private var openURL
    @State private var settingsUnavailable = false

    var body: some View {
        Form {
            Section("Add the keyboard") {
                Text("1. Open Settings, then General → Keyboard → Keyboards.")
                Text("2. Tap Add New Keyboard, then choose ForIT Dictate.")
                Text("3. Open ForIT Dictate in the keyboard list and turn on Allow Full Access.")
                Button("Open this app’s settings", systemImage: "arrow.up.right.square") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else {
                        settingsUnavailable = true
                        return
                    }
                    openURL(url) { accepted in settingsUnavailable = !accepted }
                }
                .buttonStyle(.forITSecondary)
                .accessibilityIdentifier("dictate.keyboard.openSettings")
                if settingsUnavailable {
                    Text("Settings couldn’t be opened. Open Settings from your Home Screen and follow the steps above.")
                }
            }
            Section("Why Full Access is needed") {
                Text("A keyboard cannot use the microphone, so this app listens for it. Full Access lets the keyboard open this app and collect the finished text from it.")
                Text("What you say is turned into text on this device. The keyboard sends nothing anywhere and does not read what you type.")
                    .foregroundStyle(.secondary)
            }
            Section("Dictate") {
                Text("In any text field, touch and hold the globe key and choose ForIT Dictate. Tap the microphone. The first time, this app opens to turn the microphone on: go back to where you were typing and keep talking, then tap the microphone again to finish.")
                Text("For the next five minutes the microphone key starts at once, without opening this app.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Set up the keyboard")
        .forITInlineTitle()
    }
}
