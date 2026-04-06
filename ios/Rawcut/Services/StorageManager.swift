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
    private func cacheThumbnail(for phAsset: PHAsset, identifier: String) -> String? {
        let safeId = identifier.replacingOccurrences(of: "/", with: "_")
        let fileName = "\(safeId).jpg"
        let destURL = Self.thumbnailCacheDir.appendingPathComponent(fileName)

        // Skip if already cached
        if FileManager.default.fileExists(atPath: destURL.path) {
            return fileName
        }

        // Synchronous thumbnail request (300x300 is small, fast)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = true
        options.isNetworkAccessAllowed = false

        var result: String?
        PHImageManager.default().requestImage(
            for: phAsset,
            targetSize: CGSize(width: 300, height: 300),
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            guard let image, let data = image.jpegData(compressionQuality: 0.7) else { return }
            do {
                try data.write(to: destURL)
                result = fileName
            } catch {
                print("[Rawcut] Failed to cache thumbnail for \(identifier): \(error.localizedDescription)")
            }
        }

        return result
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

    /// Check device storage and automatically free synced assets if needed.
    /// Called after uploads complete and on app launch.
    /// Frees oldest-first until device has enough headroom.
    func autoOptimizeIfNeeded() async {
        guard optimizeStorageEnabled else { return }

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

        // Always set cooldown to prevent rapid retries (e.g., user denies deletion or no synced assets left)
        lastAutoOptimizeDate = .now

        if freed > 0 {
            refreshDeviceFreeSpace()
            print("[Rawcut] Auto-optimize: freed \(freed) assets, device now has \(ByteCountFormatter.string(fromByteCount: deviceFreeSpace, countStyle: .file))")

            sendAutoOptimizeNotification(freedCount: freed)
        } else {
            print("[Rawcut] Auto-optimize: nothing to free (no synced assets or user denied)")
        }
    }

    /// Free synced assets oldest-first until at least `targetBytes` are freed.
    private func freeUpSpaceByBytes(_ targetBytes: Int64) async -> Int {
        let context = ModelContext(modelContainer)
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

                let results = PHAsset.fetchAssets(
                    withLocalIdentifiers: [asset.localIdentifier],
                    options: nil
                )
                if let phAsset = results.firstObject {
                    let thumbFile = cacheThumbnail(for: phAsset, identifier: asset.localIdentifier)
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
        content.title = "저장공간 최적화 완료"
        content.body = "\(freedCount)개 미디어의 로컬 사본을 정리했습니다. 클라우드에 안전하게 보관 중입니다."
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
                    let thumbFile = cacheThumbnail(for: phAsset, identifier: asset.localIdentifier)
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
