import Foundation

/// Turns messy YouTube-ripped titles/filenames into a best-guess (artist, title).
///
/// Deliberately lightweight — embedded tags are used when present, otherwise the
/// filename is cleaned: junk-only brackets are stripped (`[Official Video]`,
/// `(Lyrics)`, `[HD]`…) while meaningful ones are kept (`(feat. …)`,
/// `(Slowed & Reverb)`, `(Remix)`, `(Prod. …)`), then split on " - ".
enum TitleCleaner {
    struct Result {
        let title: String
        let artist: String?
        let album: String?
    }

    /// Bracketed segments whose inner text contains any of these are dropped.
    private static let junkKeywords: [String] = [
        "official video", "official music video", "music video", "lyric video",
        "lyrics video", "official audio", "official lyric", "official", "lyrics",
        "lyric", "audio only", "audio", "visualizer", "visualiser", "hd", "hq",
        "4k", "8k", "m/v", "mv", "clip officiel", "clip official", "official clip",
        "free download", "out now", "explicit", "remaster", "remastered",
        "video oficial", "videoclip", "exclusive music video", "prod",
    ]

    static func clean(embeddedTitle: String?, embeddedArtist: String?, filename: String) -> Result {
        let raw = firstNonEmpty(embeddedTitle, filename.replacingOccurrences(of: "_", with: " "))
        let working = collapseSpaces(stripJunkBrackets(raw))

        var artist = trimmedNonEmpty(embeddedArtist)
        var title = working

        if let (a, t) = splitArtistTitle(working) {
            if artist == nil {
                artist = a
                title = t
            } else if a.compare(artist!, options: .caseInsensitive) == .orderedSame {
                // Title still carries the duplicated "Artist - " prefix; drop it.
                title = t
            }
        }

        title = collapseSpaces(title)
        if title.isEmpty { title = collapseSpaces(raw) }
        return Result(title: title, artist: artist, album: nil)
    }

    // MARK: Helpers

    private static func splitArtistTitle(_ s: String) -> (String, String)? {
        for sep in [" - ", " – ", " — ", " ‐ ", " ― "] {
            if let r = s.range(of: sep) {
                let a = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let t = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !a.isEmpty, !t.isEmpty { return (a, t) }
            }
        }
        return nil
    }

    private static func stripJunkBrackets(_ s: String) -> String {
        var out = s as NSString
        let patterns = ["\\[[^\\]]*\\]", "\\([^\\)]*\\)", "\\{[^\\}]*\\}"]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let matches = re.matches(in: out as String, range: NSRange(location: 0, length: out.length))
            for m in matches.reversed() {
                let inner = out.substring(with: m.range).lowercased()
                if junkKeywords.contains(where: { inner.contains($0) }) {
                    out = out.replacingCharacters(in: m.range, with: "") as NSString
                }
            }
        }
        return out as String
    }

    private static func collapseSpaces(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " -–—_·|"))
    }

    private static func trimmedNonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func firstNonEmpty(_ a: String?, _ b: String) -> String {
        if let a = a?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty { return a }
        return b
    }
}
