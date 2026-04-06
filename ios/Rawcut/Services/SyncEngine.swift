import Foundation
import SwiftData
import BackgroundTasks
import Photos
import CryptoKit
import UserNotifications

// MARK: - Sync Progress

struct SyncProgress: Sendable {
    var totalItems: Int = 0
    var syncedCount: Int = 0
    var uploadingCount: Int = 0
    var pendingCount: Int = 0
    var failedCount: Int = 0
    var totalBytesSynced: Int64 = 0

    var fraction: Double {
        guard totalItems > 0 else { return 0 }
        return Double(syncedCount) / Double(totalItems)
    }

    var isComplete: Bool {
        pendingCount == 0 && uploadingCount == 0
    }
}

// MARK: - Sync Engine

@MainActor
final class SyncEngine: ObservableObject {

    // MARK: - Published State

    @Published private(set) var syncProgress = SyncProgress()
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var syncStatusMessage: String = "Idle"
    @Published private(set) var lastSyncedDate: Date?

    // MARK: - Dependencies

    let uploadManagerRef: UploadManager
    let modelContainerRef: ModelContainer
    private var uploadManager: UploadManager { uploadManagerRef }
    private let networkMonitor: NetworkMonitor
    private var modelContainer: ModelContainer { modelContainerRef }
    private weak var storageManager: StorageManager?

    // MARK: - Configuration

    private let maxRetries = 3
    private var currentTask: Task<Void, Never>?
    private var isPaused: Bool = false

    /// Reads user preference for Wi-Fi-only sync.
    /// Default matches @AppStorage("syncOnWiFiOnly") = true in SettingsView.
    private var syncOnWiFiOnly: Bool {
        // @AppStorage defaults to true, but UserDefaults.bool returns false for unset keys.
        // Use object(forKey:) to detect never-set state and default to true.
        if UserDefaults.standard.object(forKey: "syncOnWiFiOnly") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "syncOnWiFiOnly")
    }

    /// True if current network state allows syncing based on user preference
    private var isNetworkAllowedForSync: Bool {
        guard networkMonitor.isConnected else { return false }
        if syncOnWiFiOnly && !networkMonitor.isWiFi {
            return false
        }
        return true
    }

    // MARK: - Init

    init(
        uploadManager: UploadManager,
        networkMonitor: NetworkMonitor,
        modelContainer: ModelContainer
    ) {
        self.uploadManagerRef = uploadManager
        self.networkMonitor = networkMonitor
        self.modelContainerRef = modelContainer

        observeNetworkChanges()
    }

    func setStorageManager(_ manager: StorageManager) {
        self.storageManager = manager
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    func startSync() {
        guard !isSyncing else { return }
        guard isNetworkAllowedForSync else {
            if !networkMonitor.isConnected {
                syncStatusMessage = "Waiting for network..."
            } else {
                syncStatusMessage = "Waiting for Wi-Fi..."
            }
            return
        }

        // Reset stale "uploading" assets back to pending (from previous crash/restart)
        let context = ModelContext(modelContainer)
        let uploadingPredicate = #Predicate<MediaAsset> { $0.syncStatusRaw == "uploading" }
        do {
            let stale = try context.fetch(FetchDescriptor<MediaAsset>(predicate: uploadingPredicate))
            if !stale.isEmpty {
                for asset in stale {
                    asset.syncStatus = .pending
                }
                try context.save()
                print("[Rawcut] Reset \(stale.count) stale uploading assets to pending")
            }
        } catch {
            print("[Rawcut] Failed to reset stale uploads: \(error.localizedDescription)")
        }

        isPaused = false
        isSyncing = true
        syncStatusMessage = "Syncing..."

        currentTask = Task {
            await processSyncQueue()
        }
    }

    func pauseSync() {
        isPaused = true
        isSyncing = false
        currentTask?.cancel()
        currentTask = nil
        syncStatusMessage = "Paused"
        print("[Rawcut] Sync paused")
    }

    func retryFailed() {
        let context = ModelContext(modelContainer)
        let predicate = #Predicate<MediaAsset> { $0.syncStatusRaw == "failed" }
        let descriptor = FetchDescriptor<MediaAsset>(predicate: predicate)

        do {
            let failedAssets = try context.fetch(descriptor)
            for asset in failedAssets {
                asset.syncStatus = .pending
            }
            try context.save()
            print("[Rawcut] Reset \(failedAssets.count) failed assets to pending")
            refreshProgress()
            startSync()
        } catch {
            print("[Rawcut] Failed to reset failed assets: \(error.localizedDescription)")
        }
    }

    /// Called by AppDelegate to run sync in a background task context
    func performBackgroundSync() async {
        guard isNetworkAllowedForSync else { return }
        isPaused = false
        await processSyncQueue()
    }

    /// Schedule a BGProcessingTask for overnight catch-up
    func scheduleBackgroundProcessing() {
        let request = BGProcessingTaskRequest(
            identifier: AppDelegate.backgroundProcessingTaskID
        )
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        do {
            try BGTaskScheduler.shared.submit(request)
            print("[Rawcut] Scheduled background processing task")
        } catch {
            print("[Rawcut] Failed to schedule background processing: \(error.localizedDescription)")
        }
    }

    // MARK: - Queue Processing

    private func processSyncQueue() async {
        defer {
            refreshProgress()
            isSyncing = false
            if syncProgress.isComplete {
                syncStatusMessage = "All synced"
                // Auto-optimize storage after sync completes
                Task { await storageManager?.autoOptimizeIfNeeded() }
            }
        }

        while !Task.isCancelled && !isPaused {
            refreshProgress()

            guard isNetworkAllowedForSync else {
                if !networkMonitor.isConnected {
                    syncStatusMessage = "Waiting for network..."
                    print("[Rawcut] Network lost, pausing sync queue")
                } else {
                    syncStatusMessage = "Waiting for Wi-Fi..."
                    print("[Rawcut] Cellular only, waiting for Wi-Fi (syncOnWiFiOnly enabled)")
                }
                return
            }

            // Fetch next pending asset (newest first)
            guard let asset = fetchNextPendingAsset() else {
                print("[Rawcut] Sync queue empty")
                return
            }

            await uploadSingleAsset(asset)
        }
    }

    private func uploadSingleAsset(_ asset: MediaAsset) async {
        let context = ModelContext(modelContainer)
        let identifier = asset.localIdentifier

        // Mark as uploading
        if let dbAsset = fetchAsset(identifier: identifier, in: context) {
            dbAsset.syncStatus = .uploading
            do {
                try context.save()
            } catch {
                print("[Rawcut] Failed to mark \(identifier) as uploading: \(error.localizedDescription)")
            }
        }
        refreshProgress()
        syncStatusMessage = "Uploading..."

        // Export file from Photos library
        guard let fileURL = await exportAssetToTempFile(localIdentifier: identifier) else {
            print("[Rawcut] Failed to export asset \(identifier)")
            markFailed(identifier: identifier, in: context)
            return
        }

        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        // Compute content hash for dedup
        let hash = computeSHA256(fileURL: fileURL)
        if let hash {
            do {
                // Check if another asset with same hash is already synced
                let hashPredicate = #Predicate<MediaAsset> {
                    $0.contentHash == hash && $0.syncStatusRaw == "synced" && $0.localIdentifier != identifier
                }
                let hashDescriptor = FetchDescriptor<MediaAsset>(predicate: hashPredicate)
                if let existing = try context.fetch(hashDescriptor).first,
                   let existingBlob = existing.cloudBlobName {
                    // Duplicate found — skip upload, reuse blob name
                    if let dbAsset = fetchAsset(identifier: identifier, in: context) {
                        dbAsset.syncStatus = .synced
                        dbAsset.cloudBlobName = existingBlob
                        dbAsset.contentHash = hash
                        try context.save()
                    }
                    refreshProgress()
                    print("[Rawcut] Dedup: \(identifier) matches \(existing.localIdentifier), skipping upload")
                    return
                }

                // Store hash on asset
                if let dbAsset = fetchAsset(identifier: identifier, in: context) {
                    dbAsset.contentHash = hash
                    try context.save()
                }
            } catch {
                print("[Rawcut] Dedup check failed for \(identifier): \(error.localizedDescription)")
                // Continue to upload — dedup is an optimization, not critical
            }
        }

        // Attempt upload with retries
        var lastError: Error?
        for attempt in 0..<maxRetries {
            if Task.isCancelled || isPaused { return }

            do {
                // Create a sendable snapshot for the upload
                let assetSnapshot = MediaAsset(
                    localIdentifier: asset.localIdentifier,
                    syncStatus: asset.syncStatus,
                    fileSize: asset.fileSize,
                    mediaType: asset.mediaType,
                    createdDate: asset.createdDate
                )
                let result = try await uploadManager.uploadAsset(assetSnapshot, fileURL: fileURL)

                // Mark as synced
                if let dbAsset = fetchAsset(identifier: identifier, in: context) {
                    dbAsset.syncStatus = .synced
                    dbAsset.cloudBlobName = result.cloudBlobName
                    try context.save()
                }
                syncProgress.totalBytesSynced += result.bytesUploaded
                lastSyncedDate = .now
                refreshProgress()
                print("[Rawcut] Synced \(identifier)")

                // Schedule tag sync (backend auto-tags in background, takes a few seconds)
                let blobName = result.cloudBlobName
                let container = modelContainerRef
                Task {
                    await Self.syncTagsForAsset(
                        blobName: blobName,
                        localIdentifier: identifier,
                        modelContainer: container,
                        authManager: uploadManager.authManagerRef
                    )
                }
                return

            } catch {
                lastError = error
                let delay = backoffDelay(attempt: attempt)
                print("[Rawcut] Upload attempt \(attempt + 1)/\(maxRetries) failed for \(identifier): \(error.localizedDescription). Retrying in \(delay)s...")

                try? await Task.sleep(for: .seconds(delay))
            }
        }

        // All retries exhausted
        print("[Rawcut] Upload failed after \(maxRetries) retries for \(identifier): \(lastError?.localizedDescription ?? "unknown")")
        markFailed(identifier: identifier, in: context)
        sendUploadFailureNotification(assetId: identifier, error: lastError)
    }

    // MARK: - Helpers

    private func fetchNextPendingAsset() -> MediaAsset? {
        let context = ModelContext(modelContainer)

        // Priority 1: Photos first (smaller, faster to sync)
        let photoPredicate = #Predicate<MediaAsset> {
            $0.syncStatusRaw == "pending" && ($0.mediaTypeRaw == "photo" || $0.mediaTypeRaw == "livePhoto")
        }
        var photoDescriptor = FetchDescriptor<MediaAsset>(
            predicate: photoPredicate,
            sortBy: [SortDescriptor(\.createdDate, order: .reverse)]
        )
        photoDescriptor.fetchLimit = 1

        do {
            if let photo = try context.fetch(photoDescriptor).first {
                return photo
            }
        } catch {
            print("[Rawcut] Failed to fetch pending photos: \(error.localizedDescription)")
        }

        // Priority 2: Videos — only on Wi-Fi, or if user allows cellular
        let videoPredicate = #Predicate<MediaAsset> {
            $0.syncStatusRaw == "pending" && $0.mediaTypeRaw == "video"
        }
        var videoDescriptor = FetchDescriptor<MediaAsset>(
            predicate: videoPredicate,
            sortBy: [SortDescriptor(\.createdDate, order: .reverse)]
        )
        videoDescriptor.fetchLimit = 1

        do {
            guard let video = try context.fetch(videoDescriptor).first else { return nil }

            // Large videos (>100MB): prefer Wi-Fi + not low power mode
            let isLargeVideo = video.fileSize > 100_000_000
            if isLargeVideo && !networkMonitor.isWiFi {
                print("[Rawcut] Deferring large video upload (\(video.fileSize) bytes) until Wi-Fi")
                return nil
            }
            if isLargeVideo && ProcessInfo.processInfo.isLowPowerModeEnabled {
                print("[Rawcut] Deferring large video upload in Low Power Mode")
                return nil
            }

            return video
        } catch {
            print("[Rawcut] Failed to fetch pending videos: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchAsset(identifier: String, in context: ModelContext) -> MediaAsset? {
        let predicate = #Predicate<MediaAsset> { $0.localIdentifier == identifier }
        let descriptor = FetchDescriptor<MediaAsset>(predicate: predicate)
        return try? context.fetch(descriptor).first
    }

    private func markFailed(identifier: String, in context: ModelContext) {
        if let dbAsset = fetchAsset(identifier: identifier, in: context) {
            dbAsset.syncStatus = .failed
            do {
                try context.save()
            } catch {
                print("[Rawcut] Failed to save failed status for \(identifier): \(error.localizedDescription)")
            }
        }
        refreshProgress()
    }

    private func backoffDelay(attempt: Int) -> Double {
        // Exponential backoff: 2s, 4s, 8s
        pow(2.0, Double(attempt + 1))
    }

    func refreshProgress() {
        let context = ModelContext(modelContainer)

        do {
            let allDescriptor = FetchDescriptor<MediaAsset>()
            let all = try context.fetchCount(allDescriptor)

            let syncedPredicate = #Predicate<MediaAsset> { $0.syncStatusRaw == "synced" || $0.syncStatusRaw == "cloudOnly" }
            let synced = try context.fetchCount(FetchDescriptor<MediaAsset>(predicate: syncedPredicate))

            let uploadingPredicate = #Predicate<MediaAsset> { $0.syncStatusRaw == "uploading" }
            let uploading = try context.fetchCount(FetchDescriptor<MediaAsset>(predicate: uploadingPredicate))

            let pendingPredicate = #Predicate<MediaAsset> { $0.syncStatusRaw == "pending" }
            let pending = try context.fetchCount(FetchDescriptor<MediaAsset>(predicate: pendingPredicate))

            let failedPredicate = #Predicate<MediaAsset> { $0.syncStatusRaw == "failed" }
            let failed = try context.fetchCount(FetchDescriptor<MediaAsset>(predicate: failedPredicate))

            syncProgress = SyncProgress(
                totalItems: all,
                syncedCount: synced,
                uploadingCount: uploading,
                pendingCount: pending,
                failedCount: failed,
                totalBytesSynced: syncProgress.totalBytesSynced
            )
        } catch {
            print("[Rawcut] Failed to refresh sync progress: \(error.localizedDescription)")
        }
    }

    // MARK: - Tag Sync

    /// Fetch tags from backend after upload (auto-tagging runs asynchronously on server).
    /// Retries a few times with delay since tagging may not be instant.
    @MainActor
    static func syncTagsForAsset(
        blobName: String,
        localIdentifier: String,
        modelContainer: ModelContainer,
        authManager: AuthManager
    ) async {
        guard let token = authManager.authToken else { return }

        // Wait for backend auto-tagging to complete (typically 5-15s)
        for attempt in 0..<3 {
            try? await Task.sleep(for: .seconds(Double(attempt + 1) * 10))

            guard let response = await APIClient.getTagsByBlob(blobName: blobName, authToken: token) else {
                continue
            }

            // Only update if tags were actually generated
            guard response.tagged_at != nil, !response.tags.isEmpty else { continue }

            let context = ModelContext(modelContainer)
            let predicate = #Predicate<MediaAsset> { $0.localIdentifier == localIdentifier }
            do {
                if let asset = try context.fetch(FetchDescriptor<MediaAsset>(predicate: predicate)).first {
                    asset.tags = response.tags
                    try context.save()
                    print("[Rawcut] Tags synced for \(localIdentifier): \(response.tags)")
                }
            } catch {
                print("[Rawcut] Failed to save synced tags: \(error.localizedDescription)")
            }
            return
        }
        print("[Rawcut] Tag sync timed out for \(localIdentifier)")
    }

    // MARK: - Photo Export

    private func exportAssetToTempFile(localIdentifier: String) async -> URL? {
        let results = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        )
        guard let phAsset = results.firstObject else {
            print("[Rawcut] PHAsset not found for \(localIdentifier)")
            return nil
        }

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "\(localIdentifier.replacingOccurrences(of: "/", with: "_"))_export"

        if phAsset.mediaType == .video {
            return await exportVideo(phAsset: phAsset, to: tempDir.appendingPathComponent("\(fileName).mov"))
        } else {
            return await exportPhoto(phAsset: phAsset, to: tempDir.appendingPathComponent("\(fileName).jpg"))
        }
    }

    private func exportPhoto(phAsset: PHAsset, to destination: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            PHImageManager.default().requestImageDataAndOrientation(
                for: phAsset,
                options: options
            ) { data, _, _, _ in
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    try data.write(to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    print("[Rawcut] Failed to write photo to temp: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func exportVideo(phAsset: PHAsset, to destination: URL) async -> URL? {
        await Self._exportVideoOffMain(phAsset: phAsset, to: destination)
    }

    /// Runs off MainActor to avoid dispatch_assert_queue crash from
    /// PHImageManager callbacks that fire on background queues.
    nonisolated private static func _exportVideoOffMain(phAsset: PHAsset, to destination: URL) async -> URL? {
        await withUnsafeContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.version = .current

            let resumed = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
            resumed.initialize(to: false)

            PHImageManager.default().requestAVAsset(
                forVideo: phAsset,
                options: options
            ) { avAsset, _, info in
                guard !resumed.pointee else { return }

                if let isCancelled = info?[PHImageCancelledKey] as? Bool, isCancelled {
                    resumed.pointee = true
                    resumed.deallocate()
                    continuation.resume(returning: nil)
                    return
                }

                guard let urlAsset = avAsset as? AVURLAsset else {
                    if info?[PHImageResultIsDegradedKey] as? Bool != true {
                        resumed.pointee = true
                        resumed.deallocate()
                        continuation.resume(returning: nil)
                    }
                    return
                }

                resumed.pointee = true
                do {
                    try FileManager.default.copyItem(at: urlAsset.url, to: destination)
                    resumed.deallocate()
                    continuation.resume(returning: destination)
                } catch {
                    print("[Rawcut] Failed to copy video to temp: \(error.localizedDescription)")
                    resumed.deallocate()
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Notifications

    private func sendUploadFailureNotification(assetId: String, error: Error?) {
        let content = UNMutableNotificationContent()
        content.title = "업로드 실패"
        content.body = "일부 미디어를 클라우드에 올리지 못했습니다. 앱을 열어 다시 시도하세요."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "upload-failure-\(assetId.prefix(8))",
            content: content,
            trigger: nil // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[Rawcut] Failed to send upload failure notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Hashing

    private nonisolated func computeSHA256(fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { handle.closeFile() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1_048_576) // 1MB chunks
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Network Observation

    private func observeNetworkChanges() {
        NotificationCenter.default.addObserver(
            forName: .networkDidReconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPaused == false, !self.isSyncing else { return }
                guard self.isNetworkAllowedForSync else {
                    print("[Rawcut] Network reconnected but Wi-Fi required")
                    self.syncStatusMessage = "Waiting for Wi-Fi..."
                    return
                }
                print("[Rawcut] Network reconnected, resuming sync")
                self.startSync()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .networkDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isSyncing else { return }
                print("[Rawcut] Network lost, pausing sync")
                self.syncStatusMessage = "Waiting for network..."
            }
        }
    }
}
