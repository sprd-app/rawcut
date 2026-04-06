import Foundation

enum SyncStatus: String, Codable, Sendable {
    case pending
    case uploading
    case synced
    case failed
    /// Uploaded to cloud, local copy deleted from Photos library
    case cloudOnly
}
