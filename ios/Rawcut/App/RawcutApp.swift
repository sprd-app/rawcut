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
    @StateObject private var downloadManager: DownloadManager
    @StateObject private var storageManager: StorageManager

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

        let download = DownloadManager(authManager: auth)
        let storage = StorageManager(modelContainer: container)

        _syncEngine = StateObject(wrappedValue: engine)
        _photoObserver = StateObject(wrappedValue: observer)
        _networkMonitor = StateObject(wrappedValue: network)
        _authManager = StateObject(wrappedValue: auth)
        _downloadManager = StateObject(wrappedValue: download)
        _storageManager = StateObject(wrappedValue: storage)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(syncEngine)
                .environmentObject(photoObserver)
                .environmentObject(networkMonitor)
                .environmentObject(authManager)
                .environmentObject(downloadManager)
                .environmentObject(storageManager)
                .preferredColorScheme(.dark)
                .task {
                    // Wire services to AppDelegate for background task handling
                    appDelegate.syncEngine = syncEngine
                    appDelegate.uploadManager = syncEngine.uploadManagerRef
                    syncEngine.setStorageManager(storageManager)
                    // NetworkMonitor starts automatically in init()
                    // Check current photo authorization (don't auto-request, let UI handle it)
                    photoObserver.refreshAuthorizationStatus()
                    var status = photoObserver.authorizationStatus
                    print("[Rawcut] Photo auth status: \(status)")
                    if status == .notDetermined {
                        await photoObserver.requestAuthorization()
                        status = photoObserver.authorizationStatus
                    }
                    if status == .authorized || status == .limited {
                        photoObserver.performInitialImport()
                        photoObserver.startObserving()
                        syncEngine.startSync()
                    }
                    // If .notDetermined or .denied, MediaHubView shows the "Grant Access" button
                    // which calls photoObserver.requestAuthorization()

                    // Auto-optimize storage on launch if needed
                    await storageManager.autoOptimizeIfNeeded()
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
