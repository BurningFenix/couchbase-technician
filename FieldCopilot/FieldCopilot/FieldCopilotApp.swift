import SwiftUI

@main
struct FieldCopilotApp: App {
    @State private var dbManager = DatabaseManager()
    @State private var chatEngine = ChatEngine()
    @State private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(dbManager)
                .environment(chatEngine)
                .environment(router)
                .task {
                    chatEngine.attach(dbManager)
                }
                // Hand MLX's cached GPU buffers back before iOS has to
                // terminate the app to reclaim memory.
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    QwenLLMService.releaseCachedMemory()
                }
        }
    }
}
