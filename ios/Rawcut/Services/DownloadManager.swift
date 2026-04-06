import Foundation
import Photos

// MARK: - Download Error

enum DownloadError: Error, LocalizedError {
    case notAuthenticated
    case invalidURL(String)
    case serverError(statusCode: Int)
    case photosSaveFailed(underlying: Error?)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            "Not authenticated. Please sign in."
        case .invalidURL(let url):
            "Invalid download URL: \(url)"
        case .serverError(let code):
            "Server error (\(code))"
        case .photosSaveFailed(let error):
            "Failed to save to Photos: \(error?.localizedDescription ?? "unknown")"
        }
    }
}

// MARK: - Download State

/// Per-asset download state, observable from thumbnails
struct DownloadState: Sendable {
    var progress: Double = 0
    var isDownloading: Bool = false
    var error: String?
}

// MARK: - Download Manager

/// Downloads cloud-only media assets back to the device's Photos library.
/// Tracks per-asset download progress for inline UI updates.
@MainActor
final class DownloadManager: NSObject, ObservableObject {

    @Published private(set) var isDownloading: Bool = false
    @Published private(set) var downloadProgress: Double = 0

    /// Per-asset download state, keyed by localIdentifier.
    /// AssetThumbnailView observes this for inline progress.
    @Published private(set) var activeDownloads: [String: DownloadState] = [:]

    /// Local identifiers of assets currently being restored from cloud.
    /// PhotoLibraryObserver checks this to avoid creating duplicates
    /// when the newly-saved PHAsset triggers a library change notification.
    private(set) var pendingRestoreIdentifiers: Set<String> = []

    private let authManager: AuthManager
    private lazy var downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Maps URLSessionTask identifiers to asset localIdentifiers
    private var taskToAssetId: [Int: String] = [:]

    /// Continuations waiting for download completion
    private var downloadContinuations: [Int: CheckedContinuation<URL, any Error>] = [:]

    init(authManager: AuthManager) {
        self.authManager = authManager
        super.init()
    }

    /// Check if a specific asset is currently downloading
    func isDownloading(assetId: String) -> Bool {
        activeDownloads[assetId]?.isDownloading == true
    }

    /// Get download progress for a specific asset (0.0 to 1.0)
    func progress(for assetId: String) -> Double {
        activeDownloads[assetId]?.progress ?? 0
    }

    /// Download a cloud asset and save it to the Photos library.
    /// Returns the new PHAsset local identifier on success.
    func downloadToPhotos(
        blobName: String,
        mediaType: MediaType,
        assetId: String
    ) async throws -> String? {
        guard let token = authManager.authToken else {
            throw DownloadError.notAuthenticated
        }

        // Mark download active
        activeDownloads[assetId] = DownloadState(progress: 0, isDownloading: true)
        isDownloading = true
        downloadProgress = 0

        defer {
            activeDownloads.removeValue(forKey: assetId)
            isDownloading = activeDownloads.values.contains { $0.isDownloading }
            downloadProgress = 0
        }

        // 1. Get signed download URL from backend
        let signedURL = try await APIClient.getMediaDownloadURL(
            blobName: blobName,
            authToken: token
        )

        guard let url = URL(string: signedURL) else {
            throw DownloadError.invalidURL(signedURL)
        }

        // 2. Download to temp file with progress tracking
        let tempURL = try await downloadFile(from: url, assetId: assetId)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // 3. Save to Photos library
        let localId = try await saveToPhotosLibrary(
            fileURL: tempURL,
            mediaType: mediaType
        )

        // Track the new localIdentifier so PhotoLibraryObserver
        // doesn't create a duplicate when it sees the new PHAsset.
        if let localId {
            pendingRestoreIdentifiers.insert(localId)
        }

        print("[Rawcut] Downloaded \(blobName) -> Photos: \(localId ?? "nil")")
        return localId
    }

    /// Call after the restored asset's MediaAsset record has been updated,
    /// so PhotoLibraryObserver can resume normal processing for this identifier.
    func clearPendingRestore(_ identifier: String) {
        pendingRestoreIdentifiers.remove(identifier)
    }

    // MARK: - Private

    private func downloadFile(from url: URL, assetId: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let task = downloadSession.downloadTask(with: url)
            let taskId = task.taskIdentifier
            taskToAssetId[taskId] = assetId
            downloadContinuations[taskId] = continuation
            task.resume()
        }
    }

    private func saveToPhotosLibrary(fileURL: URL, mediaType: MediaType) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            var placeholder: PHObjectPlaceholder?

            PHPhotoLibrary.shared().performChanges {
                let request: PHAssetChangeRequest?
                switch mediaType {
                case .video:
                    request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                case .photo, .livePhoto:
                    request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                }
                placeholder = request?.placeholderForCreatedAsset
            } completionHandler: { success, error in
                if success {
                    continuation.resume(returning: placeholder?.localIdentifier)
                } else {
                    continuation.resume(throwing: DownloadError.photosSaveFailed(underlying: error))
                }
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskId = downloadTask.taskIdentifier
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)

        Task { @MainActor [weak self] in
            guard let self, let assetId = self.taskToAssetId[taskId] else { return }
            self.activeDownloads[assetId]?.progress = progress
            self.downloadProgress = progress
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskId = downloadTask.taskIdentifier

        // Move file before continuation resumes (temp file is deleted after this callback)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(downloadTask.response?.url?.pathExtension ?? "dat")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloadContinuations[taskId]?.resume(returning: dest)
                self.downloadContinuations.removeValue(forKey: taskId)
                self.taskToAssetId.removeValue(forKey: taskId)
            }
        } catch {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloadContinuations[taskId]?.resume(throwing: error)
                self.downloadContinuations.removeValue(forKey: taskId)
                self.taskToAssetId.removeValue(forKey: taskId)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }
        let taskId = task.taskIdentifier
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let assetId = self.taskToAssetId[taskId] {
                self.activeDownloads[assetId]?.error = error.localizedDescription
                self.activeDownloads[assetId]?.isDownloading = false
            }
            self.downloadContinuations[taskId]?.resume(throwing: error)
            self.downloadContinuations.removeValue(forKey: taskId)
            self.taskToAssetId.removeValue(forKey: taskId)
        }
    }
}
