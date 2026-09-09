import Foundation
import MusicboxCore

/// The app's network transport for `GET /v1/sync`. An `actor` so its config
/// snapshot and `URLSession` are accessed serially off the main thread, and it
/// conforms to `MusicboxCore.SyncTransport` — meaning `SyncClient.syncAll`
/// drives it directly. Decoding reuses the `MusicboxCore` models; the merge
/// logic lives entirely in `SyncClient`.
actor SyncService: SyncTransport {
    private var config: ServerConfig?
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func updateConfig(_ config: ServerConfig) {
        self.config = config
    }

    enum TransportError: Error, LocalizedError {
        case notConfigured
        case badRequest
        case httpStatus(Int)
        case notHTTP

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Server URL / token not set."
            case .badRequest: return "Could not build the sync request URL."
            case .httpStatus(let code): return "Server returned HTTP \(code)."
            case .notHTTP: return "Unexpected (non-HTTP) response."
            }
        }
    }

    func fetchSync(since: Int) async throws -> SyncResponse {
        guard let config else { throw TransportError.notConfigured }
        guard let request = MusicboxAPI.syncRequest(since: since, config: config) else {
            throw TransportError.badRequest
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TransportError.notHTTP }
        guard http.statusCode == 200 else { throw TransportError.httpStatus(http.statusCode) }

        // The wire is snake_case, but `Track`/`Tombstone`/`SyncResponse` carry
        // their own explicit CodingKeys — so DO NOT enable
        // `.convertFromSnakeCase` here or keys would be converted twice.
        let decoder = JSONDecoder()
        return try decoder.decode(SyncResponse.self, from: data)
    }
}
