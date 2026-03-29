import Foundation

enum SyncStatus: String, Codable, Sendable {
    case pending
    case uploading
    case synced
    case failed
}
