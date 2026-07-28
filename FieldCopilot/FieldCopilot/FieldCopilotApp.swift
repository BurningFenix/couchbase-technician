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
        }
    }
}
