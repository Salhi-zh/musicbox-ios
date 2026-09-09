import Testing
@testable import MusicboxCore

@Suite("SortEngine")
struct SortEngineTests {

    @Test("natural number order: single-digit before double-digit")
    func naturalOrderTrack() {
        let t2 = makeTrack(index: 1, title: "Track 2")
        let t10 = makeTrack(index: 2, title: "Track 10")
        let sorted = SortEngine.sorted([t10, t2], by: [SortDescriptor(field: .title)])
        #expect(sorted.map(\.title) == ["Track 2", "Track 10"])
    }

    @Test("natural number order: Part 9 before Part 10")
    func naturalOrderPart() {
        let p9 = makeTrack(index: 1, title: "Part 9")
        let p10 = makeTrack(index: 2, title: "Part 10")
        let p2 = makeTrack(index: 3, title: "Part 2")
        let sorted = SortEngine.sorted([p10, p2, p9], by: [SortDescriptor(field: .title)])
        #expect(sorted.map(\.title) == ["Part 2", "Part 9", "Part 10"])
    }

    @Test("natural order handles leading zeros consistently")
    func naturalOrderLeadingZeros() {
        let a = makeTrack(index: 1, title: "Track 007")
        let b = makeTrack(index: 2, title: "Track 7")
        let c = makeTrack(index: 3, title: "Track 8")
        let sorted = SortEngine.sorted([c, a, b], by: [SortDescriptor(field: .title)])
        // "007" and "7" both represent 7 — total order still resolves via the uuid tie-break.
        #expect(sorted.map(\.title).last == "Track 8")
        #expect(Set(sorted.prefix(2).map(\.title)) == ["Track 007", "Track 7"])
    }

    @Test("unicode: diacritics collate as their base letter")
    func unicodeCollation() {
        let air = makeTrack(index: 1, title: "x", artist: "Air")
        let bjork = makeTrack(index: 2, title: "x", artist: "Björk")
        let blur = makeTrack(index: 3, title: "x", artist: "Blur")
        let sorted = SortEngine.sorted([blur, bjork, air], by: [SortDescriptor(field: .artist)])
        #expect(sorted.map(\.artist) == ["Air", "Björk", "Blur"])
    }

    @Test("leading article strip changes collation order")
    func leadingArticleStrip() {
        let air = makeTrack(index: 1, title: "x", artist: "Air")
        let beatles = makeTrack(index: 2, title: "x", artist: "The Beatles")
        let blur = makeTrack(index: 3, title: "x", artist: "Blur")

        let unstripped = SortEngine.sorted([blur, beatles, air], by: [SortDescriptor(field: .artist, stripLeadingArticle: false)])
        #expect(unstripped.map(\.artist) == ["Air", "Blur", "The Beatles"])

        let stripped = SortEngine.sorted([blur, beatles, air], by: [SortDescriptor(field: .artist, stripLeadingArticle: true)])
        #expect(stripped.map(\.artist) == ["Air", "The Beatles", "Blur"])
    }

    @Test("stripping an article that would empty the string keeps the original")
    func leadingArticleStripKeepsWhenEmptied() {
        // Exercise the guard directly: "the " matches the article prefix,
        // but removing it leaves nothing — the original must be kept.
        #expect(SortEngine.stripLeadingArticle("the ") == "the ")
        // Normal case still strips.
        #expect(SortEngine.stripLeadingArticle("the beatles") == "beatles")
    }

    @Test("total order is stable across two independent builds")
    func stableAcrossRebuilds() {
        let tracks = generateCorpus(count: 60)
        let descriptors = [SortDescriptor(field: .artist), SortDescriptor(field: .album), SortDescriptor(field: .trackNo)]
        let first = SortEngine.sorted(tracks, by: descriptors).map(\.uuid)
        let second = SortEngine.sorted(tracks.shuffled(), by: descriptors).map(\.uuid)
        #expect(first == second)
    }

    @Test("ties are broken deterministically by uuid")
    func tieBreakByUUID() {
        // Two tracks with identical title (and thus identical primary key) —
        // the uuid suffix must produce a stable, deterministic order.
        let a = makeTrack(index: 5, title: "Same Title")
        let b = makeTrack(index: 1, title: "Same Title")
        let sorted1 = SortEngine.sorted([a, b], by: [SortDescriptor(field: .title)])
        let sorted2 = SortEngine.sorted([b, a], by: [SortDescriptor(field: .title)])
        #expect(sorted1.map(\.uuid) == sorted2.map(\.uuid))
    }

    @Test("descending direction reverses order")
    func descending() {
        let t2 = makeTrack(index: 1, title: "Track 2")
        let t10 = makeTrack(index: 2, title: "Track 10")
        let sorted = SortEngine.sorted([t2, t10], by: [SortDescriptor(field: .title, direction: .descending)])
        #expect(sorted.map(\.title) == ["Track 10", "Track 2"])
    }

    @Test("multi-level sort: primary then secondary")
    func multiLevelSort() {
        let a1 = makeTrack(index: 1, title: "x", artist: "Air", album: "Moon Safari", trackNo: 2)
        let a2 = makeTrack(index: 2, title: "x", artist: "Air", album: "Moon Safari", trackNo: 1)
        let b1 = makeTrack(index: 3, title: "x", artist: "Blur", album: "Leisure", trackNo: 1)
        let sorted = SortEngine.sorted([a1, b1, a2], by: [SortDescriptor(field: .artist), SortDescriptor(field: .trackNo)])
        #expect(sorted.map(\.uuid) == [a2.uuid, a1.uuid, b1.uuid])
    }

    @Test("nils sort last ascending on numeric fields")
    func nilsSortLastAscending() {
        let withYear = makeTrack(index: 1, title: "x", year: 1999)
        let noYear = makeTrack(index: 2, title: "y", year: nil)
        let sorted = SortEngine.sorted([noYear, withYear], by: [SortDescriptor(field: .year)])
        #expect(sorted.map(\.uuid) == [withYear.uuid, noYear.uuid])
    }

    // MARK: Shuffle

    @Test("seeded shuffle is deterministic")
    func deterministicShuffle() {
        let tracks = generateCorpus(count: 40)
        let a = SortEngine.shuffled(tracks, seed: 12345)
        let b = SortEngine.shuffled(tracks, seed: 12345)
        #expect(a.map(\.uuid) == b.map(\.uuid))
    }

    @Test("different seeds produce different orders")
    func differentSeedsDiffer() {
        let tracks = generateCorpus(count: 40)
        let a = SortEngine.shuffled(tracks, seed: 1)
        let b = SortEngine.shuffled(tracks, seed: 2)
        #expect(a.map(\.uuid) != b.map(\.uuid))
    }

    @Test("smart shuffle respects no-same-artist-within-N spacing")
    func smartShuffleSpacing() {
        var tracks: [Track] = []
        var idx = 0
        for artist in testArtistPool.prefix(6) {
            for n in 0..<5 {
                tracks.append(makeTrack(index: idx, title: "t\(n)", artist: artist))
                idx += 1
            }
        }
        let window = 3
        let shuffled = SortEngine.smartShuffle(tracks, seed: 7, noSameArtistWithin: window, noSameAlbumWithin: 0)
        #expect(shuffled.count == tracks.count)
        #expect(Set(shuffled.map(\.uuid)) == Set(tracks.map(\.uuid)))

        for i in shuffled.indices {
            let start = max(0, i - window)
            for j in start..<i {
                #expect(shuffled[j].artist != shuffled[i].artist)
            }
        }
    }
}
