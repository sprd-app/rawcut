import UIKit
import UserNotifications
import BackgroundTasks

final class AppDelegate: NSObject, UIApplicationDelegate, @unchecked Sendable {

    // MARK: - Background Task Identifiers

    static let backgroundSyncTaskID = "com.rawcut.app.sync"
    static let backgroundProcessingTaskID = "com.rawcut.app.processing"

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
        // TODO: Send token to backend
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        print("[Rawcut] Failed to register for remote notifications: \(error.localizedDescription)")
    }

    // MARK: - Push Notifications

    private func requestNotificationPermissions() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
            if let error {
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

        let syncTask = Task {
            // TODO: Perform incremental media sync
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            syncTask.cancel()
        }
    }

    private func handleBackgroundProcessing(task: BGProcessingTask) {
        let processingTask = Task {
            // TODO: Perform heavy processing (thumbnail generation, etc.)
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            processingTask.cancel()
        }
    }

    func scheduleBackgroundSync() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundSyncTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[Rawcut] Failed to schedule background sync: \(error.localizedDescription)")
        }
    }
}
