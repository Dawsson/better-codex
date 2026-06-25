import SwiftUI

@main
struct BetterCodexApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var codex = CodexConnection()

    var body: some Scene {
        WindowGroup {
            CodexConsoleView()
                .environment(codex)
                .preferredColorScheme(.dark)
                .onAppear {
                    NotificationManager.shared.requestPermission()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        codex.reconnectIfNeeded()
                    }
                }
        }
    }
}
