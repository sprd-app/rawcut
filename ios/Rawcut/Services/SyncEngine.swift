import Foundation
import SwiftData
import BackgroundTasks
import Photos
import CryptoKit
import UserNotifications
import UIKit

// MARK: - Sync Progress

struct SyncProgress: Sendable {
    var totalItems: Int = 0
    var syncedCount: Int = 0
    var uploadingCount: Int = 0
    var pendingCount: Int = 0
    var failedCount: Int = 0
    var totalBytesSynced: Int64 = 0
    var pendingBytes: Int64 = 0

    /// Currently uploading file info
    var currentUploadName: String?
    var currentUploadBytes: Int64 = 0
    var currentUploadTotalBytes: Int64 = 0
    var currentUploadMediaType: String?

    /// Upload speed tracking for ETA
    var recentBytesPerSecond: Double = 0
    var syncStartedAt: Date?

    var fraction: Double {
        guard totalItems > 0 else { return 0 }
        return Double(syncedCount) / Double(totalItems)
    }

    var currentUploadFraction: Double {
        guard currentUploadTotalBytes > 0 else { return 0 }
        return Double(currentUploadBytes) / Double(currentUploadTotalBytes)
    }

    var isComplete: Bool {
        pendingCount == 0 && uploadingCount == 0
    }

    /// Estimated time remaining for pending uploads, or nil if unknown.
    var estimatedTimeRemaining: TimeInterval? {
        guard pendingBytes > 0, recentBytesPerSecond > 0 else { return nil }
        return Double(pendingBytes) / recentBytesPerSecond
    }

    /// Human-readable ETA string
    var etaText: String? {
        guard let seconds = estimatedTimeRemaining else { return nil }
        if seconds < 60 { return "< 1 min" }
        if seconds < 3600 {
            let mins = Int(seconds / 60)
            return "~\(mins) min"
        }
        let hours = Int(seconds / 3600)
        let mins = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        if hours >= 24 {
            let days = hours / 24
            return "~\(days)d \(hours % 24)h"
        }
        return "~\(hours)h \(mins)m"
    }

    /// Formatted size of current upload (e.g., "12.3 MB / 45.6 MB")
    var currentUploadProgressText: String? {
        guard currentUploadTotalBytes > 0 else { return nil }
        let sent = ByteCountFormatter.string(fromByteCount: currentUploadBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: currentUploadTotalBytes, countStyle: .file)
        return "\(sent) / \(total)"
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
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

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

        // Observe per-file upload progress for UI
        uploadManager.onProgressUpdate = { [weak self] _, bytesSent, totalBytes in
            Task { @MainActor [weak self] in
                self?.syncProgress.currentUploadBytes = bytesSent
                self?.syncProgress.currentUploadTotalBytes = totalBytes
            }
        }
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
        if syncProgress.syncStartedAt == nil {
            syncProgress.syncStartedAt = .now
        }

        // Request background execution time so uploads continue when app goes to background
        beginBackgroundTask()

        currentTask = Task {
            await processSyncQueue()
            endBackgroundTask()
        }
    }

    func pauseSync() {
        isPaused = true
        isSyncing = false
        currentTask?.cancel()
        currentTask = nil
        syncStatusMessage = "Paused"
        endBackgroundTask()
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
        guard !isSyncing else { return }
        guard isNetworkAllowedForSync else { return }
        isPaused = false
        isSyncing = true
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

        // Track current upload info
        syncProgress.currentUploadName = identifier
        syncProgress.currentUploadBytes = 0
        syncProgress.currentUploadTotalBytes = asset.fileSize
        syncProgress.currentUploadMediaType = asset.mediaTypeRaw
        syncStatusMessage = "Uploading \(asset.mediaType == .video ? "video" : "photo")..."

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

        // Use chunked upload for large files (>50MB), regular upload otherwise
        let useChunkedUpload = asset.fileSize > 50_000_000

        // Attempt upload with retries
        var lastError: Error?
        for attempt in 0..<maxRetries {
            if Task.isCancelled || isPaused { return }

            do {
                let result: UploadResult
                if useChunkedUpload {
                    result = try await chunkedUpload(
                        fileURL: fileURL,
                        asset: asset,
                        contentHash: hash
                    )
                } else {
                    // Create a sendable snapshot for the upload
                    let assetSnapshot = MediaAsset(
                        localIdentifier: asset.localIdentifier,
                        syncStatus: asset.syncStatus,
                        fileSize: asset.fileSize,
                        mediaType: asset.mediaType,
                        createdDate: asset.createdDate
                    )
                    result = try await uploadManager.uploadAsset(assetSnapshot, fileURL: fileURL)
                }

                // Mark as synced
                if let dbAsset = fetchAsset(identifier: identifier, in: context) {
                    dbAsset.syncStatus = .synced
                    dbAsset.cloudBlobName = result.cloudBlobName
                    try context.save()
                }
                syncProgress.totalBytesSynced += result.bytesUploaded
                syncProgress.currentUploadName = nil
                syncProgress.currentUploadBytes = 0
                syncProgress.currentUploadTotalBytes = 0
                lastSyncedDate = .now

                // Update upload speed estimate (rolling average)
                if let started = syncProgress.syncStartedAt {
                    let elapsed = Date.now.timeIntervalSince(started)
                    if elapsed > 0 {
                        syncProgress.recentBytesPerSecond = Double(syncProgress.totalBytesSynced) / elapsed
                    }
                }
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
                let size = ByteCountFormatter.string(fromByteCount: video.fileSize, countStyle: .file)
                syncStatusMessage = "Waiting for Wi-Fi (large file \(size))"
                print("[Rawcut] Deferring large video upload (\(video.fileSize) bytes) until Wi-Fi")
                return nil
            }
            if isLargeVideo && ProcessInfo.processInfo.isLowPowerModeEnabled {
                syncStatusMessage = "Low Power Mode — large upload deferred"
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

            // Estimate pending bytes for ETA — only recalculate when count changes
            // to avoid fetching all pending assets on every refresh.
            var pBytes = syncProgress.pendingBytes
            if pending != syncProgress.pendingCount || pBytes == 0 {
                let pendingBytesPredicate = #Predicate<MediaAsset> { $0.syncStatusRaw == "pending" }
                let pendingAssets = try context.fetch(FetchDescriptor<MediaAsset>(predicate: pendingBytesPredicate))
                pBytes = pendingAssets.reduce(Int64(0)) { $0 + $1.fileSize }
            }

            syncProgress = SyncProgress(
                totalItems: all,
                syncedCount: synced,
                uploadingCount: uploading,
                pendingCount: pending,
                failedCount: failed,
                totalBytesSynced: syncProgress.totalBytesSynced,
                pendingBytes: pBytes,
                recentBytesPerSecond: syncProgress.recentBytesPerSecond,
                syncStartedAt: syncProgress.syncStartedAt
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

    // MARK: - Chunked Upload (for large files)

    private func chunkedUpload(
        fileURL: URL,
        asset: MediaAsset,
        contentHash: String?
    ) async throws -> UploadResult {
        let token = await MainActor.run { uploadManager.authManagerRef.authToken }
        guard let token else { throw UploadError.noAuthToken }

        let fileSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int ?? 0
        let contentType = asset.mediaType == .video ? "video/mp4" : "image/jpeg"
        let filename = fileURL.lastPathComponent

        // 1. Init chunked upload
        let initResponse = try await APIClient.initChunkedUpload(
            filename: filename,
            fileSize: fileSize,
            mediaType: asset.mediaTypeRaw,
            contentType: contentType,
            contentHash: contentHash,
            authToken: token
        )

        // Dedup: server found existing blob
        if initResponse.total_chunks == 0 {
            print("[Rawcut] Chunked dedup: \(asset.localIdentifier) → \(initResponse.blob_name)")
            return UploadResult(
                cloudBlobName: initResponse.blob_name,
                bytesUploaded: Int64(fileSize)
            )
        }

        // 2. Upload chunks
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { handle.closeFile() }

        let chunkSize = initResponse.chunk_size
        var totalSent: Int64 = 0

        for chunkIndex in 0..<initResponse.total_chunks {
            if Task.isCancelled || isPaused { throw CancellationError() }

            let offset = UInt64(chunkIndex * chunkSize)
            handle.seek(toFileOffset: offset)
            let chunkData = handle.readData(ofLength: chunkSize)
            guard !chunkData.isEmpty else { break }

            try await APIClient.uploadChunk(
                uploadId: initResponse.upload_id,
                chunkIndex: chunkIndex,
                data: chunkData,
                authToken: token
            )

            totalSent += Int64(chunkData.count)
            syncProgress.currentUploadBytes = totalSent
            syncProgress.currentUploadTotalBytes = Int64(fileSize)

            let pct = Int(Double(totalSent) / Double(fileSize) * 100)
            if pct % 10 == 0 {
                print("[Rawcut] Chunked upload \(asset.localIdentifier): \(pct)%")
            }
        }

        // 3. Commit
        let commitResponse = try await APIClient.commitChunkedUpload(
            uploadId: initResponse.upload_id,
            authToken: token
        )

        print("[Rawcut] Chunked upload complete: \(asset.localIdentifier) → \(commitResponse.blob_name)")
        return UploadResult(
            cloudBlobName: commitResponse.blob_name,
            bytesUploaded: Int64(commitResponse.size)
        )
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
        content.title = "Upload Failed"
        content.body = "Some media couldn't be uploaded to the cloud. Open the app to retry."
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

    // MARK: - Background Task Management

    /// Request extended background execution time from iOS.
    /// This gives ~30s (up to ~3min) for the current upload to finish.
    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "rawcut.sync") { [weak self] in
            // iOS is about to kill our background time — schedule a BGTask to continue later
            self?.endBackgroundTask()
            self?.scheduleBackgroundProcessing()
            print("[Rawcut] Background time expiring, scheduled BGTask for remaining uploads")
        }
        print("[Rawcut] Began background task for sync")
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    /// Called when app transitions to/from foreground.
    /// Resumes sync when returning to foreground if there are pending items.
    func handleScenePhaseChange(isActive: Bool) {
        if isActive {
            // Returning to foreground — resume sync if needed
            refreshProgress()
            if syncProgress.pendingCount > 0 && !isSyncing && !isPaused {
                print("[Rawcut] App became active, resuming sync (\(syncProgress.pendingCount) pending)")
                startSync()
            }
        } else {
            // Going to background — batch enqueue pending uploads to background URLSession
            // so iOS can continue uploading even after app suspension
            if syncProgress.pendingCount > 0 {
                beginBackgroundTask()
                Task {
                    await enqueueBackgroundBatch()
                    scheduleBackgroundProcessing()
                    endBackgroundTask()
                }
            }
        }
    }

    // MARK: - Batch Background Enqueue

    /// Pre-export and enqueue up to N pending assets to the background URLSession.
    /// iOS will upload them even after the app is suspended/terminated.
    private let backgroundBatchSize = 10

    private func enqueueBackgroundBatch() async {
        let context = ModelContext(modelContainer)

        // Fetch pending photos first (smaller), then videos
        let pendingPredicate = #Predicate<MediaAsset> {
            $0.syncStatusRaw == "pending"
        }
        var descriptor = FetchDescriptor<MediaAsset>(
            predicate: pendingPredicate,
            sortBy: [SortDescriptor(\.fileSize, order: .forward)] // smallest first for background
        )
        descriptor.fetchLimit = backgroundBatchSize

        guard let pendingAssets = try? context.fetch(descriptor), !pendingAssets.isEmpty else {
            print("[Rawcut] No pending assets for background batch")
            return
        }

        var enqueued = 0
        for asset in pendingAssets {
            guard isNetworkAllowedForSync else { break }

            // Skip large videos in background (>100MB) — too risky for background time
            if asset.fileSize > 100_000_000 { continue }

            // Export to temp file
            guard let fileURL = await exportAssetToTempFile(localIdentifier: asset.localIdentifier) else {
                continue
            }

            // Compute hash
            let hash = computeSHA256(fileURL: fileURL)
            if let hash {
                asset.contentHash = hash
            }

            // Mark as uploading
            asset.syncStatus = .uploading
            try? context.save()

            // Create a sendable snapshot
            let snapshot = MediaAsset(
                localIdentifier: asset.localIdentifier,
                syncStatus: .uploading,
                fileSize: asset.fileSize,
                mediaType: asset.mediaType,
                createdDate: asset.createdDate,
                contentHash: hash
            )

            // Enqueue on background URLSession — iOS will handle even after app death
            do {
                _ = try await uploadManager.uploadAsset(snapshot, fileURL: fileURL)

                // Mark synced (if we're still alive to see the result)
                if let dbAsset = fetchAsset(identifier: asset.localIdentifier, in: context) {
                    dbAsset.syncStatus = .synced
                    try? context.save()
                }
                enqueued += 1
            } catch {
                // Revert to pending so foreground can retry
                if let dbAsset = fetchAsset(identifier: asset.localIdentifier, in: context) {
                    dbAsset.syncStatus = .pending
                    try? context.save()
                }
            }

            // Clean up temp file
            try? FileManager.default.removeItem(at: fileURL)
        }

        refreshProgress()
        print("[Rawcut] Background batch: enqueued \(enqueued)/\(pendingAssets.count) uploads")
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
