import Foundation
import SwiftData
import Photos
import UIKit
import UserNotifications

/// Manages device storage optimization — freeing local copies of cloud-synced assets.
/// Handles thumbnail caching so cloud-only assets remain visually browsable.
/// When "Optimize Storage" is enabled, automatically frees space when device storage is low.
@MainActor
final class StorageManager: ObservableObject {

    // MARK: - Types

    struct SpaceRecoveryEstimate: Sendable {
        var assetCount: Int = 0
        var totalBytes: Int64 = 0

        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        }
    }

    // MARK: - Published State

    @Published private(set) var lastFreedCount: Int?
    @Published private(set) var deviceFreeSpace: Int64 = 0
    @Published private(set) var lastAutoOptimizeDate: Date?

    /// When non-nil, shows a banner recommending the user free space.
    @Published var optimizationRecommendation: OptimizationRecommendation?

    struct OptimizationRecommendation: Equatable {
        var assetCount: Int
        var totalBytes: Int64
        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        }
    }

    // MARK: - Configuration

    /// Threshold below which auto-optimization kicks in (default 5 GB)
    private let autoOptimizeThreshold: Int64 = 5_000_000_000

    /// Minimum interval between auto-optimize runs (10 minutes)
    private let autoOptimizeCooldown: TimeInterval = 600

    /// Reads user preference for automatic storage optimization.
    var optimizeStorageEnabled: Bool {
        if UserDefaults.standard.object(forKey: "optimizeStorage") == nil {
            return true // default on, like iCloud
        }
        return UserDefaults.standard.bool(forKey: "optimizeStorage")
    }

    // MARK: - Dependencies

    private let modelContainer: ModelContainer

    /// Directory for cached thumbnails of cloud-only assets
    static let thumbnailCacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Thumbnail Cache

    /// Get the cached thumbnail URL for an asset, if it exists.
    static func cachedThumbnailURL(for fileName: String?) -> URL? {
        guard let fileName else { return nil }
        let url = thumbnailCacheDir.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Load a cached thumbnail image from disk.
    static func loadCachedThumbnail(fileName: String?) -> UIImage? {
        guard let url = cachedThumbnailURL(for: fileName) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// Cache a thumbnail for an asset before its local copy is deleted.
    /// Returns the file name (not full path) of the cached thumbnail.
    /// Runs the PHImageManager request off the main thread to avoid UI blocking.
    private func cacheThumbnail(for phAsset: PHAsset, identifier: String) async -> String? {
        let safeId = identifier.replacingOccurrences(of: "/", with: "_")
        let fileName = "\(safeId).jpg"
        let destURL = Self.thumbnailCacheDir.appendingPathComponent(fileName)

        // Skip if already cached
        if FileManager.default.fileExists(atPath: destURL.path) {
            return fileName
        }

        // Async thumbnail request — yields main thread between requests
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = false
            options.isNetworkAccessAllowed = false

            PHImageManager.default().requestImage(
                for: phAsset,
                targetSize: CGSize(width: 600, height: 600),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                // PHImageManager may call back multiple times (degraded then full).
                // Only process the final delivery.
                let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                guard !isDegraded else { return }

                guard let image, let data = image.jpegData(compressionQuality: 0.7) else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    try data.write(to: destURL)
                    continuation.resume(returning: fileName)
                } catch {
                    print("[Rawcut] Failed to cache thumbnail for \(identifier): \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Space Estimation

    func estimateRecoverableSpace() -> SpaceRecoveryEstimate {
        let context = ModelContext(modelContainer)
        let predicate = #Predicate<MediaAsset> { $0.syncStatusRaw == "synced" }
        let descriptor = FetchDescriptor<MediaAsset>(predicate: predicate)

        do {
            let synced = try context.fetch(descriptor)
            var estimate = SpaceRecoveryEstimate()
            for asset in synced {
                let results = PHAsset.fetchAssets(
                    withLocalIdentifiers: [asset.localIdentifier],
                    options: nil
                )
                if results.count > 0 {
                    estimate.assetCount += 1
                    estimate.totalBytes += asset.fileSize
                }
            }
            return estimate
        } catch {
            print("[Rawcut] Failed to estimate recoverable space: \(error.localizedDescription)")
            return SpaceRecoveryEstimate()
        }
    }

    // MARK: - Device Storage Monitoring

    /// Query available device storage using the system-recommended key.
    func refreshDeviceFreeSpace() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage {
            deviceFreeSpace = available
        }
    }

    /// True when device free space is below the auto-optimize threshold.
    var isStorageLow: Bool {
        deviceFreeSpace > 0 && deviceFreeSpace < autoOptimizeThreshold
    }

    // MARK: - Auto Optimization

    /// Check if storage optimization should be recommended to the user.
    /// Instead of auto-deleting with a jarring system popup, we show a banner
    /// that the user can tap to trigger the optimization themselves.
    func checkOptimizationRecommendation() {
        guard optimizeStorageEnabled else { return }

        refreshDeviceFreeSpace()
        guard isStorageLow else {
            optimizationRecommendation = nil
            return
        }

        let estimate = estimateRecoverableSpace()
        guard estimate.assetCount > 0 else {
            optimizationRecommendation = nil
            return
        }

        optimizationRecommendation = OptimizationRecommendation(
            assetCount: estimate.assetCount,
            totalBytes: estimate.totalBytes
        )
        print("[Rawcut] Storage low (\(ByteCountFormatter.string(fromByteCount: deviceFreeSpace, countStyle: .file)) free), recommending optimization: \(estimate.assetCount) assets, \(estimate.formattedSize)")
    }

    /// Execute the recommended optimization. Called when user taps the banner.
    func executeOptimization() async -> Int {
        let freed = await freeUpSpace()
        lastAutoOptimizeDate = .now
        optimizationRecommendation = nil
        refreshDeviceFreeSpace()
        if freed > 0 {
            sendAutoOptimizeNotification(freedCount: freed)
        }
        return freed
    }

    /// Legacy auto-optimize for background sync completion.
    /// Only runs when app is NOT active to avoid surprising the user.
    func autoOptimizeIfNeeded(force: Bool = false) async {
        guard optimizeStorageEnabled else { return }

        // Never auto-delete when user is actively using the app
        let appState = UIApplication.shared.applicationState
        if appState == .active {
            // Instead, set up a recommendation banner
            checkOptimizationRecommendation()
            return
        }

        // Cooldown: don't run too frequently
        if let last = lastAutoOptimizeDate,
           Date.now.timeIntervalSince(last) < autoOptimizeCooldown {
            return
        }

        refreshDeviceFreeSpace()
        guard isStorageLow else { return }

        print("[Rawcut] Auto-optimize: device free space \(ByteCountFormatter.string(fromByteCount: deviceFreeSpace, countStyle: .file)), below threshold")

        let targetFreeSpace = autoOptimizeThreshold * 2 // aim for 10 GB headroom
        let bytesToFree = targetFreeSpace - deviceFreeSpace
        let freed = await freeUpSpaceByBytes(bytesToFree)

        lastAutoOptimizeDate = .now

        if freed > 0 {
            refreshDeviceFreeSpace()
            print("[Rawcut] Auto-optimize: freed \(freed) assets, device now has \(ByteCountFormatter.string(fromByteCount: deviceFreeSpace, countStyle: .file))")
            sendAutoOptimizeNotification(freedCount: freed)
        }
    }

    /// Free synced assets oldest-first until at least `targetBytes` are freed.
    /// Always preserves assets from the last `protectRecentDays` days.
    private func freeUpSpaceByBytes(_ targetBytes: Int64) async -> Int {
        let context = ModelContext(modelContainer)

        // Protect recent media — never auto-delete assets less than 7 days old
        let protectRecentDays = 7
        let cutoff = Calendar.current.date(byAdding: .day, value: -protectRecentDays, to: .now) ?? .now

        let predicate = #Predicate<MediaAsset> { $0.syncStatusRaw == "synced" }
        let descriptor = FetchDescriptor<MediaAsset>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.createdDate, order: .forward)] // oldest first
        )

        do {
            let syncedAssets = try context.fetch(descriptor)
            guard !syncedAssets.isEmpty else { return 0 }

            var phAssetsToDelete: [PHAsset] = []
            var eligibleAssets: [MediaAsset] = []
            var accumulatedBytes: Int64 = 0

            for asset in syncedAssets {
                guard asset.cloudBlobName != nil else { continue }
                // Never auto-delete recent assets
                guard asset.createdDate < cutoff else { continue }

                let results = PHAsset.fetchAssets(
                    withLocalIdentifiers: [asset.localIdentifier],
                    options: nil
                )
                if let phAsset = results.firstObject {
                    let thumbFile = await cacheThumbnail(for: phAsset, identifier: asset.localIdentifier)
                    asset.cachedThumbnail = thumbFile

                    phAssetsToDelete.append(phAsset)
                    eligibleAssets.append(asset)
                    accumulatedBytes += asset.fileSize

                    if accumulatedBytes >= targetBytes { break }
                }
            }

            guard !phAssetsToDelete.isEmpty else { return 0 }

            try context.save()

            let deleted = await requestPhotosDeletion(phAssetsToDelete)

            if deleted {
                for asset in eligibleAssets {
                    asset.syncStatus = .cloudOnly
                }
                try context.save()
                let count = eligibleAssets.count
                lastFreedCount = count
                return count
            }
        } catch {
            print("[Rawcut] Auto-optimize failed: \(error.localizedDescription)")
        }

        return 0
    }

    private func sendAutoOptimizeNotification(freedCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Storage Optimized"
        content.body = "Cleaned up local copies of \(freedCount) media items. They're safely stored in the cloud."
        content.sound = nil // silent

        let request = UNNotificationRequest(
            identifier: "auto-optimize-\(Int(Date.now.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Free Up Space (Manual)

    func freeUpSpace(olderThan days: Int = 0) async -> Int {
        let context = ModelContext(modelContainer)
        let predicate = #Predicate<MediaAsset> { $0.syncStatusRaw == "synced" }
        let descriptor = FetchDescriptor<MediaAsset>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.createdDate, order: .forward)]
        )

        do {
            let syncedAssets = try context.fetch(descriptor)
            guard !syncedAssets.isEmpty else { return 0 }

            let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .now
            let eligible = syncedAssets.filter { asset in
                guard asset.cloudBlobName != nil else { return false }
                return days == 0 || asset.createdDate < cutoffDate
            }
            guard !eligible.isEmpty else { return 0 }

            // Collect PHAssets and cache thumbnails BEFORE deletion
            var phAssetsToDelete: [PHAsset] = []
            var eligibleAssets: [MediaAsset] = []

            for asset in eligible {
                let results = PHAsset.fetchAssets(
                    withLocalIdentifiers: [asset.localIdentifier],
                    options: nil
                )
                if let phAsset = results.firstObject {
                    // Cache thumbnail before we lose the local copy
                    let thumbFile = await cacheThumbnail(for: phAsset, identifier: asset.localIdentifier)
                    asset.cachedThumbnail = thumbFile

                    phAssetsToDelete.append(phAsset)
                    eligibleAssets.append(asset)
                }
            }

            guard !phAssetsToDelete.isEmpty else { return 0 }

            // Save thumbnail paths before deletion
            try context.save()

            let deleted = await requestPhotosDeletion(phAssetsToDelete)

            if deleted {
                for asset in eligibleAssets {
                    asset.syncStatus = .cloudOnly
                }
                try context.save()
                let count = eligibleAssets.count
                lastFreedCount = count
                print("[Rawcut] Freed \(count) assets, thumbnails cached")
                return count
            }
        } catch {
            print("[Rawcut] Free up space failed: \(error.localizedDescription)")
        }

        return 0
    }

    // MARK: - Private

    private func requestPhotosDeletion(_ assets: [PHAsset]) async -> Bool {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSFastEnumeration)
            } completionHandler: { success, error in
                if let error {
                    print("[Rawcut] Photos deletion error: \(error.localizedDescription)")
                }
                continuation.resume(returning: success)
            }
        }
    }
}
