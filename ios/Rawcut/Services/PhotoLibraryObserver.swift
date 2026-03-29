import Foundation
import Photos
import SwiftData

// MARK: - Authorization Status

enum PhotoAuthorizationStatus: Sendable {
    case notDetermined
    case authorized
    case limited
    case denied
    case restricted
}

// MARK: - Photo Library Observer

@MainActor
final class PhotoLibraryObserver: NSObject, ObservableObject {

    @Published private(set) var authorizationStatus: PhotoAuthorizationStatus = .notDetermined
    @Published private(set) var isObserving: Bool = false

    private let modelContainer: ModelContainer
    private weak var syncEngine: SyncEngine?

    // Track the last fetch result for diffing
    private var lastFetchResult: PHFetchResult<PHAsset>?

    init(modelContainer: ModelContainer, syncEngine: SyncEngine? = nil) {
        self.modelContainer = modelContainer
        self.syncEngine = syncEngine
        super.init()
        updateAuthorizationStatus()
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        updateAuthorizationStatus(from: status)

        if status == .authorized || status == .limited {
            performInitialImport()
            startObserving()
        } else {
            print("[Rawcut] Photo library access denied: \(status.rawValue)")
        }
    }

    private func updateAuthorizationStatus(from phStatus: PHAuthorizationStatus? = nil) {
        let status = phStatus ?? PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .notDetermined:
            authorizationStatus = .notDetermined
        case .authorized:
            authorizationStatus = .authorized
        case .limited:
            authorizationStatus = .limited
        case .denied:
            authorizationStatus = .denied
        case .restricted:
            authorizationStatus = .restricted
        @unknown default:
            authorizationStatus = .denied
        }
    }

    // MARK: - Observation

    func startObserving() {
        guard !isObserving else { return }
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            print("[Rawcut] Cannot observe photo library without authorization")
            return
        }

        PHPhotoLibrary.shared().register(self)
        isObserving = true
        print("[Rawcut] Photo library observer registered")
    }

    func stopObserving() {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        isObserving = false
        print("[Rawcut] Photo library observer unregistered")
    }

    // MARK: - Initial Import

    func performInitialImport() {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.predicate = assetFilterPredicate()

        let result = PHAsset.fetchAssets(with: fetchOptions)
        lastFetchResult = result

        let context = ModelContext(modelContainer)
        var newCount = 0

        result.enumerateObjects { [weak self] phAsset, _, _ in
            guard let self else { return }
            if self.insertIfNew(phAsset: phAsset, context: context) {
                newCount += 1
            }
        }

        do {
            try context.save()
            print("[Rawcut] Initial import: \(newCount) new assets added")
            syncEngine?.refreshProgress()
            if newCount > 0 {
                syncEngine?.startSync()
            }
        } catch {
            print("[Rawcut] Failed to save initial import: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// Filter: photos and videos only. Excludes screenshots and live photo video components.
    private func assetFilterPredicate() -> NSPredicate {
        // Include photos (not screenshots) and videos
        // PHAsset.mediaSubtype.screenshot rawValue = 512
        NSPredicate(
            format: "(mediaType == %d AND NOT (mediaSubtypes & %d != 0)) OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaSubtype.photoScreenshot.rawValue,
            PHAssetMediaType.video.rawValue
        )
    }

    private func mediaType(for phAsset: PHAsset) -> MediaType {
        switch phAsset.mediaType {
        case .video:
            return .video
        case .image:
            if phAsset.mediaSubtypes.contains(.photoLive) {
                return .livePhoto
            }
            return .photo
        default:
            return .photo
        }
    }

    /// Insert a PHAsset into SwiftData if it doesn't already exist. Returns true if inserted.
    @discardableResult
    private func insertIfNew(phAsset: PHAsset, context: ModelContext) -> Bool {
        let identifier = phAsset.localIdentifier
        let predicate = #Predicate<MediaAsset> { $0.localIdentifier == identifier }
        let descriptor = FetchDescriptor<MediaAsset>(predicate: predicate)

        do {
            let existing = try context.fetchCount(descriptor)
            guard existing == 0 else { return false }
        } catch {
            print("[Rawcut] Error checking existing asset: \(error.localizedDescription)")
            return false
        }

        // Estimate file size from PHAsset resource
        let resources = PHAssetResource.assetResources(for: phAsset)
        let primaryResource = resources.first
        let fileSize = primaryResource.flatMap { resource in
            resource.value(forKey: "fileSize") as? Int64
        } ?? 0

        let asset = MediaAsset(
            localIdentifier: phAsset.localIdentifier,
            syncStatus: .pending,
            fileSize: fileSize,
            mediaType: mediaType(for: phAsset),
            createdDate: phAsset.creationDate ?? .now
        )
        context.insert(asset)
        return true
    }
}

// MARK: - PHPhotoLibraryChangeObserver

extension PhotoLibraryObserver: PHPhotoLibraryChangeObserver {

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            handlePhotoLibraryChange(changeInstance)
        }
    }

    private func handlePhotoLibraryChange(_ changeInstance: PHChange) {
        guard let lastResult = lastFetchResult else {
            // No previous fetch result; do a full re-import
            performInitialImport()
            return
        }

        guard let changes = changeInstance.changeDetails(for: lastResult) else {
            return
        }

        lastFetchResult = changes.fetchResultAfterChanges

        guard changes.hasIncrementalChanges else {
            // Major change; re-import
            performInitialImport()
            return
        }

        let context = ModelContext(modelContainer)
        var newCount = 0

        // Process inserted assets
        if let insertedObjects = changes.insertedObjects as? [PHAsset], !insertedObjects.isEmpty {
            for phAsset in insertedObjects {
                // Filter: skip screenshots and non-photo/video
                if phAsset.mediaType == .image && phAsset.mediaSubtypes.contains(.photoScreenshot) {
                    continue
                }
                guard phAsset.mediaType == .image || phAsset.mediaType == .video else {
                    continue
                }

                if insertIfNew(phAsset: phAsset, context: context) {
                    newCount += 1
                }
            }
        }

        // Process removed assets
        if let removedObjects = changes.removedObjects as? [PHAsset], !removedObjects.isEmpty {
            for phAsset in removedObjects {
                let identifier = phAsset.localIdentifier
                let predicate = #Predicate<MediaAsset> { $0.localIdentifier == identifier }
                let descriptor = FetchDescriptor<MediaAsset>(predicate: predicate)

                if let existing = try? context.fetch(descriptor).first {
                    context.delete(existing)
                }
            }
        }

        do {
            try context.save()
            if newCount > 0 {
                print("[Rawcut] Photo library change: \(newCount) new assets")
                syncEngine?.refreshProgress()
                syncEngine?.startSync()
            }
        } catch {
            print("[Rawcut] Failed to process photo library changes: \(error.localizedDescription)")
        }
    }
}
