import ForITCommon
import SwiftUI
import UIKit

/// The app's one screen: where a dictation stands, a place to try it, the
/// language, and the way to the keyboard's set-up steps.
struct HomeView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if !coordinator.trialText.isEmpty {
                    trialSection
                }
                languageSection
                Section("Keyboard") {
                    NavigationLink {
                        KeyboardSetupView()
                    } label: {
                        Label("Set up the keyboard", systemImage: "keyboard")
                    }
                }
            }
            .forITGroupedList()
            .navigationTitle("ForIT Dictate")
            .forITProfileMenu(account: nil, settings: { DictateSettingsView() })
        }
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label(statusTitle, systemImage: statusSymbol)
                    .font(.headline)
                    .foregroundStyle(coordinator.phase == .recording ? Color.red : Color.primary)
                    .accessibilityIdentifier("dictate.status")
                Text(statusDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let notice = coordinator.notice {
                    Text(notice)
                        .font(.subheadline)
                        .accessibilityIdentifier("dictate.notice")
                }
            }
            .padding(.vertical, 4)

            Button(action: coordinator.toggleTrial) {
                Label(coordinator.phase == .recording ? "Stop" : "Try it here", systemImage: coordinator.phase == .recording ? "stop.fill" : "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.forITPrimary)
            .disabled(coordinator.phase == .transcribing)
            .accessibilityIdentifier("dictate.toggle")

            if coordinator.phase == .ready {
                Button("Turn the microphone off", action: coordinator.turnMicrophoneOff)
                    .buttonStyle(.forITSecondary)
                    .accessibilityIdentifier("dictate.microphoneOff")
            }
            if coordinator.microphoneDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.forITSecondary)
            }
        }
    }

    private var statusTitle: String {
        switch coordinator.phase {
        case .idle: return "Microphone off"
        case .ready: return "Ready"
        case .recording: return "Listening"
        case .transcribing: return "Writing it out"
        }
    }

    private var statusSymbol: String {
        switch coordinator.phase {
        case .idle: return "mic.slash"
        case .ready: return "mic"
        case .recording: return "waveform"
        case .transcribing: return "text.cursor"
        }
    }

    private var statusDetail: String {
        switch coordinator.phase {
        case .idle:
            return "Tap the microphone on the ForIT Dictate keyboard, or try it here."
        case .ready:
            return "The microphone stays on for five minutes so the keyboard can start without opening this app. Nothing is kept unless you are dictating."
        case .recording:
            return coordinator.recordingForKeyboard
                ? "Go back to the app you were typing in and keep talking. Tap the microphone key again when you are done."
                : "Say something, then tap Stop."
        case .transcribing:
            return "Your words are turned into text on this device."
        }
    }

    // MARK: Trial

    private var trialSection: some View {
        Section("What you said") {
            Text(coordinator.trialText)
                .textSelection(.enabled)
                .accessibilityIdentifier("dictate.trialText")
            Button {
                UIPasteboard.general.string = coordinator.trialText
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    // MARK: Language

    private var languageSection: some View {
        Section("Language") {
            switch coordinator.readiness {
            case .checking:
                Label("Checking", systemImage: "hourglass")
            case .ready(let language):
                Label(language, systemImage: "checkmark.circle")
            case .needsDownload(let language):
                Text("\(language) needs a one-time download before you can dictate.")
                Button("Download \(language)") {
                    Task { await coordinator.downloadLanguage() }
                }
                .buttonStyle(.forITPrimary)
                .accessibilityIdentifier("dictate.downloadLanguage")
            case .downloading(let language):
                HStack {
                    ProgressView()
                    Text("Downloading \(language)")
                }
            case .unsupported:
                Text("This iPhone's language is not supported for dictation.")
            case .failed(let reason):
                Text("The language could not be downloaded. \(reason)")
                Button("Try again") {
                    Task { await coordinator.downloadLanguage() }
                }
                .buttonStyle(.forITSecondary)
            }
        }
    }
}
