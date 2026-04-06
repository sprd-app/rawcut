import SwiftUI
import SwiftData

@main
struct RawcutApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

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
        let download = DownloadManager(authManager: auth)

        let observer = PhotoLibraryObserver(
            modelContainer: container,
            syncEngine: engine,
            downloadManager: download
        )
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

                    // Check storage optimization recommendation on launch
                    storageManager.checkOptimizationRecommendation()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    syncEngine.handleScenePhaseChange(isActive: newPhase == .active)

                    if newPhase == .active {
                        // Re-import any photos taken while app was inactive
                        if photoObserver.authorizationStatus == .authorized ||
                           photoObserver.authorizationStatus == .limited {
                            photoObserver.performInitialImport()
                        }
                        // Check storage optimization on every foreground return (item 6)
                        storageManager.checkOptimizationRecommendation()
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
