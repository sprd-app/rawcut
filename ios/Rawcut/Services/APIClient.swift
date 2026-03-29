import Foundation

/// Lightweight client for rawcut backend API calls.
enum APIClient {

    static let baseURL = "https://rawcut-api.wittygrass-ccc95e2e.koreacentral.azurecontainerapps.io"

    // MARK: - Models

    struct Project: Identifiable, Codable, Sendable {
        let id: String
        let user_id: String
        let title: String
        let description: String
        let created_at: String
        let updated_at: String

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

    // MARK: - Helpers

    private static func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
