import Foundation

/// Lightweight client for rawcut backend API calls.
enum APIClient {

    #if DEBUG
    static let baseURL = "https://avah-unexploitative-marcelle.ngrok-free.dev"
    #else
    static let baseURL = "https://rawcut-api.wittygrass-ccc95e2e.koreacentral.azurecontainerapps.io"
    #endif

    // MARK: - Models

    struct Project: Identifiable, Codable, Sendable, Hashable {
        let id: String
        let user_id: String
        let title: String
        let description: String
        let created_at: String
        let updated_at: String
        let type: String?

        var isAuto: Bool { type == "auto" }

        var formattedDate: String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: created_at) {
                return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
            }
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: created_at) {
                return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
            }
            return created_at
        }
    }

    struct ProjectClip: Codable, Sendable {
        let asset_id: String
        let position: Int
        let trim_start: Double
        let trim_end: Double?
        let role: String
        let blob_name: String?
        let media_type: String?
        let content_type: String?
        let quality_score: Double?
        let energy_level: Double?
    }

    struct Render: Identifiable, Codable, Sendable {
        let id: String
        let project_id: String
        let user_id: String
        let status: String
        let preset: String
        let aspect_ratio: String
        let progress: Double
        let output_blob: String?
        let error: String?
        let created_at: String
        let completed_at: String?

        var isComplete: Bool { status == "complete" }
        var isFailed: Bool { status == "failed" }
        var isProcessing: Bool { status == "processing" || status == "queued" }
    }

    struct DownloadURL: Codable, Sendable {
        let url: String
    }

    struct AutoVideoResponse: Codable, Sendable {
        let project_id: String
        let render_id: String
        let title: String
        let clip_count: Int
        let estimated_seconds: Int
        let is_existing: Bool
        let preset: String
        let aspect_ratio: String
    }

    enum AutoVideoError: LocalizedError {
        case serverError(String)
        var errorDescription: String? {
            switch self {
            case .serverError(let msg): return msg
            }
        }
    }

    // MARK: - Auto-Video

    static func createAutoVideo(
        timezoneOffset: Int,
        preset: String = "warm_film",
        aspectRatio: String = "2.0",
        authToken: String
    ) async throws -> AutoVideoResponse {
        guard let url = URL(string: "\(baseURL)/api/auto-video") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct Body: Encodable {
            let timezone_offset: Int
            let preset: String
            let aspect_ratio: String
        }
        request.httpBody = try JSONEncoder().encode(
            Body(timezone_offset: timezoneOffset, preset: preset, aspect_ratio: aspectRatio)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // Parse server error message
            struct ErrorDetail: Decodable { let detail: String }
            if let err = try? JSONDecoder().decode(ErrorDetail.self, from: data) {
                throw AutoVideoError.serverError(err.detail)
            }
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(AutoVideoResponse.self, from: data)
    }

    // MARK: - Projects

    static func listProjects(authToken: String) async throws -> [Project] {
        guard let url = URL(string: "\(baseURL)/api/projects") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode([Project].self, from: data)
    }

    static func createProject(title: String, description: String, authToken: String) async throws -> Project {
        guard let url = URL(string: "\(baseURL)/api/projects") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct Body: Encodable { let title: String; let description: String }
        request.httpBody = try JSONEncoder().encode(Body(title: title, description: description))

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(Project.self, from: data)
    }

    static func deleteProject(id: String, authToken: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/projects/\(id)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
    }

    // MARK: - Clips

    static func setProjectClips(projectId: String, blobNames: [String], authToken: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/projects/\(projectId)/clips") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct ClipItem: Encodable {
            let blob_name: String
            let position: Int
        }
        struct Body: Encodable { let clips: [ClipItem] }

        let clips = blobNames.enumerated().map { ClipItem(blob_name: $1, position: $0) }
        request.httpBody = try JSONEncoder().encode(Body(clips: clips))

        let (_, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
    }

    static func getProjectClips(projectId: String, authToken: String) async throws -> [ProjectClip] {
        guard let url = URL(string: "\(baseURL)/api/projects/\(projectId)/clips") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode([ProjectClip].self, from: data)
    }

    // MARK: - Renders

    static func startRender(
        projectId: String,
        preset: String = "warm_film",
        aspectRatio: String = "2.0",
        authToken: String
    ) async throws -> Render {
        guard let url = URL(string: "\(baseURL)/api/projects/\(projectId)/render") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct Body: Encodable { let preset: String; let aspect_ratio: String }
        request.httpBody = try JSONEncoder().encode(Body(preset: preset, aspect_ratio: aspectRatio))

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(Render.self, from: data)
    }

    static func getRenderStatus(renderId: String, authToken: String) async throws -> Render {
        guard let url = URL(string: "\(baseURL)/api/renders/\(renderId)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(Render.self, from: data)
    }

    static func getRenderDownloadURL(renderId: String, authToken: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/api/renders/\(renderId)/download") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(DownloadURL.self, from: data).url
    }

    static func listProjectRenders(projectId: String, authToken: String) async throws -> [Render] {
        guard let url = URL(string: "\(baseURL)/api/projects/\(projectId)/renders") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode([Render].self, from: data)
    }

    // MARK: - Helpers

    private static func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
