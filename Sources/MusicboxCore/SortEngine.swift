import Foundation

/// Direction for a single level of a multi-level sort.
public enum SortDirection: String, Codable, Sendable {
    case ascending, descending
}

/// One level of a multi-level sort. `field` reuses `PredicateField` — the
/// same vocabulary `SearchIndex` filters and `SmartPlaylistRule` conditions
/// use — per the "same predicates" requirement.
public struct SortDescriptor: Codable, Equatable, Sendable {
    public var field: PredicateField
    public var direction: SortDirection
    /// Only meaningful for string fields (title/artist/albumArtist/album/genre).
    public var stripLeadingArticle: Bool

    public init(field: PredicateField, direction: SortDirection = .ascending, stripLeadingArticle: Bool = false) {
        self.field = field
        self.direction = direction
        self.stripLeadingArticle = stripLeadingArticle
    }
}

/// Builds total-order, byte-comparable collation keys for tracks and sorts
/// by them. See CONTRACT.md / module doc comments for the exact byte
/// layout; the short version:
///
/// - String fields: normalized text, digit runs replaced by
///   `0x01 <len> <leading-zero-stripped digits>` (so "Track 2" < "Track 10"),
///   remaining scalars clamped into `0x02...0xFF`, segment terminated by
///   `0x00`.
/// - Numeric/optional fields: 1 presence byte (`0x00` = present, `0x01` =
///   absent/nil, so nils sort last ascending) + 8-byte sign-flipped
///   big-endian value (Int via two's-complement sign-bit flip, Double via
///   the standard IEEE-754 sortable-bits trick).
/// - Each level bitwise-inverted when `direction == .descending`.
/// - A 16-byte UUID tie-break suffix is always appended (ascending), making
///   every produced key a total order — stable across rebuilds/processes.
public enum SortEngine {

    // MARK: Public API

    public static func sortKey(for track: Track, stats: TrackStats = .empty, descriptors: [SortDescriptor]) -> [UInt8] {
        var result: [UInt8] = []
        for descriptor in descriptors {
            var segment = segmentBytes(for: descriptor.field, track: track, stats: stats, stripArticle: descriptor.stripLeadingArticle)
            if descriptor.direction == .descending {
                for i in segment.indices { segment[i] = ~segment[i] }
            }
            result.append(contentsOf: segment)
        }
        result.append(contentsOf: uuidBytes(track.uuid))
        return result
    }

    public static func sorted(_ tracks: [Track], stats: [UUID: TrackStats] = [:], by descriptors: [SortDescriptor]) -> [Track] {
        guard !descriptors.isEmpty else {
            // Still total-order by uuid alone.
            return tracks.sorted { lexicographicallyLess(uuidBytes($0.uuid), uuidBytes($1.uuid)) }
        }
        let keyed = tracks.map { track in
            (track, sortKey(for: track, stats: stats[track.uuid] ?? .empty, descriptors: descriptors))
        }
        return keyed.sorted { lexicographicallyLess($0.1, $1.1) }.map { $0.0 }
    }

    // MARK: Segment builders

    static func collationKey(for text: String, stripArticle: Bool) -> [UInt8] {
        var normalized = Normalization.normalize(text)
        if stripArticle {
            normalized = stripLeadingArticle(normalized)
        }

        var bytes: [UInt8] = []
        let scalars = Array(normalized.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            if scalar.value >= 0x30, scalar.value <= 0x39 {
                // Digit run.
                var j = i
                var digits = ""
                while j < scalars.count, scalars[j].value >= 0x30, scalars[j].value <= 0x39 {
                    digits.unicodeScalars.append(scalars[j])
                    j += 1
                }
                var strippedDigits = Substring(digits)
                while strippedDigits.count > 1, strippedDigits.first == "0" {
                    strippedDigits.removeFirst()
                }
                bytes.append(0x01)
                bytes.append(UInt8(min(strippedDigits.count, 255)))
                for d in strippedDigits.prefix(255) {
                    bytes.append(d.asciiValue ?? 0x30)
                }
                i = j
            } else {
                let raw = scalar.value <= 0xFF ? UInt8(scalar.value) : 0xFF
                bytes.append(max(raw, 0x02))
                i += 1
            }
        }
        bytes.append(0x00) // segment terminator
        return bytes
    }

    private static let leadingArticles = ["the ", "a ", "an ", "le ", "la ", "los ", "die ", "der "]

    static func stripLeadingArticle(_ normalized: String) -> String {
        for article in leadingArticles where normalized.hasPrefix(article) {
            let stripped = String(normalized.dropFirst(article.count))
            return stripped.isEmpty ? normalized : stripped
        }
        return normalized
    }

    private static func segmentBytes(for field: PredicateField, track: Track, stats: TrackStats, stripArticle: Bool) -> [UInt8] {
        switch field {
        case .title: return collationKey(for: track.title, stripArticle: stripArticle)
        case .artist: return collationKey(for: track.artist ?? "", stripArticle: stripArticle)
        case .albumArtist: return collationKey(for: track.albumArtist ?? "", stripArticle: stripArticle)
        case .album: return collationKey(for: track.album ?? "", stripArticle: stripArticle)
        case .genre: return collationKey(for: track.genre ?? "", stripArticle: stripArticle)
        case .codec: return collationKey(for: track.codec, stripArticle: false)
        case .year: return optionalIntKey(track.year)
        case .trackNo: return optionalIntKey(track.trackNo)
        case .discNo: return optionalIntKey(track.discNo)
        case .duration: return optionalIntKey(track.durationMs)
        case .added: return optionalIntKey(track.addedAt)
        case .modified: return optionalIntKey(track.modifiedAt)
        case .playCount: return optionalIntKey(stats.playCount)
        case .rating: return optionalIntKey(stats.rating)
        case .bpm: return optionalDoubleKey(stats.bpm)
        case .fileSize: return optionalIntKey(track.fileSize)
        case .bitrate: return optionalIntKey(track.bitrate)
        }
    }

    private static func optionalIntKey(_ value: Int?) -> [UInt8] {
        guard let value else {
            return [0x01] + [UInt8](repeating: 0, count: 8)
        }
        let flipped = UInt64(bitPattern: Int64(value)) ^ 0x8000_0000_0000_0000
        return [0x00] + bigEndianBytes(flipped)
    }

    private static func optionalDoubleKey(_ value: Double?) -> [UInt8] {
        guard let value, value.isFinite else {
            return [0x01] + [UInt8](repeating: 0, count: 8)
        }
        let bits = value.bitPattern
        let flipped: UInt64 = value.sign == .minus ? ~bits : (bits | 0x8000_0000_0000_0000)
        return [0x00] + bigEndianBytes(flipped)
    }

    private static func bigEndianBytes(_ value: UInt64) -> [UInt8] {
        let be = value.bigEndian
        return withUnsafeBytes(of: be) { Array($0) }
    }

    private static func uuidBytes(_ uuid: UUID) -> [UInt8] {
        withUnsafeBytes(of: uuid.uuid) { Array($0) }
    }

    private static func lexicographicallyLess(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        let n = min(a.count, b.count)
        var i = 0
        while i < n {
            if a[i] != b[i] { return a[i] < b[i] }
            i += 1
        }
        return a.count < b.count
    }
}

// MARK: - Deterministic shuffle

/// Small, fast, seedable PRNG (SplitMix64) so shuffles are reproducible
/// given a stored seed — Swift's default `SystemRandomNumberGenerator` is
/// not seedable.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        // Avoid the degenerate all-zero state.
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

extension SortEngine {

    /// Seeded Fisher–Yates: same seed → same order, every time.
    public static func shuffled(_ tracks: [Track], seed: UInt64) -> [Track] {
        var rng = SeededGenerator(seed: seed)
        var arr = tracks
        arr.shuffle(using: &rng)
        return arr
    }

    /// Shuffle with spacing constraints: no repeated artist within
    /// `noSameArtistWithin` preceding slots (hard, honoured whenever the corpus
    /// allows it) and no repeated album within `noSameAlbumWithin` (soft — used
    /// to pick *which* track of the chosen artist to emit).
    ///
    /// Uses frequency-aware scheduling: at each slot it emits the artist with
    /// the most tracks left that isn't inside its cooldown window. That is the
    /// standard optimal strategy for spacing identical items ≥k apart — it finds
    /// a valid arrangement whenever one exists, and only when every remaining
    /// artist is still in cooldown (spacing genuinely impossible) does it relax.
    /// Deterministic for a given seed; independent of Dictionary hash order.
    public static func smartShuffle(
        _ tracks: [Track],
        seed: UInt64,
        noSameArtistWithin: Int,
        noSameAlbumWithin: Int
    ) -> [Track] {
        guard tracks.count > 1 else { return tracks }
        let pool = shuffled(tracks, seed: seed)

        // Bucket tracks by artist, preserving the seeded order within each
        // bucket. Tracks with no artist get a unique key so they're never
        // spacing-constrained against each other.
        func key(_ t: Track) -> String { t.artist ?? "\u{0}\u{0}nil-\(t.uuid.uuidString)" }
        var order: [String] = []                 // stable, seed-derived key order
        var orderIndex: [String: Int] = [:]
        var queues: [String: [Track]] = [:]
        for t in pool {
            let k = key(t)
            if queues[k] == nil {
                queues[k] = []
                orderIndex[k] = order.count
                order.append(k)
            }
            queues[k]!.append(t)
        }

        var lastPos: [String: Int] = [:]         // artist key -> last emitted slot
        var albumLastPos: [String: Int] = [:]    // album      -> last emitted slot
        var result: [Track] = []
        result.reserveCapacity(pool.count)

        func eligible(_ k: String, at p: Int) -> Bool {
            guard noSameArtistWithin > 0, let lp = lastPos[k] else { return true }
            return p - lp > noSameArtistWithin
        }

        while result.count < pool.count {
            let p = result.count
            let live = order.filter { !(queues[$0]?.isEmpty ?? true) }
            let ready = live.filter { eligible($0, at: p) }
            let choices = ready.isEmpty ? live : ready   // relax only if forced

            // Prefer most tracks remaining; tie -> longest idle (smallest
            // lastPos); tie -> stable seed order. All deterministic.
            let chosen = choices.max { a, b in
                let ca = queues[a]!.count, cb = queues[b]!.count
                if ca != cb { return ca < cb }
                let la = lastPos[a] ?? -1, lb = lastPos[b] ?? -1
                if la != lb { return la > lb }
                return orderIndex[a]! > orderIndex[b]!
            }!

            // From the chosen artist, prefer a track whose album is outside the
            // album cooldown window (soft constraint); else take the next one.
            var q = queues[chosen]!
            var pick = 0
            if noSameAlbumWithin > 0 {
                if let ok = q.firstIndex(where: { t in
                    guard let al = t.album, let ap = albumLastPos[al] else { return true }
                    return p - ap > noSameAlbumWithin
                }) { pick = ok }
            }
            let t = q.remove(at: pick)
            queues[chosen] = q
            result.append(t)
            lastPos[chosen] = p
            if let al = t.album { albumLastPos[al] = p }
        }
        return result
    }
}
