import Foundation

/// Evaluates `SmartPlaylistRule`s over the same predicate vocabulary
/// (`PredicateField` / `PredicateComparator`) that `SearchIndex` filters and
/// `SortEngine` sort keys use, so a rule like
/// `played < 3 AND added > 30d AND genre = electronic` reads consistently
/// everywhere in the app.
public enum SmartPlaylist {

    /// Filters `tracks` to those matching ALL of `rule.conditions`, then
    /// applies `rule.sort` and `rule.limit`.
    public static func evaluate(
        _ rule: SmartPlaylistRule,
        tracks: [Track],
        stats: [UUID: TrackStats] = [:],
        now: Date = Date()
    ) -> [Track] {
        let matched = tracks.filter { track in
            let trackStats = stats[track.uuid] ?? .empty
            return rule.conditions.allSatisfy { matches($0, track: track, stats: trackStats, now: now) }
        }
        let ordered = rule.sort.isEmpty ? matched : SortEngine.sorted(matched, stats: stats, by: rule.sort)
        guard let limit = rule.limit, limit >= 0, limit < ordered.count else {
            return ordered
        }
        return Array(ordered.prefix(limit))
    }

    static func matches(_ condition: SmartPlaylistCondition, track: Track, stats: TrackStats, now: Date) -> Bool {
        switch condition.field {
        case .title: return stringMatch(track.title, condition)
        case .artist: return stringMatch(track.artist ?? "", condition)
        case .albumArtist: return stringMatch(track.albumArtist ?? "", condition)
        case .album: return stringMatch(track.album ?? "", condition)
        case .genre: return stringMatch(track.genre ?? "", condition)
        case .codec: return stringMatch(track.codec, condition)
        case .year: return intMatch(track.year, condition)
        case .trackNo: return intMatch(track.trackNo, condition)
        case .discNo: return intMatch(track.discNo, condition)
        case .duration: return durationMatch(track.durationMs, condition)
        case .fileSize: return intMatch(track.fileSize, condition)
        case .bitrate: return intMatch(track.bitrate, condition)
        case .playCount: return intMatch(stats.playCount, condition)
        case .rating: return intMatch(stats.rating, condition)
        case .bpm: return doubleMatch(stats.bpm, condition)
        case .added: return ageMatch(track.addedAt, condition, now: now)
        case .modified: return ageMatch(track.modifiedAt, condition, now: now)
        }
    }

    private static func stringMatch(_ text: String, _ condition: SmartPlaylistCondition) -> Bool {
        let normalizedText = Normalization.normalize(text)
        let normalizedValue = Normalization.normalize(condition.value)
        switch condition.comparator {
        case .equals: return normalizedText == normalizedValue
        case .notEquals: return normalizedText != normalizedValue
        case .contains: return normalizedText.contains(normalizedValue)
        case .lessThan: return normalizedText < normalizedValue
        case .lessThanOrEqual: return normalizedText <= normalizedValue
        case .greaterThan: return normalizedText > normalizedValue
        case .greaterThanOrEqual: return normalizedText >= normalizedValue
        }
    }

    private static func intMatch(_ fieldValue: Int?, _ condition: SmartPlaylistCondition) -> Bool {
        guard let fieldValue, let target = Int(condition.value) else { return false }
        return SearchIndex.compareInt(fieldValue, condition.comparator, target)
    }

    private static func doubleMatch(_ fieldValue: Double?, _ condition: SmartPlaylistCondition) -> Bool {
        guard let fieldValue, let target = Double(condition.value) else { return false }
        return compareDouble(fieldValue, condition.comparator, target)
    }

    private static func durationMatch(_ ms: Int, _ condition: SmartPlaylistCondition) -> Bool {
        guard let targetMs = SearchIndex.parseDurationToMs(condition.value) else { return false }
        return SearchIndex.compareInt(ms, condition.comparator, targetMs)
    }

    /// `added` / `modified`: a value ending in `d`/`w`/`h` (days/weeks/hours)
    /// is an AGE threshold — `added > 30d` means "added more than 30 days
    /// ago". A bare integer is compared as an absolute epoch-seconds value.
    private static func ageMatch(_ epochSeconds: Int, _ condition: SmartPlaylistCondition, now: Date) -> Bool {
        let value = condition.value
        if let last = value.last, "dwh".contains(last), let magnitude = Double(value.dropLast()) {
            let unitSeconds: Double
            switch last {
            case "d": unitSeconds = 86_400
            case "w": unitSeconds = 604_800
            default: unitSeconds = 3_600
            }
            let thresholdSeconds = magnitude * unitSeconds
            let age = now.timeIntervalSince1970 - Double(epochSeconds)
            return compareDouble(age, condition.comparator, thresholdSeconds)
        }
        guard let absolute = Int(value) else { return false }
        return SearchIndex.compareInt(epochSeconds, condition.comparator, absolute)
    }

    private static func compareDouble(_ lhs: Double, _ cmp: PredicateComparator, _ rhs: Double) -> Bool {
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

    // MARK: Textual rule parsing ("played < 3 AND added > 30d AND genre = electronic")

    private static let fieldAliases: [String: PredicateField] = [
        "title": .title,
        "artist": .artist,
        "albumartist": .albumArtist,
        "album_artist": .albumArtist,
        "album": .album,
        "genre": .genre,
        "year": .year,
        "trackno": .trackNo,
        "track_no": .trackNo,
        "discno": .discNo,
        "disc_no": .discNo,
        "duration": .duration,
        "added": .added,
        "modified": .modified,
        "played": .playCount,
        "playcount": .playCount,
        "play_count": .playCount,
        "rating": .rating,
        "bpm": .bpm,
        "filesize": .fileSize,
        "file_size": .fileSize,
        "bitrate": .bitrate,
        "codec": .codec,
    ]

    /// Parses `"field comparator value"` clauses joined by `AND` (case-insensitive).
    /// Unparseable clauses are skipped. Comparators are matched longest-first
    /// (`>=`/`<=`/`!=` before `>`/`<`/`=`) so they aren't chopped mid-token.
    public static func parseRule(_ text: String) -> [SmartPlaylistCondition] {
        let clauses = splitOnWord(text, word: "AND")
        return clauses.compactMap(parseCondition)
    }

    private static func splitOnWord(_ text: String, word: String) -> [String] {
        let upperWord = word.uppercased()
        let tokens = text.split(separator: " ").map(String.init)
        var clauses: [[String]] = [[]]
        for token in tokens {
            if token.uppercased() == upperWord {
                clauses.append([])
            } else {
                clauses[clauses.count - 1].append(token)
            }
        }
        return clauses.map { $0.joined(separator: " ") }.filter { !$0.isEmpty }
    }

    private static func parseCondition(_ clause: String) -> SmartPlaylistCondition? {
        let trimmed = clause.trimmingCharacters(in: .whitespaces)
        let comparatorTokens: [(String, PredicateComparator)] = [
            (">=", .greaterThanOrEqual),
            ("<=", .lessThanOrEqual),
            ("!=", .notEquals),
            (">", .greaterThan),
            ("<", .lessThan),
            ("=", .equals),
        ]
        for (token, comparator) in comparatorTokens {
            if let range = trimmed.range(of: token) {
                let fieldText = trimmed[trimmed.startIndex..<range.lowerBound]
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                let valueText = trimmed[range.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
                guard !fieldText.isEmpty, !valueText.isEmpty, let field = fieldAliases[fieldText] else { continue }
                return SmartPlaylistCondition(field: field, comparator: comparator, value: valueText)
            }
        }
        return nil
    }
}
