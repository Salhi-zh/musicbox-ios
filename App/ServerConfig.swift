import Foundation

/// A resolved, ready-to-use server configuration. `Sendable` so it can be
/// snapshotted on the main actor and handed to the `SyncService` actor / used
/// from background download tasks.
struct ServerConfig: Sendable, Equatable {
    /// Base URL of the server, e.g. `http://100.x.y.z:PORT`. No trailing `/v1`.
    var baseURL: URL
    var bearerToken: String

    /// Builds a request against a `/v1/...` path with the bearer header set.
    func request(path: String, queryItems: [URLQueryItem] = []) -> URLRequest? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        // Join base path (usually empty) with the endpoint path safely.
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + path
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        return request
    }
}
