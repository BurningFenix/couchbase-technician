import SwiftUI
import AppKit

@main
struct FieldDispatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = Store()

    var body: some Scene {
        WindowGroup("Field Dispatcher") {
            ContentView()
                .environment(store)
                .frame(minWidth: 860, minHeight: 600)
                .task { store.start() }
        }
        .windowResizability(.contentSize)
    }
}

/// A package executable isn't a bundled .app, so it launches as a background
/// process by default. Promote it to a regular foreground app so the window
/// appears and takes focus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
