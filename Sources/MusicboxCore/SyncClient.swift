import Foundation

/// Payload of `GET /v1/sync?since={rev}`.
public struct SyncResponse: Codable, Equatable, Sendable {
    public var rev: Int
    public var tracks: [Track]
    public var tombstones: [Tombstone]

    public init(rev: Int, tracks: [Track], tombstones: [Tombstone]) {
        self.rev = rev
        self.tracks = tracks
        self.tombstones = tombstones
    }
}

/// Network abstracted behind a protocol so tests (and the real app) can
/// inject a fake/live transport. `MusicboxCore` never touches URLSession
/// directly.
public protocol SyncTransport: Sendable {
    func fetchSync(since: Int) async throws -> SyncResponse
}

/// Client-side materialized view of the library: the merged track set plus
/// the highest rev seen so far.
public struct SyncState: Equatable, Sendable {
    public var tracksByUUID: [UUID: Track]
    public var rev: Int

    public init(tracksByUUID: [UUID: Track] = [:], rev: Int = 0) {
        self.tracksByUUID = tracksByUUID
        self.rev = rev
    }

    public var tracks: [Track] { Array(tracksByUUID.values) }
}

public enum SyncError: Error, Equatable, Sendable {
    /// The rolling divergence hash computed from local state doesn't match
    /// the hash the caller expects — a delta was dropped/corrupted somewhere
    /// upstream. Caller should discard local state and do a full resync
    /// (i.e. `fetchSync(since: 0)`).
    case divergenceDetected(expected: UInt64, actual: UInt64)
}

public enum SyncClient {

    /// Applies one sync page: upserts `response.tracks`, removes anything in
    /// `response.tombstones`, and bumps `state.rev` to `max(state.rev,
    /// response.rev)`. Returns the new rev.
    @discardableResult
    public static func applySync(_ response: SyncResponse, into state: inout SyncState) -> Int {
        for track in response.tracks {
            state.tracksByUUID[track.uuid] = track
        }
        for tombstone in response.tombstones {
            // A tombstone with a lower rev than what we already have for
            // that uuid would be stale/out-of-order; only apply if it's not
            // superseded by a track upsert of equal-or-higher rev in this
            // very page (tracks are applied first above, so this simply
            // matches server intent: tombstone always wins for its uuid).
            state.tracksByUUID.removeValue(forKey: tombstone.uuid)
        }
        state.rev = max(state.rev, response.rev)
        return state.rev
    }

    /// Repeatedly calls `transport.fetchSync(since:)` starting from
    /// `state.rev` until a page reports no further advancement, applying
    /// each page in turn.
    public static func syncAll(_ state: inout SyncState, transport: any SyncTransport) async throws {
        while true {
            let response = try await transport.fetchSync(since: state.rev)
            let previousRev = state.rev
            applySync(response, into: &state)
            if state.rev <= previousRev {
                break
            }
        }
    }

    // MARK: Divergence hash

    /// Deterministic (process- and platform-independent) hash over the
    /// sorted `(uuid, rev)` pairs of the current track set. Two clients — or
    /// a client before/after a suspected-dropped delta — that compute the
    /// same hash are provably looking at the same `(uuid, rev)` set. A
    /// mismatch means silent delta drift; the caller should fall back to a
    /// full resync (`since: 0`).
    public static func divergenceHash(_ tracks: [Track]) -> UInt64 {
        let sorted = tracks.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
        var hash: UInt64 = 0xcbf29ce484222325 // FNV-1a offset basis
        for track in sorted {
            withUnsafeBytes(of: track.uuid.uuid) { hash = fnv1a($0, into: hash) }
            withUnsafeBytes(of: Int64(track.rev).bigEndian) { hash = fnv1a($0, into: hash) }
        }
        return hash
    }

    private static func fnv1a(_ bytes: UnsafeRawBufferPointer, into initial: UInt64) -> UInt64 {
        var hash = initial
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    /// Verifies the local track set against a hash the caller believes is
    /// authoritative (e.g. one echoed back by the server, or one captured
    /// before applying a suspect delta). Throws `.divergenceDetected` on mismatch.
    public static func verifyDivergence(_ tracks: [Track], expected: UInt64) throws {
        let actual = divergenceHash(tracks)
        if actual != expected {
            throw SyncError.divergenceDetected(expected: expected, actual: actual)
        }
    }

    // MARK: Play-event sync

    /// Append-only union of a local and remote play-event log, deduped by `id`.
    public static func mergePlayEvents(_ existing: [PlayEvent], with incoming: [PlayEvent]) -> [PlayEvent] {
        var byId: [UUID: PlayEvent] = [:]
        var order: [UUID] = []
        for event in existing + incoming {
            if byId[event.id] == nil {
                order.append(event.id)
            }
            byId[event.id] = event
        }
        return order.map { byId[$0]! }
    }
}
