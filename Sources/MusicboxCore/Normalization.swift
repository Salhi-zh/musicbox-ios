import Foundation

/// Pure text-normalization helpers shared by search, sort, and smart
/// playlists. No dependency on anything but Foundation's Unicode-normalized
/// string APIs (`decomposedStringWithCompatibilityMapping`, etc.), which
/// exist in swift-corelibs-foundation on Linux.
public enum Normalization {

    /// Codepoints that Unicode's own NFKD decomposition does *not* break
    /// into base + combining mark, so they survive step 2 unless folded
    /// explicitly. Applied after lowercasing.
    private static let foldMap: [Character: String] = [
        "ß": "ss",
        "æ": "ae",
        "ø": "o",
        "ł": "l",
        "đ": "d",
        "þ": "th",
        "ð": "d",
    ]

    /// `NFKD → strip combining marks → NFKC → lowercase → fold non-decomposing
    /// special chars → (NFKC already folded full-width→half-width) → collapse
    /// whitespace.`
    public static func normalize(_ input: String) -> String {
        guard !input.isEmpty else { return input }

        // 1. NFKD (compatibility decomposition).
        let decomposed = input.decomposedStringWithCompatibilityMapping

        // 2. Strip combining marks (Unicode general category Mn).
        var stripped = String.UnicodeScalarView()
        stripped.reserveCapacity(decomposed.unicodeScalars.count)
        for scalar in decomposed.unicodeScalars {
            if scalar.properties.generalCategory == .nonspacingMark {
                continue
            }
            stripped.append(scalar)
        }
        let strippedString = String(stripped)

        // 3. NFKC (also folds full-width → half-width forms).
        let recomposed = strippedString.precomposedStringWithCompatibilityMapping

        // 4. Lowercase.
        let lowered = recomposed.lowercased()

        // 5. Fold characters NFKD doesn't decompose.
        var folded = ""
        folded.reserveCapacity(lowered.count)
        for ch in lowered {
            if let replacement = foldMap[ch] {
                folded += replacement
            } else {
                folded.append(ch)
            }
        }

        // 6. Collapse whitespace runs to a single space, trim ends.
        return collapseWhitespace(folded)
    }

    /// `normalize(_:)` further stripped of everything that isn't a letter or
    /// digit, so punctuation-insensitive matches work (`dont` ~ `Don't`).
    public static func tight(_ input: String) -> String {
        let normalized = normalize(input)
        var result = ""
        result.reserveCapacity(normalized.count)
        for scalar in normalized.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func collapseWhitespace(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        var lastWasSpace = false
        for ch in input {
            if ch.isWhitespace {
                if !lastWasSpace {
                    result.append(" ")
                }
                lastWasSpace = true
            } else {
                result.append(ch)
                lastWasSpace = false
            }
        }
        if result.hasPrefix(" ") {
            result.removeFirst()
        }
        if result.hasSuffix(" ") {
            result.removeLast()
        }
        return result
    }
}
