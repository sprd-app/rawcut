import UIKit
import UserNotifications
import BackgroundTasks

final class AppDelegate: NSObject, UIApplicationDelegate, @unchecked Sendable {

    // MARK: - Background Task Identifiers

    static let backgroundSyncTaskID = "com.rawcut.app.sync"
    static let backgroundProcessingTaskID = "com.rawcut.app.processing"

    // Set from RawcutApp after services are initialized
    weak var syncEngine: SyncEngine?
    var uploadManager: UploadManager?

    // MARK: - UIApplicationDelegate

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        registerBackgroundTasks()
        requestNotificationPermissions()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("[Rawcut] APNs device token: \(token)")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        print("[Rawcut] Failed to register for remote notifications: \(error.localizedDescription)")
    }

    // MARK: - Background URL Session

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        guard identifier == UploadManager.sessionIdentifier else {
            completionHandler()
            return
        }
        print("[Rawcut] System woke app for background upload session")
        uploadManager?.handleBackgroundEvents(completionHandler: completionHandler)
    }

    // MARK: - Push Notifications

    private func requestNotificationPermissions() {
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            } catch {
                print("[Rawcut] Notification auth error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Background Tasks

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundSyncTaskID,
            using: nil
        ) { task in
            self.handleBackgroundSync(task: task as! BGAppRefreshTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundProcessingTaskID,
            using: nil
        ) { task in
            self.handleBackgroundProcessing(task: task as! BGProcessingTask)
        }
    }

    private func handleBackgroundSync(task: BGAppRefreshTask) {
        scheduleBackgroundSync()

        let engine = syncEngine
        let syncTask = Task {
            await engine?.performBackgroundSync()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            syncTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    private func handleBackgroundProcessing(task: BGProcessingTask) {
        let engine = syncEngine
        let processingTask = Task {
            await engine?.performBackgroundSync()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            processingTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    func scheduleBackgroundSync() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundSyncTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[Rawcut] Failed to schedule background sync: \(error.localizedDescription)")
        }
    }
}
