import Foundation

// MARK: - Query model

/// A comparator paired with a typed value, e.g. `duration > 300_000` (ms).
public struct ComparatorValue<T: Equatable & Sendable>: Equatable, Sendable {
    public var comparator: PredicateComparator
    public var value: T

    public init(comparator: PredicateComparator, value: T) {
        self.comparator = comparator
        self.value = value
    }
}

/// Result of parsing a raw query string like `artist:pink year:1990-1999 mid week`.
public struct ParsedQuery: Equatable, Sendable {
    public var artist: String?          // normalized substring filter
    public var genre: String?           // normalized substring filter
    public var yearRange: ClosedRange<Int>?
    public var duration: ComparatorValue<Int>?   // milliseconds
    public var rating: ComparatorValue<Int>?
    public var freeTerms: [String]      // normalized (non-tight) tokens, AND-matched

    public static let empty = ParsedQuery(artist: nil, genre: nil, yearRange: nil, duration: nil, rating: nil, freeTerms: [])
}

public struct ScoredTrack: Equatable, Sendable {
    public var track: Track
    public var score: Double
}

public enum GroupKey: Sendable {
    case artist, album, song
}

public struct SearchGroup: Sendable {
    public var key: String
    public var bestScore: Double
    public var tracks: [Track]
}

public struct SearchOutcome: Sendable {
    public var scored: [ScoredTrack]
    public var usedFuzzy: Bool
}

// MARK: - SearchIndex

/// Simple in-memory search over an array of tracks. Built once; the target
/// library is a few hundred tracks so a linear scan per query is
/// single-digit microseconds — no trigram index / mmap layout needed.
public final class SearchIndex {

    private struct FieldHaystack {
        let title: String
        let artist: String
        let albumArtist: String
        let album: String
        let genre: String
        let words: [String]
    }

    private struct SearchFrame {
        let normalizedQuery: String
        let matchedUUIDs: Set<UUID>
        /// False for frames produced via the fuzzy fallback — a later query
        /// that extends this one must NOT narrow from it (fuzzy matches
        /// aren't guaranteed to be a superset-safe base for substring AND).
        let narrowable: Bool
    }

    private let tracks: [Track]
    private let byUUID: [UUID: Track]
    private let haystacks: [UUID: FieldHaystack]
    private var stats: [UUID: TrackStats]
    private var frames: [SearchFrame] = []

    public init(tracks: [Track], stats: [UUID: TrackStats] = [:]) {
        self.tracks = tracks
        self.stats = stats
        var byUUID: [UUID: Track] = [:]
        var haystacks: [UUID: FieldHaystack] = [:]
        byUUID.reserveCapacity(tracks.count)
        haystacks.reserveCapacity(tracks.count)
        for t in tracks {
            byUUID[t.uuid] = t
            let title = Normalization.normalize(t.title)
            let artist = Normalization.normalize(t.artist ?? "")
            let albumArtist = Normalization.normalize(t.albumArtist ?? "")
            let album = Normalization.normalize(t.album ?? "")
            let genre = Normalization.normalize(t.genre ?? "")
            let words = [title, artist, albumArtist, album, genre]
                .flatMap { $0.split(separator: " ") }
                .map(String.init)
            haystacks[t.uuid] = FieldHaystack(title: title, artist: artist, albumArtist: albumArtist, album: album, genre: genre, words: words)
        }
        self.byUUID = byUUID
        self.haystacks = haystacks
    }

    /// Swap in fresh derived/local stats (play counts, ratings, bpm) without rebuilding the index.
    public func updateStats(_ stats: [UUID: TrackStats]) {
        self.stats = stats
    }

    /// Drops incremental-narrowing state. Correctness of `search` never
    /// depends on this; it only affects how much of the corpus a given call
    /// re-scans.
    public func resetSearchState() {
        frames.removeAll()
    }

    public var narrowingStackDepth: Int { frames.count }

    // MARK: Search

    public func search(_ rawQuery: String) -> SearchOutcome {
        let parsed = Self.parseQuery(rawQuery)
        let normalizedQueryString = Self.narrowingKey(for: parsed)

        let candidateUUIDs = candidateSpace(for: normalizedQueryString)

        var results: [ScoredTrack] = []
        var matchedUUIDs: Set<UUID> = []
        results.reserveCapacity(candidateUUIDs.count)
        for uuid in candidateUUIDs {
            guard let track = byUUID[uuid], let hay = haystacks[uuid] else { continue }
            let trackStats = stats[uuid] ?? .empty
            guard passesFilters(parsed, track: track, stats: trackStats) else { continue }
            guard let score = matchScore(parsed.freeTerms, hay: hay, stats: trackStats) else { continue }
            results.append(ScoredTrack(track: track, score: score))
            matchedUUIDs.insert(uuid)
        }

        var usedFuzzy = false
        var narrowable = true
        if results.count < 5, !parsed.freeTerms.isEmpty {
            usedFuzzy = true
            narrowable = false
            results.append(contentsOf: fuzzySearch(parsed, excluding: matchedUUIDs))
        }

        pushFrame(normalizedQuery: normalizedQueryString, matchedUUIDs: matchedUUIDs, narrowable: narrowable)

        results.sort { $0.score > $1.score }
        return SearchOutcome(scored: results, usedFuzzy: usedFuzzy)
    }

    /// Group already-scored results (e.g. from `search(_:).scored`) by
    /// artist/album/song. Groups are ranked by their best-scoring member;
    /// within a group, tracks are ordered by `descriptors` if given, else by
    /// score.
    public func grouped(_ scored: [ScoredTrack], by key: GroupKey, sortedBy descriptors: [SortDescriptor] = []) -> [SearchGroup] {
        var buckets: [String: [ScoredTrack]] = [:]
        var order: [String] = []
        for st in scored {
            let k = groupKeyString(for: st.track, key: key)
            if buckets[k] == nil {
                buckets[k] = []
                order.append(k)
            }
            buckets[k]!.append(st)
        }
        var groups = order.map { k -> SearchGroup in
            let items = buckets[k]!
            let best = items.map(\.score).max() ?? 0
            let trackList: [Track]
            if descriptors.isEmpty {
                trackList = items.sorted { $0.score > $1.score }.map(\.track)
            } else {
                trackList = SortEngine.sorted(items.map(\.track), stats: stats, by: descriptors)
            }
            return SearchGroup(key: k, bestScore: best, tracks: trackList)
        }
        groups.sort { $0.bestScore > $1.bestScore }
        return groups
    }

    private func groupKeyString(for track: Track, key: GroupKey) -> String {
        switch key {
        case .artist: return track.artist ?? ""
        case .album: return track.album ?? ""
        case .song: return track.title
        }
    }

    // MARK: Narrowing stack

    private func candidateSpace(for normalizedQuery: String) -> [UUID] {
        guard !normalizedQuery.isEmpty else { return tracks.map(\.uuid) }
        while let top = frames.last, !normalizedQuery.hasPrefix(top.normalizedQuery) {
            frames.removeLast()
        }
        if let top = frames.last, top.narrowable {
            return Array(top.matchedUUIDs)
        }
        return tracks.map(\.uuid)
    }

    private func pushFrame(normalizedQuery: String, matchedUUIDs: Set<UUID>, narrowable: Bool) {
        guard !normalizedQuery.isEmpty else { return }
        frames.append(SearchFrame(normalizedQuery: normalizedQuery, matchedUUIDs: matchedUUIDs, narrowable: narrowable))
    }

    private static func narrowingKey(for parsed: ParsedQuery) -> String {
        // The narrowing property (superset-safe restriction) holds for the
        // substring-AND-tokens matching rule. We key the stack off of the
        // exact normalized free-text query only: filters (artist/genre/year/
        // duration/rating) don't participate in substring narrowing and are
        // always re-evaluated per candidate regardless.
        parsed.freeTerms.joined(separator: " ")
    }

    // MARK: Filtering

    private func passesFilters(_ parsed: ParsedQuery, track: Track, stats: TrackStats) -> Bool {
        if let artist = parsed.artist, !artist.isEmpty {
            guard Normalization.normalize(track.artist ?? "").contains(artist) else { return false }
        }
        if let genre = parsed.genre, !genre.isEmpty {
            guard Normalization.normalize(track.genre ?? "").contains(genre) else { return false }
        }
        if let yearRange = parsed.yearRange {
            guard let year = track.year, yearRange.contains(year) else { return false }
        }
        if let duration = parsed.duration {
            guard Self.compareInt(track.durationMs, duration.comparator, duration.value) else { return false }
        }
        if let rating = parsed.rating {
            guard let r = stats.rating, Self.compareInt(r, rating.comparator, rating.value) else { return false }
        }
        return true
    }

    // MARK: Scoring

    private func matchScore(_ freeTerms: [String], hay: FieldHaystack, stats: TrackStats) -> Double? {
        let playBonus = 40.0 * log2(1.0 + Double(stats.playCount))
        guard !freeTerms.isEmpty else {
            return playBonus
        }

        let fields: [(text: String, weight: Double)] = [
            (hay.title, 3.0),
            (hay.artist, 2.5),
            (hay.albumArtist, 2.5),
            (hay.album, 1.5),
            (hay.genre, 1.0),
        ]

        var total = 0.0
        let joinedQuery = freeTerms.joined(separator: " ")
        if !joinedQuery.isEmpty {
            if hay.title == joinedQuery {
                total += 1000
            } else if hay.title.hasPrefix(joinedQuery) {
                total += 500
            }
        }

        for term in freeTerms {
            var bestFieldScore: Double?
            for (text, weight) in fields {
                guard let range = text.range(of: term) else { continue }
                let atBoundary = Self.isWordBoundary(text, range)
                let base = atBoundary ? 300.0 : 100.0
                let position = text.distance(from: text.startIndex, to: range.lowerBound)
                let positionBonus = max(0.0, 20.0 - Double(position))
                let fieldScore = (base + positionBonus) * weight
                bestFieldScore = max(bestFieldScore ?? 0, fieldScore)
            }
            guard let best = bestFieldScore else { return nil }
            total += best
        }

        return total + playBonus
    }

    private static func isWordBoundary(_ text: String, _ range: Range<String.Index>) -> Bool {
        guard range.lowerBound != text.startIndex else { return true }
        return text[text.index(before: range.lowerBound)] == " "
    }

    // MARK: Fuzzy fallback

    private func fuzzySearch(_ parsed: ParsedQuery, excluding: Set<UUID>) -> [ScoredTrack] {
        guard !parsed.freeTerms.isEmpty else { return [] }
        var results: [ScoredTrack] = []
        for track in tracks {
            guard !excluding.contains(track.uuid) else { continue }
            let trackStats = stats[track.uuid] ?? .empty
            guard passesFilters(parsed, track: track, stats: trackStats) else { continue }
            guard let hay = haystacks[track.uuid] else { continue }

            var scoreAccum = 0.0
            var allMatched = true
            for term in parsed.freeTerms {
                let maxDistance = term.count <= 5 ? 1 : 2
                var matchedWord = false
                for word in hay.words where !word.isEmpty {
                    if Self.boundedLevenshtein(term, word, maxDistance: maxDistance) != nil {
                        matchedWord = true
                        break
                    }
                }
                if !matchedWord {
                    allMatched = false
                    break
                }
                scoreAccum += 50.0 // flat fuzzy tier — below any exact substring hit.
            }
            guard allMatched else { continue }
            scoreAccum += 40.0 * log2(1.0 + Double(trackStats.playCount))
            results.append(ScoredTrack(track: track, score: scoreAccum))
        }
        return results
    }

    static func boundedLevenshtein(_ a: String, _ b: String, maxDistance: Int) -> Int? {
        let aChars = Array(a)
        let bChars = Array(b)
        if abs(aChars.count - bChars.count) > maxDistance { return nil }
        if aChars.isEmpty { return bChars.count <= maxDistance ? bChars.count : nil }
        if bChars.isEmpty { return aChars.count <= maxDistance ? aChars.count : nil }

        var previous = [Int](0...bChars.count)
        var current = [Int](repeating: 0, count: bChars.count + 1)

        for i in 1...aChars.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > maxDistance { return nil }
            previous = current
        }
        let dist = previous[bChars.count]
        return dist <= maxDistance ? dist : nil
    }

    // MARK: Query parsing (also used by SmartPlaylist for shared comparator/value parsing)

    public static func parseQuery(_ raw: String) -> ParsedQuery {
        var result = ParsedQuery.empty
        let rawTokens = raw.split(whereSeparator: { $0 == " " }).map(String.init)
        for rawToken in rawTokens {
            if let colonIdx = rawToken.firstIndex(of: ":") {
                let key = rawToken[rawToken.startIndex..<colonIdx].lowercased()
                let value = String(rawToken[rawToken.index(after: colonIdx)...])
                switch key {
                case "artist":
                    let n = Normalization.normalize(value)
                    if !n.isEmpty { result.artist = n; continue }
                case "genre":
                    let n = Normalization.normalize(value)
                    if !n.isEmpty { result.genre = n; continue }
                case "year":
                    if let range = parseYearRange(value) { result.yearRange = range; continue }
                case "duration":
                    let (cmp, rest) = extractComparator(value)
                    if let ms = parseDurationToMs(rest) { result.duration = ComparatorValue(comparator: cmp, value: ms); continue }
                case "rating":
                    let (cmp, rest) = extractComparator(value)
                    if let r = Int(rest) { result.rating = ComparatorValue(comparator: cmp, value: r); continue }
                default:
                    break
                }
            }
            let normalized = Normalization.normalize(rawToken)
            if !normalized.isEmpty {
                result.freeTerms.append(normalized)
            }
        }
        return result
    }

    static func extractComparator(_ value: String) -> (PredicateComparator, String) {
        if value.hasPrefix(">=") { return (.greaterThanOrEqual, String(value.dropFirst(2))) }
        if value.hasPrefix("<=") { return (.lessThanOrEqual, String(value.dropFirst(2))) }
        if value.hasPrefix("!=") { return (.notEquals, String(value.dropFirst(2))) }
        if value.hasPrefix(">") { return (.greaterThan, String(value.dropFirst(1))) }
        if value.hasPrefix("<") { return (.lessThan, String(value.dropFirst(1))) }
        if value.hasPrefix("=") { return (.equals, String(value.dropFirst(1))) }
        return (.equals, value)
    }

    static func parseDurationToMs(_ raw: String) -> Int? {
        guard !raw.isEmpty else { return nil }
        var s = raw
        var multiplier = 1000.0 // bare number => seconds
        if let last = s.last, last.isLetter {
            switch last {
            case "h": multiplier = 3_600_000
            case "m": multiplier = 60_000
            case "s": multiplier = 1000
            default: return nil
            }
            s.removeLast()
        }
        guard let magnitude = Double(s) else { return nil }
        return Int(magnitude * multiplier)
    }

    static func parseYearRange(_ raw: String) -> ClosedRange<Int>? {
        if raw.count > 1, let dashOffset = raw.dropFirst().firstIndex(of: "-") {
            let lo = String(raw[raw.startIndex..<dashOffset])
            let hi = String(raw[raw.index(after: dashOffset)...])
            guard let loInt = Int(lo), let hiInt = Int(hi), loInt <= hiInt else { return nil }
            return loInt...hiInt
        }
        guard let y = Int(raw) else { return nil }
        return y...y
    }

    static func compareInt(_ lhs: Int, _ cmp: PredicateComparator, _ rhs: Int) -> Bool {
        switch cmp {
        case .equals: return lhs == rhs
        case .notEquals: return lhs != rhs
        case .lessThan: return lhs < rhs
        case .lessThanOrEqual: return lhs <= rhs
        case .greaterThan: return lhs > rhs
        case .greaterThanOrEqual: return lhs >= rhs
        case .contains: return false
        }
    }
}
