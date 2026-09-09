import Foundation
import MusicboxCore

/// On-disk snapshot of the synced library: the merged track set plus the
/// highest rev applied so far. `Track` is reused verbatim from `MusicboxCore`
/// (snake_case Codable), so the stored file is byte-compatible with the wire
/// payload's track shape.
struct LibrarySnapshot: Codable, Sendable {
    var rev: Int
    var tracks: [Track]

    static let empty = LibrarySnapshot(rev: 0, tracks: [])
}

/// A tiny Codable-file store in Application Support.
///
/// This is deliberately lean for Phase 0. FUTURE: swap this for GRDB (a single
/// SQLite file with a `tracks` table + indices) once the library grows past a
/// few thousand rows or we need incremental/queryable persistence and a
/// play-event log. The `load()`/`save()` surface is all the app depends on, so
/// that migration stays local to this file.
struct LibraryStore {
    let fileURL: URL

    /// Creates the store, ensuring `Application Support/Musicbox/` exists and
    /// is excluded from iCloud/iTunes backup (it is a rebuildable cache of
    /// server state, not user-authored data).
    init(fileManager: FileManager = .default) throws {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        var dir = base.appendingPathComponent("Musicbox", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.excludeFromBackup(&dir)
        self.fileURL = dir.appendingPathComponent("library.json", isDirectory: false)
    }

    func load() -> LibrarySnapshot {
        guard let data = try? Data(contentsOf: fileURL) else { return .empty }
        return (try? JSONDecoder().decode(LibrarySnapshot.self, from: data)) ?? .empty
    }

    func save(_ snapshot: LibrarySnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        // Encrypted at rest, but readable for background audio after the first
        // unlock — the right protection class for a background media app.
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var url = fileURL
        Self.excludeFromBackup(&url)
    }

    private static func excludeFromBackup(_ url: inout URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
