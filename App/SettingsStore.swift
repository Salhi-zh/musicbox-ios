import Foundation
import Combine

/// Persists the server base URL and bearer token.
///
/// For now these live in `UserDefaults`. The bearer token is a credential and
/// SHOULD move to the Keychain (kSecClassGenericPassword) before this app is
/// shared or shipped — left as UserDefaults for Phase 0 simplicity. The rest
/// of the app only ever reads `config`, so swapping the backing store later is
/// a change local to this file.
@MainActor
final class SettingsStore: ObservableObject {
    private enum Keys {
        static let baseURL = "musicbox.server.baseURL"
        static let token = "musicbox.server.token"
    }

    private let defaults: UserDefaults

    @Published var baseURLString: String {
        didSet { defaults.set(baseURLString, forKey: Keys.baseURL) }
    }

    @Published var bearerToken: String {
        didSet { defaults.set(bearerToken, forKey: Keys.token) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.baseURLString = defaults.string(forKey: Keys.baseURL) ?? ""
        self.bearerToken = defaults.string(forKey: Keys.token) ?? ""
    }

    /// A usable config, or `nil` if the user has not entered a valid URL + token yet.
    var config: ServerConfig? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            !bearerToken.isEmpty,
            let url = URL(string: trimmed),
            url.scheme != nil,
            url.host != nil
        else { return nil }
        return ServerConfig(baseURL: url, bearerToken: bearerToken)
    }
}
