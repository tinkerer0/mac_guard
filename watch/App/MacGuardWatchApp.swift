import SwiftUI

@main
struct MacGuardWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView(model: delegate.model)
        }
    }
}
