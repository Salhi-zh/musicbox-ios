import Foundation
import Combine
import UIKit
import ImageIO
import MusicboxCore

/// A `UIImage` moved across a concurrency boundary. `UIImage` is not `Sendable`,
/// but a freshly-decoded, never-mutated thumbnail is effectively immutable, so
/// this hand-off is safe.
private struct SendableImage: @unchecked Sendable {
    let image: UIImage
}

/// Loads album art via `GET /v1/art/{uuid}?size=200`, downsampling with
/// ImageIO (`CGImageSourceCreateThumbnailAtIndex`) rather than
/// `UIImage(data:)` so we never hold a full-resolution decode in memory, and
/// caches the results in a small in-memory `NSCache`.
@MainActor
final class ArtworkLoader: ObservableObject {
    /// Point size we ask the server for; the request tops out at the 200px art.
    private let requestSize = 200
    /// Pixel ceiling for the downsample (≈2x for Retina crispness at 100pt).
    private let maxPixelSize: CGFloat = 200

    private let settings: SettingsStore
    private let session: URLSession
    private let cache: NSCache<NSUUID, UIImage> = {
        let c = NSCache<NSUUID, UIImage>()
        c.countLimit = 300
        return c
    }()

    init(settings: SettingsStore, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    func cachedImage(for uuid: UUID) -> UIImage? {
        cache.object(forKey: uuid as NSUUID)
    }

    /// Returns a downsampled thumbnail for `uuid`, or `nil` if unavailable.
    func image(for uuid: UUID) async -> UIImage? {
        if let cached = cache.object(forKey: uuid as NSUUID) { return cached }
        guard let config = settings.config,
              let request = MusicboxAPI.artRequest(for: uuid, size: requestSize, config: config)
        else { return nil }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let image = await Self.downsample(data, maxPixelSize: maxPixelSize) else { return nil }
            cache.setObject(image, forKey: uuid as NSUUID)
            return image
        } catch {
            return nil
        }
    }

    /// Downsamples off the main actor. ImageIO decodes straight to the target
    /// pixel size, so the full-size bitmap is never realized.
    private static func downsample(_ data: Data, maxPixelSize: CGFloat) async -> UIImage? {
        await Task.detached(priority: .utility) { () -> SendableImage? in
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            guard
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            return SendableImage(image: UIImage(cgImage: cgImage))
        }.value?.image
    }
}
