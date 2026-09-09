import Foundation

// MARK: - Track

/// Mirrors a single row of `GET /v1/sync?since={rev}` → `tracks[]`.
///
/// Field presence follows the server's tagging reality: metadata that may be
/// missing from a file's tags (artist, album, year, genre, track/disc
/// numbers, bitrate for some containers, ReplayGain, YouTube provenance) is
/// optional. Fields the server always computes at ingest time (title,
/// duration, codec, samplerate, channels, file size, hash, timestamps, rev)
/// are required. See CONTRACT.md for the full rationale — this split was not
/// dictated by the spec and may need adjustment against the real server.
public struct Track: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var uuid: UUID
    public var title: String
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var trackNo: Int?
    public var discNo: Int?
    public var year: Int?
    public var genre: String?
    public var durationMs: Int
    public var codec: String
    public var samplerate: Int?
    public var channels: Int?
    public var bitrate: Int?
    public var fileSize: Int
    public var sha256: String
    public var rgTrackGain: Double?
    public var rgTrackPeak: Double?
    public var ytVideoId: String?
    public var sourceUrl: String?
    public var addedAt: Int
    public var modifiedAt: Int
    public var rev: Int

    public var id: UUID { uuid }

    public init(
        uuid: UUID,
        title: String,
        artist: String? = nil,
        albumArtist: String? = nil,
        album: String? = nil,
        trackNo: Int? = nil,
        discNo: Int? = nil,
        year: Int? = nil,
        genre: String? = nil,
        durationMs: Int,
        codec: String,
        samplerate: Int? = nil,
        channels: Int? = nil,
        bitrate: Int? = nil,
        fileSize: Int,
        sha256: String,
        rgTrackGain: Double? = nil,
        rgTrackPeak: Double? = nil,
        ytVideoId: String? = nil,
        sourceUrl: String? = nil,
        addedAt: Int,
        modifiedAt: Int,
        rev: Int
    ) {
        self.uuid = uuid
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.trackNo = trackNo
        self.discNo = discNo
        self.year = year
        self.genre = genre
        self.durationMs = durationMs
        self.codec = codec
        self.samplerate = samplerate
        self.channels = channels
        self.bitrate = bitrate
        self.fileSize = fileSize
        self.sha256 = sha256
        self.rgTrackGain = rgTrackGain
        self.rgTrackPeak = rgTrackPeak
        self.ytVideoId = ytVideoId
        self.sourceUrl = sourceUrl
        self.addedAt = addedAt
        self.modifiedAt = modifiedAt
        self.rev = rev
    }

    enum CodingKeys: String, CodingKey {
        case uuid, title, artist
        case albumArtist = "album_artist"
        case album
        case trackNo = "track_no"
        case discNo = "disc_no"
        case year, genre
        case durationMs = "duration_ms"
        case codec, samplerate, channels, bitrate
        case fileSize = "file_size"
        case sha256
        case rgTrackGain = "rg_track_gain"
        case rgTrackPeak = "rg_track_peak"
        case ytVideoId = "yt_video_id"
        case sourceUrl = "source_url"
        case addedAt = "added_at"
        case modifiedAt = "modified_at"
        case rev
    }
}

// MARK: - PlayEvent

/// An append-only play-log entry. Play counts / "last played" / etc. are
/// always *derived* from a collection of these — never stored as a mutable
/// counter on `Track`. Wire-encoded snake_case for symmetry with `Track`.
public struct PlayEvent: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var trackUUID: UUID
    public var playedAt: Int
    public var msPlayed: Int
    public var completed: Bool
    public var device: String

    public init(id: UUID, trackUUID: UUID, playedAt: Int, msPlayed: Int, completed: Bool, device: String) {
        self.id = id
        self.trackUUID = trackUUID
        self.playedAt = playedAt
        self.msPlayed = msPlayed
        self.completed = completed
        self.device = device
    }

    enum CodingKeys: String, CodingKey {
        case id
        case trackUUID = "track_uuid"
        case playedAt = "played_at"
        case msPlayed = "ms_played"
        case completed, device
    }
}

// MARK: - Tombstone

public struct Tombstone: Codable, Equatable, Hashable, Sendable {
    public var uuid: UUID
    public var rev: Int

    public init(uuid: UUID, rev: Int) {
        self.uuid = uuid
        self.rev = rev
    }
}

// MARK: - Playlist

/// A user-ordered, explicit playlist (as opposed to a `SmartPlaylistRule`,
/// which is evaluated dynamically). Not specified field-by-field in the
/// brief; modeled to mirror `Track`/sync conventions (rev + timestamps) so
/// it can ride the same sync machinery in the future.
public struct Playlist: Codable, Equatable, Identifiable, Sendable {
    public var uuid: UUID
    public var name: String
    public var trackUUIDs: [UUID]
    public var createdAt: Int
    public var modifiedAt: Int
    public var rev: Int

    public var id: UUID { uuid }

    public init(uuid: UUID, name: String, trackUUIDs: [UUID], createdAt: Int, modifiedAt: Int, rev: Int) {
        self.uuid = uuid
        self.name = name
        self.trackUUIDs = trackUUIDs
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.rev = rev
    }

    enum CodingKeys: String, CodingKey {
        case uuid, name
        case trackUUIDs = "track_uuids"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
        case rev
    }
}

// MARK: - Smart playlist rule model

/// Fields a smart-playlist condition (or a search filter) may test.
/// `playCount` / `rating` / `bpm` are *derived or locally-stored* — they are
/// not part of the `Track` wire payload (see CONTRACT.md).
public enum PredicateField: String, Codable, Sendable, CaseIterable {
    case title, artist, albumArtist, album, genre, year
    case trackNo, discNo
    case duration, added, modified
    case playCount, rating, bpm
    case fileSize, bitrate, codec
}

public enum PredicateComparator: String, Codable, Sendable {
    case equals = "="
    case notEquals = "!="
    case lessThan = "<"
    case lessThanOrEqual = "<="
    case greaterThan = ">"
    case greaterThanOrEqual = ">="
    case contains
}

public struct SmartPlaylistCondition: Codable, Equatable, Sendable {
    public var field: PredicateField
    public var comparator: PredicateComparator
    /// Raw textual value, parsed contextually per field (e.g. "30d" for a
    /// date-typed field means "30 days ago", "5m" for duration means minutes).
    public var value: String

    public init(field: PredicateField, comparator: PredicateComparator, value: String) {
        self.field = field
        self.comparator = comparator
        self.value = value
    }
}

public struct SmartPlaylistRule: Codable, Equatable, Sendable {
    /// AND-combined; matches the "played < 3 AND added > 30d AND genre = electronic" example.
    public var conditions: [SmartPlaylistCondition]
    public var sort: [SortDescriptor]
    public var limit: Int?

    public init(conditions: [SmartPlaylistCondition], sort: [SortDescriptor] = [], limit: Int? = nil) {
        self.conditions = conditions
        self.sort = sort
        self.limit = limit
    }
}

// MARK: - Derived stats

/// Per-track statistics that are either derived from the `PlayEvent` log
/// (`playCount`) or stored purely locally on-device (`rating`, `bpm`) — none
/// of these three ride the sync wire contract. Callers assemble a
/// `[UUID: TrackStats]` lookup and thread it through `SearchIndex` /
/// `SortEngine` / `SmartPlaylist` wherever those fields are needed.
public struct TrackStats: Equatable, Sendable {
    public var playCount: Int
    public var rating: Int?
    public var bpm: Double?

    public init(playCount: Int = 0, rating: Int? = nil, bpm: Double? = nil) {
        self.playCount = playCount
        self.rating = rating
        self.bpm = bpm
    }

    public static let empty = TrackStats()
}

/// Derive per-track play counts from an append-only event log.
/// - Parameter completedOnly: if true, only count events with `completed == true`.
public func derivePlayCounts(from events: [PlayEvent], completedOnly: Bool = false) -> [UUID: Int] {
    var counts: [UUID: Int] = [:]
    for event in events where !completedOnly || event.completed {
        counts[event.trackUUID, default: 0] += 1
    }
    return counts
}
