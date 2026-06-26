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
                    codex.refreshAfterForeground()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        codex.refreshAfterForeground()
                    }
                }
                .onOpenURL { url in
                    codex.configure(from: url)
                }
        }
    }
}
