import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import MusicboxCore

/// The on-device music library. No server, no sync.
///
/// Audio files live in the app's Documents directory, which is exposed in the
/// Files app as "On My iPhone → Musicbox" (`UIFileSharingEnabled` +
/// `LSSupportsOpeningDocumentsInPlace`). The user drags files in there, or uses
/// the in-app Import button (`.fileImporter`). `scan()` walks Documents,
/// extracts metadata with AVFoundation, cleans messy YouTube-style names, and
/// builds `[MusicboxCore.Track]` for the UI. A small Codable index in
/// Application Support persists the results (and keeps each track's UUID stable
/// across rescans); cached artwork is written as downsized JPEGs there too.
@MainActor
final class LocalLibraryService: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isScanning = false

    /// Documents dir — the "Musicbox" folder users see in the Files app.
    let musicDir: URL
    private let supportDir: URL
    private let artDir: URL
    private let indexURL: URL

    private var entries: [Entry] = []
    private var urlByUUID: [UUID: URL] = [:]

    private static let audioExtensions: Set<String> =
        ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "alac", "mp4"]

    struct Entry: Codable {
        var track: Track
        var relativePath: String
        var hasArtwork: Bool
    }
    private struct LocalIndex: Codable { var entries: [Entry] }

    init() {
        let fm = FileManager.default
        musicDir = (try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        supportDir = support.appendingPathComponent("Musicbox", isDirectory: true)
        artDir = supportDir.appendingPathComponent("artwork", isDirectory: true)
        indexURL = supportDir.appendingPathComponent("index.json", isDirectory: false)
        try? fm.createDirectory(at: artDir, withIntermediateDirectories: true)
        loadIndex()
    }

    // MARK: Lookups used by the player / artwork loader

    func fileURL(for uuid: UUID) -> URL? { urlByUUID[uuid] }

    func artworkURL(for uuid: UUID) -> URL? {
        let u = artDir.appendingPathComponent(uuid.uuidString + ".jpg")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    // MARK: Import (from the in-app document picker)

    /// Copy picked files into the Documents folder, then rescan.
    func importFiles(_ urls: [URL]) async {
        let fm = FileManager.default
        for src in urls {
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }
            let dest = uniqueDestination(for: src.lastPathComponent)
            do { try fm.copyItem(at: src, to: dest) } catch { continue }
        }
        await scan()
    }

    // MARK: Scan

    /// Walk Documents, index any new audio files, drop vanished ones, publish.
    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let fm = FileManager.default
        var byPath: [String: Entry] = Dictionary(
            entries.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a }
        )
        var seen = Set<String>()

        // Gather file URLs synchronously first — iterating a DirectoryEnumerator
        // with for-in is unavailable in an async context, so use nextObject().
        var fileURLs: [URL] = []
        if let en = fm.enumerator(
            at: musicDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            while let url = en.nextObject() as? URL {
                if Self.audioExtensions.contains(url.pathExtension.lowercased()) {
                    fileURLs.append(url)
                }
            }
        }
        for url in fileURLs {
            let rel = relativePath(of: url)
            seen.insert(rel)
            if byPath[rel] != nil { continue }               // already indexed
            if let entry = await makeEntry(for: url, relativePath: rel) {
                byPath[rel] = entry
            }
        }

        let kept = byPath.values.filter { seen.contains($0.relativePath) }
        setEntries(kept.sorted { $0.track.title.localizedCaseInsensitiveCompare($1.track.title) == .orderedAscending })
        saveIndex()
    }

    // MARK: Build one track from a file

    private func makeEntry(for url: URL, relativePath rel: String) async -> Entry? {
        let asset = AVURLAsset(url: url)

        var embeddedTitle: String?
        var embeddedArtist: String?
        var embeddedAlbum: String?
        var embeddedAlbumArtist: String?
        var artworkData: Data?

        if let meta = try? await asset.load(.commonMetadata) {
            for item in meta {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:      embeddedTitle = try? await item.load(.stringValue)
                case .commonKeyArtist:     embeddedArtist = try? await item.load(.stringValue)
                case .commonKeyAlbumName:  embeddedAlbum = try? await item.load(.stringValue)
                case .commonKeyArtwork:    artworkData = try? await item.load(.dataValue)
                default: break
                }
            }
        }
        // iTunes "album artist" isn't a common key; try the id3/itunes spaces.
        if embeddedAlbumArtist == nil, let meta = try? await asset.load(.metadata) {
            for item in meta where (item.identifier == .id3MetadataBand
                                    || item.identifier == .iTunesMetadataAlbumArtist) {
                embeddedAlbumArtist = try? await item.load(.stringValue)
            }
        }

        let durationSec = (try? await asset.load(.duration))?.seconds ?? 0
        let durationMs = Int((durationSec.isFinite ? durationSec : 0) * 1000)

        let cleaned = TitleCleaner.clean(
            embeddedTitle: embeddedTitle,
            embeddedArtist: embeddedArtist,
            filename: url.deletingPathExtension().lastPathComponent
        )

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let now = Int(Date().timeIntervalSince1970)
        let uuid = UUID()   // stability comes from the persisted index (existing rels are skipped)

        let track = Track(
            uuid: uuid,
            title: cleaned.title.isEmpty ? url.deletingPathExtension().lastPathComponent : cleaned.title,
            artist: cleaned.artist,
            albumArtist: embeddedAlbumArtist ?? cleaned.artist,
            album: (embeddedAlbum?.isEmpty == false ? embeddedAlbum : nil) ?? cleaned.album,
            durationMs: durationMs,
            codec: url.pathExtension.lowercased(),
            fileSize: size,
            sha256: "",
            sourceUrl: rel,
            addedAt: now,
            modifiedAt: now,
            rev: 0
        )

        var hasArt = false
        if let data = artworkData, let jpeg = Self.downsampledJPEG(data, maxPixel: 500) {
            let dest = artDir.appendingPathComponent(uuid.uuidString + ".jpg")
            if (try? jpeg.write(to: dest, options: .atomic)) != nil { hasArt = true }
        }

        return Entry(track: track, relativePath: rel, hasArtwork: hasArt)
    }

    // MARK: Index persistence

    private func setEntries(_ newEntries: [Entry]) {
        entries = newEntries
        urlByUUID = Dictionary(
            newEntries.map { ($0.track.uuid, musicDir.appendingPathComponent($0.relativePath)) },
            uniquingKeysWith: { a, _ in a }
        )
        tracks = newEntries.map(\.track)
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let idx = try? JSONDecoder().decode(LocalIndex.self, from: data) else {
            setEntries([])
            return
        }
        // Only keep entries whose file still exists.
        let fm = FileManager.default
        let live = idx.entries.filter { fm.fileExists(atPath: musicDir.appendingPathComponent($0.relativePath).path) }
        setEntries(live)
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(LocalIndex(entries: entries)) else { return }
        try? data.write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var url = indexURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: Helpers

    private func relativePath(of url: URL) -> String {
        let base = musicDir.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        if full.hasPrefix(base) {
            return String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return url.lastPathComponent
    }

    private func uniqueDestination(for filename: String) -> URL {
        let fm = FileManager.default
        var candidate = musicDir.appendingPathComponent(filename)
        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        var n = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = musicDir.appendingPathComponent("\(stem) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Downsample embedded artwork to a small JPEG without realizing the full bitmap.
    private static func downsampledJPEG(_ data: Data, maxPixel: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
