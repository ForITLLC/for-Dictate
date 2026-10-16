import Charts
import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager

    var body: some View {
        DashboardContent(modelContext: modelContext)
    }
}
