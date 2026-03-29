import SwiftUI
import SwiftData

@main
struct RawcutApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Services — initialized once, shared via environment
    @StateObject private var syncEngine: SyncEngine
    @StateObject private var photoObserver: PhotoLibraryObserver
    @StateObject private var networkMonitor: NetworkMonitor
    @StateObject private var authManager: AuthManager

    var sharedModelContainer: ModelContainer = {
        LocalStore.shared.container
    }()

    init() {
        let container = LocalStore.shared.container
        let auth = AuthManager()
        let network = NetworkMonitor()
        let upload = UploadManager(authManager: auth)
        let engine = SyncEngine(
            uploadManager: upload,
            networkMonitor: network,
            modelContainer: container
        )
        let observer = PhotoLibraryObserver(
            modelContainer: container,
            syncEngine: engine
        )

        _syncEngine = StateObject(wrappedValue: engine)
        _photoObserver = StateObject(wrappedValue: observer)
        _networkMonitor = StateObject(wrappedValue: network)
        _authManager = StateObject(wrappedValue: auth)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(syncEngine)
                .environmentObject(photoObserver)
                .environmentObject(networkMonitor)
                .environmentObject(authManager)
                .preferredColorScheme(.dark)
                .task {
                    // NetworkMonitor starts automatically in init()
                    // Check current photo authorization (don't auto-request, let UI handle it)
                    photoObserver.refreshAuthorizationStatus()
                    let status = photoObserver.authorizationStatus
                    if status == .authorized || status == .limited {
                        photoObserver.performInitialImport()
                        photoObserver.startObserving()
                        syncEngine.startSync()
                    }
                    // If .notDetermined or .denied, MediaHubView shows the "Grant Access" button
                    // which calls photoObserver.requestAuthorization()
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
