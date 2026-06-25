import SwiftUI

@main
struct HerdiApp: App {
    @State private var codex = CodexConnection()

    var body: some Scene {
        WindowGroup {
            CodexConsoleView()
                .environment(codex)
                .preferredColorScheme(.dark)
                .onAppear {
                    NotificationManager.shared.requestPermission()
                }
        }
    }
}
