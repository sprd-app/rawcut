import Foundation
import SwiftData

enum MediaType: String, Codable, Sendable {
    case photo
    case video
    case livePhoto
}

@Model
final class MediaAsset {
    /// Photos framework local identifier
    @Attribute(.unique)
    var localIdentifier: String

    /// Cloud storage blob name (nil if not yet uploaded)
    var cloudBlobName: String?

    /// Current sync state
    var syncStatusRaw: String

    /// File size in bytes
    var fileSize: Int64

    /// Type of media
    var mediaTypeRaw: String

    /// Original creation date from EXIF / Photos metadata
    var createdDate: Date

    /// User-assigned or AI-generated tags
    var tags: [String]?

    /// Duration in seconds (0 for photos)
    var durationSeconds: Double

    /// SHA256 hash of the file content (for dedup)
    var contentHash: String?

    /// Cached thumbnail file name (relative to app's thumbnail cache dir)
    var cachedThumbnail: String?

    // MARK: - Computed accessors

    var syncStatus: SyncStatus {
        get { SyncStatus(rawValue: syncStatusRaw) ?? .pending }
        set { syncStatusRaw = newValue.rawValue }
    }

    var mediaType: MediaType {
        get { MediaType(rawValue: mediaTypeRaw) ?? .photo }
        set { mediaTypeRaw = newValue.rawValue }
    }

    init(
        localIdentifier: String,
        cloudBlobName: String? = nil,
        syncStatus: SyncStatus = .pending,
        fileSize: Int64,
        mediaType: MediaType,
        createdDate: Date = .now,
        tags: [String]? = nil,
        durationSeconds: Double = 0,
        contentHash: String? = nil,
        cachedThumbnail: String? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.cloudBlobName = cloudBlobName
        self.syncStatusRaw = syncStatus.rawValue
        self.fileSize = fileSize
        self.mediaTypeRaw = mediaType.rawValue
        self.createdDate = createdDate
        self.tags = tags
        self.durationSeconds = durationSeconds
        self.contentHash = contentHash
        self.cachedThumbnail = cachedThumbnail
    }
}
