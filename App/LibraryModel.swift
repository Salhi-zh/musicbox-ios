import Foundation
import Combine
import MusicboxCore

/// User-facing sort choices. Each maps to a `MusicboxCore` descriptor list —
/// the actual ordering is done by `SortEngine`, never here.
enum LibrarySort: String, CaseIterable, Identifiable {
    case title
    case artist
    case album
    case recentlyAdded
    case duration

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .recentlyAdded: return "Recently Added"
        case .duration: return "Duration"
        }
    }

    // Fully qualified to avoid clashing with Foundation.SortDescriptor.
    var descriptors: [MusicboxCore.SortDescriptor] {
        switch self {
        case .title:
            return [.init(field: .title, direction: .ascending, stripLeadingArticle: true)]
        case .artist:
            return [
                .init(field: .artist, direction: .ascending, stripLeadingArticle: true),
                .init(field: .album, direction: .ascending, stripLeadingArticle: true),
                .init(field: .discNo, direction: .ascending),
                .init(field: .trackNo, direction: .ascending),
            ]
        case .album:
            return [
                .init(field: .album, direction: .ascending, stripLeadingArticle: true),
                .init(field: .discNo, direction: .ascending),
                .init(field: .trackNo, direction: .ascending),
            ]
        case .recentlyAdded:
            return [.init(field: .added, direction: .descending)]
        case .duration:
            return [.init(field: .duration, direction: .ascending)]
        }
    }
}

/// A single, render-ready row. Display strings are precomputed here so the
/// SwiftUI `List` does no formatting per row while scrolling.
struct TrackRow: Identifiable, Equatable {
    let id: UUID
    let title: String
    let subtitle: String
    let duration: String
    let track: Track
}

/// Turns the on-device library into rows for the UI. Search and sorting delegate
/// to `MusicboxCore` (`SearchIndex` / `SortEngine`); this class only orchestrates
/// and formats. It observes `LocalLibraryService.tracks` and recomputes on change.
@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var rows: [TrackRow] = []
    @Published private(set) var trackCount: Int = 0
    @Published private(set) var isScanning = false
    @Published var lastMessage: String?

    /// Bound to the Library sort menu.
    @Published var sort: LibrarySort = .title {
        didSet { if oldValue != sort { recompute() } }
    }

    private var allTracks: [Track] = []
    private var index: SearchIndex?

    private let service: LocalLibraryService

    init(service: LocalLibraryService) {
        self.service = service
        // Show whatever the persisted index loaded immediately.
        apply(tracks: service.tracks)
        recompute()
    }

    // MARK: Library management

    /// Rescan the Musicbox folder (picks up files dragged in via the Files app).
    func rescan() async {
        isScanning = true
        await service.scan()
        apply(tracks: service.tracks)
        recompute()
        isScanning = false
        lastMessage = "\(trackCount) songs."
    }

    /// Import files chosen with the in-app document picker.
    func importFiles(_ urls: [URL]) async {
        isScanning = true
        await service.importFiles(urls)
        apply(tracks: service.tracks)
        recompute()
        isScanning = false
        lastMessage = "Imported. \(trackCount) songs."
    }

    // MARK: Query -> rows

    /// Rebuild the full sorted `rows`. Cheap for a few hundred tracks.
    func recompute() {
        let sorted = SortEngine.sorted(allTracks, by: sort.descriptors)
        rows = sorted.map(Self.row(for:))
    }

    /// Pure search for the Search tab; does not mutate `rows`.
    func results(for query: String) -> [TrackRow] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index else { return [] }
        return index.search(trimmed).scored.map { Self.row(for: $0.track) }
    }

    // MARK: Internals

    private func apply(tracks: [Track]) {
        allTracks = tracks
        trackCount = tracks.count
        index = SearchIndex(tracks: tracks)
    }

    private static func row(for track: Track) -> TrackRow {
        var subtitleParts: [String] = []
        if let artist = track.artist, !artist.isEmpty { subtitleParts.append(artist) }
        if let album = track.album, !album.isEmpty { subtitleParts.append(album) }
        return TrackRow(
            id: track.uuid,
            title: track.title,
            subtitle: subtitleParts.joined(separator: " — "),
            duration: formatDuration(ms: track.durationMs),
            track: track
        )
    }

    private static func formatDuration(ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
