import Foundation
import MusicboxCore

/// Thin, stateless helper for the server's REST surface. It only knows how to
/// build requests and run the couple of one-shot calls the UI needs directly
/// (`/v1/health`); the streaming/large-body endpoints (`/v1/sync`,
/// `/v1/media`, `/v1/art`) are driven by `SyncService`, `AudioPlayer` and
/// `ArtworkLoader` respectively so each owns its own caching policy.
enum MusicboxAPI {

    // MARK: URL builders

    static func mediaRequest(for uuid: UUID, config: ServerConfig) -> URLRequest? {
        config.request(path: "/v1/media/\(uuid.uuidString)")
    }

    static func artRequest(for uuid: UUID, size: Int, config: ServerConfig) -> URLRequest? {
        config.request(path: "/v1/art/\(uuid.uuidString)", queryItems: [
            URLQueryItem(name: "size", value: String(size))
        ])
    }

    static func syncRequest(since rev: Int, config: ServerConfig) -> URLRequest? {
        config.request(path: "/v1/sync", queryItems: [
            URLQueryItem(name: "since", value: String(rev))
        ])
    }

    // MARK: Health

    enum HealthResult: Equatable {
        case ok(String)
        case unreachable(String)
    }

    /// GETs `/v1/health`. Returns a short human-readable status either way; it
    /// never throws so the Settings screen can show a result directly.
    static func health(config: ServerConfig, session: URLSession = .shared) async -> HealthResult {
        guard let request = config.request(path: "/v1/health") else {
            return .unreachable("Invalid server URL")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable("No HTTP response")
            }
            guard http.statusCode == 200 else {
                return .unreachable("HTTP \(http.statusCode)")
            }
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .ok(body.isEmpty ? "OK" : body)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}
