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

/// Loads album art from the LOCAL cache written by `LocalLibraryService`
/// (a downsized JPEG per track uuid), downsampling with ImageIO rather than
/// `UIImage(data:)` so we never hold a full-resolution decode in memory. Results
/// are cached in a small in-memory `NSCache`.
@MainActor
final class ArtworkLoader: ObservableObject {
    private let maxPixelSize: CGFloat = 200
    private let library: LocalLibraryService
    private let cache: NSCache<NSUUID, UIImage> = {
        let c = NSCache<NSUUID, UIImage>()
        c.countLimit = 300
        return c
    }()

    init(library: LocalLibraryService) {
        self.library = library
    }

    func cachedImage(for uuid: UUID) -> UIImage? {
        cache.object(forKey: uuid as NSUUID)
    }

    /// Returns a downsampled thumbnail for `uuid`, or `nil` if the track has no art.
    func image(for uuid: UUID) async -> UIImage? {
        if let cached = cache.object(forKey: uuid as NSUUID) { return cached }
        guard let url = library.artworkURL(for: uuid),
              let data = try? Data(contentsOf: url) else { return nil }
        guard let image = await Self.downsample(data, maxPixelSize: maxPixelSize) else { return nil }
        cache.setObject(image, forKey: uuid as NSUUID)
        return image
    }

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
