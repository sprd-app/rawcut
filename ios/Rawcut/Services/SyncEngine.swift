import Foundation
import SwiftData
import BackgroundTasks
import Photos

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

    // MARK: - Dependencies

    private let uploadManager: UploadManager
    private let networkMonitor: NetworkMonitor
    private let modelContainer: ModelContainer

    // MARK: - Configuration

    private let maxRetries = 3
    private var currentTask: Task<Void, Never>?
    private var isPaused: Bool = false

    // MARK: - Init

    init(
        uploadManager: UploadManager,
        networkMonitor: NetworkMonitor,
        modelContainer: ModelContainer
    ) {
        self.uploadManager = uploadManager
        self.networkMonitor = networkMonitor
        self.modelContainer = modelContainer

        observeNetworkChanges()
    }

    // MARK: - Public API

    func startSync() {
        guard !isSyncing else { return }
        guard networkMonitor.isConnected else {
            syncStatusMessage = "Waiting for network..."
            return
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
        guard networkMonitor.isConnected else { return }
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
            isSyncing = false
            if syncProgress.isComplete {
                syncStatusMessage = "All synced"
            }
        }

        while !Task.isCancelled && !isPaused {
            refreshProgress()

            guard networkMonitor.isConnected else {
                syncStatusMessage = "Waiting for network..."
                print("[Rawcut] Network lost, pausing sync queue")
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
            try? context.save()
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

        // Attempt upload with retries
        var lastError: Error?
        for attempt in 0..<maxRetries {
            if Task.isCancelled || isPaused { return }

            do {
                let result = try await uploadManager.uploadAsset(asset, fileURL: fileURL)

                // Mark as synced
                if let dbAsset = fetchAsset(identifier: identifier, in: context) {
                    dbAsset.syncStatus = .synced
                    dbAsset.cloudBlobName = result.cloudBlobName
                    try context.save()
                }
                syncProgress.totalBytesSynced += result.bytesUploaded
                refreshProgress()
                print("[Rawcut] Synced \(identifier)")
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
    }

    // MARK: - Helpers

    private func fetchNextPendingAsset() -> MediaAsset? {
        let context = ModelContext(modelContainer)
        let predicate = #Predicate<MediaAsset> { $0.syncStatusRaw == "pending" }
        var descriptor = FetchDescriptor<MediaAsset>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.createdDate, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        do {
            return try context.fetch(descriptor).first
        } catch {
            print("[Rawcut] Failed to fetch pending assets: \(error.localizedDescription)")
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
            try? context.save()
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

            let syncedPredicate = #Predicate<MediaAsset> { $0.syncStatusRaw == "synced" }
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
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true

            PHImageManager.default().requestAVAsset(
                forVideo: phAsset,
                options: options
            ) { avAsset, _, _ in
                guard let urlAsset = avAsset as? AVURLAsset else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    try FileManager.default.copyItem(at: urlAsset.url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    print("[Rawcut] Failed to copy video to temp: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
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
