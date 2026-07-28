import SwiftUI
import Observation

enum AppTab: Hashable {
    case work, ask, assets, parts, settings
}

/// Cross-tab navigation: detail screens can jump to Ask with an asset
/// context attached.
@Observable
@MainActor
final class AppRouter {
    var selectedTab: AppTab = .work
}

struct ContentView: View {
    @Environment(DatabaseManager.self) private var dbManager
    @Environment(AppRouter.self) private var router
    @Environment(ChatEngine.self) private var chatEngine

    var body: some View {
        @Bindable var router = router
        Group {
            if dbManager.isReady {
                TabView(selection: $router.selectedTab) {
                    Tab("Work", systemImage: "list.clipboard", value: AppTab.work) {
                        WorkView()
                    }

                    Tab("Ask", systemImage: "questionmark.bubble", value: AppTab.ask) {
                        ChatAskView()
                    }

                    Tab("Assets", systemImage: "wrench.and.screwdriver", value: AppTab.assets) {
                        AssetsView()
                    }

                    Tab("Parts", systemImage: "shippingbox", value: AppTab.parts) {
                        PartsView()
                    }

                    Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                        SettingsView()
                    }
                }
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("FieldCopilot")
                        .font(.title2.bold())
                    ProgressView(value: dbManager.launchProgress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 280)
                    Text(dbManager.statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.default, value: dbManager.statusMessage)
                }
                .padding()
            }
        }
        .task {
            await dbManager.initialize()
            chatEngine.prewarmQwenIfNeeded()
        }
    }
}
