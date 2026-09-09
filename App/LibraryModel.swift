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

/// Owns the synced library and turns it into rows for the UI. All search and
/// sorting delegate to `MusicboxCore` (`SearchIndex` / `SortEngine`); this
/// class only orchestrates and formats.
@MainActor
final class LibraryModel: ObservableObject {
    /// The full library, sorted by `sort`. The Library tab renders this.
    @Published private(set) var rows: [TrackRow] = []
    @Published private(set) var rev: Int = 0
    @Published private(set) var trackCount: Int = 0
    @Published private(set) var isSyncing = false
    @Published var lastMessage: String?

    /// Bound to the Library sort menu.
    @Published var sort: LibrarySort = .title {
        didSet { if oldValue != sort { recompute() } }
    }

    private var allTracks: [Track] = []
    private var index: SearchIndex?

    private let store: LibraryStore?
    private let sync: SyncService
    private let settings: SettingsStore

    init(settings: SettingsStore, sync: SyncService) {
        self.settings = settings
        self.sync = sync
        self.store = try? LibraryStore()

        let snapshot = store?.load() ?? .empty
        apply(tracks: snapshot.tracks, rev: snapshot.rev)
        recompute()
    }

    // MARK: Sync

    func syncNow() async {
        guard let config = settings.config else {
            lastMessage = "Set the server URL and token in Settings first."
            return
        }
        guard !isSyncing else { return }
        isSyncing = true
        lastMessage = nil
        defer { isSyncing = false }

        await sync.updateConfig(config)

        var state = SyncState(
            tracksByUUID: Dictionary(allTracks.map { ($0.uuid, $0) }, uniquingKeysWith: { _, new in new }),
            rev: rev
        )
        do {
            try await SyncClient.syncAll(&state, transport: sync)
            apply(tracks: state.tracks, rev: state.rev)
            recompute()
            try store?.save(LibrarySnapshot(rev: rev, tracks: allTracks))
            lastMessage = "Synced \(trackCount) tracks (rev \(rev))."
        } catch {
            lastMessage = "Sync failed: \(error.localizedDescription)"
        }
    }

    // MARK: Query -> rows

    /// Rebuild the full sorted `rows` (Library tab). Cheap for a few hundred
    /// tracks, so it's fine to call on every sort change.
    func recompute() {
        let sorted = SortEngine.sorted(allTracks, by: sort.descriptors)
        rows = sorted.map(Self.row(for:))
    }

    /// Pure search used by the Search tab: runs the query through
    /// `SearchIndex` (relevance-ranked) and returns render-ready rows WITHOUT
    /// mutating the shared `rows`. An empty query returns nothing (the Search
    /// tab shows a prompt instead of the whole library).
    func results(for query: String) -> [TrackRow] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index else { return [] }
        return index.search(trimmed).scored.map { Self.row(for: $0.track) }
    }

    // MARK: Internals

    private func apply(tracks: [Track], rev: Int) {
        allTracks = tracks
        self.rev = rev
        trackCount = tracks.count
        // Rebuild the search index whenever the underlying set changes.
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
