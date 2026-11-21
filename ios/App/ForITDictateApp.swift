import ForITCommon
import SwiftUI

@main
struct ForITDictateApp: App {
    @StateObject private var coordinator = ForITDictateApp.makeCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            root
                .environmentObject(coordinator)
                .forITTint()
                .forITScreenBackground()
                .forITScreenHarness()
                .onOpenURL { coordinator.open($0) }
                .task { await coordinator.refreshReadiness() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await coordinator.refreshReadiness() }
                }
        }
    }

    /// The home screen, or in a Debug build under the device matrix, the keyboard's own view.
    @ViewBuilder private var root: some View {
        #if DEBUG
        switch ScreenshotScene.current {
        case .keyboard: KeyboardPreviewScene(state: .idle)
        case .keyboardListening: KeyboardPreviewScene(state: .listening)
        case .keyboardAccess: KeyboardPreviewScene(state: .fullAccessNeeded)
        default: HomeView()
        }
        #else
        HomeView()
        #endif
    }

    @MainActor private static func makeCoordinator() -> DictationCoordinator {
        #if DEBUG
        if let scene = ScreenshotScene.current { return .sample(scene) }
        #endif
        return DictationCoordinator()
    }
}
