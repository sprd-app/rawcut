import Foundation

// MARK: - Upload Result

struct UploadResult: Sendable {
    let cloudBlobName: String
    let bytesUploaded: Int64
}

// MARK: - Upload Error

enum UploadError: Error, LocalizedError {
    case noAuthToken
    case serverError(statusCode: Int, message: String)
    case fileNotFound(URL)
    case invalidResponse
    case sessionInvalid

    var errorDescription: String? {
        switch self {
        case .noAuthToken:
            "Not authenticated. Please sign in."
        case .serverError(let code, let message):
            "Server error (\(code)): \(message)"
        case .fileNotFound(let url):
            "File not found: \(url.lastPathComponent)"
        case .invalidResponse:
            "Invalid response from server."
        case .sessionInvalid:
            "Upload session is invalid."
        }
    }
}

// MARK: - Upload Manager

final class UploadManager: NSObject, Sendable {

    static let sessionIdentifier = "com.rawcut.upload"

    // Thread-safe storage for active upload state
    private let activeUploads = UploadStateStore()

    // Continuation for background events completion handler
    private let backgroundCompletionStore = BackgroundCompletionStore()

    private let session: URLSession

    private let authManager: AuthManager
    private let baseURL: URL

    init(authManager: AuthManager, baseURL: URL = URL(string: "https://api.rawcut.app")!) {
        self.authManager = authManager
        self.baseURL = baseURL

        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true

        let tempSession = URLSession(configuration: config)
        self.session = tempSession
        self.backgroundSession = tempSession

        super.init()

        // Re-create session with delegate now that self is initialized
        let delegateConfig = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        delegateConfig.isDiscretionary = false
        delegateConfig.sessionSendsLaunchEvents = true
        delegateConfig.allowsCellularAccess = true
    }

    // MARK: - Session (nonisolated for Sendable)

    private let backgroundSession: URLSession

    private static func createBackgroundSession(delegate: UploadManager) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Upload

    func uploadAsset(_ asset: MediaAsset, fileURL: URL) async throws -> UploadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw UploadError.fileNotFound(fileURL)
        }

        let token = await authToken()
        guard let token else {
            throw UploadError.noAuthToken
        }

        let endpoint = baseURL.appendingPathComponent("/api/upload/stream")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(asset.localIdentifier, forHTTPHeaderField: "X-Local-Identifier")
        request.setValue(asset.mediaTypeRaw, forHTTPHeaderField: "X-Media-Type")
        request.setValue("\(asset.fileSize)", forHTTPHeaderField: "X-File-Size")

        let uploadState = UploadState(assetIdentifier: asset.localIdentifier)
        await activeUploads.set(asset.localIdentifier, state: uploadState)

        let localId = asset.localIdentifier
        let fileSize = asset.fileSize
        let uploads = activeUploads
        let session = backgroundSession

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: fileURL)
            task.taskDescription = localId

            Task { @Sendable in
                await uploads.setContinuation(localId, continuation: continuation)
            }

            task.resume()
            print("[Rawcut] Upload started: \(localId) (\(fileSize) bytes)")
        }
    }

    // MARK: - Background Events

    func handleBackgroundEvents(completionHandler: @escaping @Sendable () -> Void) {
        Task {
            await backgroundCompletionStore.set(completionHandler)
        }
    }

    // MARK: - Helpers

    @MainActor
    private func authToken() -> String? {
        // In production this would return a JWT; for now use the Apple user ID
        authManager.userIdentifier
    }
}

// MARK: - URLSessionTaskDelegate

extension UploadManager: URLSessionTaskDelegate, URLSessionDataDelegate {

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let assetID = task.taskDescription else { return }
        let progress = totalBytesExpectedToSend > 0
            ? Double(totalBytesSent) / Double(totalBytesExpectedToSend)
            : 0
        Task {
            await activeUploads.updateProgress(assetID, progress: progress, bytesSent: totalBytesSent)
        }
        print("[Rawcut] Upload progress \(assetID): \(Int(progress * 100))%")
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard let assetID = dataTask.taskDescription else { return }
        Task {
            await activeUploads.appendResponseData(assetID, data: data)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let assetID = task.taskDescription else { return }

        Task {
            let state = await activeUploads.get(assetID)

            if let error {
                print("[Rawcut] Upload failed \(assetID): \(error.localizedDescription)")
                await activeUploads.resume(assetID, with: .failure(UploadError.serverError(
                    statusCode: 0,
                    message: error.localizedDescription
                )))
                return
            }

            guard let httpResponse = task.response as? HTTPURLResponse else {
                await activeUploads.resume(assetID, with: .failure(UploadError.invalidResponse))
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let body = state?.responseData.flatMap { String(data: $0, encoding: .utf8) } ?? "No body"
                print("[Rawcut] Upload server error \(assetID): \(httpResponse.statusCode) - \(body)")
                await activeUploads.resume(assetID, with: .failure(UploadError.serverError(
                    statusCode: httpResponse.statusCode,
                    message: body
                )))
                return
            }

            // Parse blob name from response
            var blobName = assetID
            if let data = state?.responseData,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["blob_name"] as? String {
                blobName = name
            }

            let result = UploadResult(
                cloudBlobName: blobName,
                bytesUploaded: state?.bytesSent ?? 0
            )
            print("[Rawcut] Upload complete \(assetID): \(blobName)")
            await activeUploads.resume(assetID, with: .success(result))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        print("[Rawcut] Background URL session finished events")
        Task {
            if let handler = await backgroundCompletionStore.get() {
                await MainActor.run { handler() }
                await backgroundCompletionStore.clear()
            }
        }
    }
}

// MARK: - Thread-safe State

private actor UploadStateStore {
    private var states: [String: UploadState] = [:]
    private var continuations: [String: CheckedContinuation<UploadResult, any Error>] = [:]

    func set(_ id: String, state: UploadState) {
        states[id] = state
    }

    func get(_ id: String) -> UploadState? {
        states[id]
    }

    func setContinuation(_ id: String, continuation: CheckedContinuation<UploadResult, any Error>) {
        continuations[id] = continuation
    }

    func updateProgress(_ id: String, progress: Double, bytesSent: Int64) {
        states[id]?.progress = progress
        states[id]?.bytesSent = bytesSent
    }

    func appendResponseData(_ id: String, data: Data) {
        if states[id]?.responseData == nil {
            states[id]?.responseData = data
        } else {
            states[id]?.responseData?.append(data)
        }
    }

    func resume(_ id: String, with result: Result<UploadResult, any Error>) {
        continuations[id]?.resume(with: result)
        continuations.removeValue(forKey: id)
        states.removeValue(forKey: id)
    }
}

private struct UploadState {
    let assetIdentifier: String
    var progress: Double = 0
    var bytesSent: Int64 = 0
    var responseData: Data?
}

private actor BackgroundCompletionStore {
    private var handler: (@Sendable () -> Void)?

    func set(_ handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func get() -> (@Sendable () -> Void)? {
        handler
    }

    func clear() {
        handler = nil
    }
}
