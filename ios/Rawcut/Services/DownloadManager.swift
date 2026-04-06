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

// MARK: - Download Manager

/// Downloads cloud-only media assets back to the device's Photos library.
@MainActor
final class DownloadManager: ObservableObject {

    @Published private(set) var isDownloading: Bool = false
    @Published private(set) var downloadProgress: Double = 0

    private let authManager: AuthManager

    init(authManager: AuthManager) {
        self.authManager = authManager
    }

    /// Download a cloud asset and save it to the Photos library.
    /// Returns the new PHAsset local identifier on success.
    func downloadToPhotos(blobName: String, mediaType: MediaType) async throws -> String? {
        guard let token = authManager.authToken else {
            throw DownloadError.notAuthenticated
        }

        isDownloading = true
        downloadProgress = 0
        defer {
            isDownloading = false
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

        // 2. Download to temp file
        let tempURL = try await downloadFile(from: url)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // 3. Save to Photos library
        let localId = try await saveToPhotosLibrary(
            fileURL: tempURL,
            mediaType: mediaType
        )

        print("[Rawcut] Downloaded \(blobName) -> Photos: \(localId ?? "nil")")
        return localId
    }

    // MARK: - Private

    private func downloadFile(from url: URL) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw DownloadError.serverError(statusCode: code)
        }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "dat" : url.pathExtension)
        try FileManager.default.moveItem(at: tempURL, to: dest)

        downloadProgress = 1.0
        return dest
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
