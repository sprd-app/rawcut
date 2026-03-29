import SwiftUI
import SwiftData

@main
struct RawcutApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var sharedModelContainer: ModelContainer = {
        LocalStore.shared.container
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .modelContainer(sharedModelContainer)
    }
}
