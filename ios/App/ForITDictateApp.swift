import ForITCommon
import SwiftUI

@main
struct ForITDictateApp: App {
    @StateObject private var coordinator = DictationCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(coordinator)
                .forITTint()
                .forITScreenBackground()
                .onOpenURL { coordinator.open($0) }
                .task { await coordinator.refreshReadiness() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await coordinator.refreshReadiness() }
                }
        }
    }
}
