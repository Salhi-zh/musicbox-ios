import Testing
@testable import MusicboxCore

@Suite("SearchIndex")
struct SearchIndexTests {

    @Test("results match a naive AND-substring scan across ~300 tracks and many queries")
    func propertyAgainstNaiveScan() {
        let tracks = generateCorpus(count: 300)
        let index = SearchIndex(tracks: tracks)

        var queries: [String] = []
        queries += testArtistPool
        queries += testAlbumPool
        queries += testGenrePool
        queries += testTitleWordPool
        queries += ["air moon", "daft punk", "the beatles", "kid a radiohead", "post-rock"]
        // Diacritic-insensitive forms of accented pool entries.
        queries += ["bjork", "sigur ros", "motley crue", "beyonce", "cafe tacvba", "royksopp"]
        queries += ["ELECTRONIC", "RaDioHeAd"]
        let extending = ["s", "si", "sig", "sigu", "sigur", "sigur r", "sigur ro"]

        for query in queries + extending {
            let freeTerms = query
                .split(separator: " ")
                .map { Normalization.normalize(String($0)) }
                .filter { !$0.isEmpty }
            let naiveSet = naiveMatch(tracks, freeTerms: freeTerms)
            let outcome = index.search(query)
            let resultSet = Set(outcome.scored.map { $0.track.uuid })

            #expect(naiveSet.isSubset(of: resultSet), "naive matches missing from SearchIndex for query '\(query)'")
            if naiveSet.count >= 5 {
                #expect(resultSet == naiveSet, "exact-match set diverges from naive scan for query '\(query)'")
                #expect(!outcome.usedFuzzy, "fuzzy fallback should not trigger with >=5 exact matches for '\(query)'")
            }
        }
    }

    @Test("narrowing a query that extends the previous exact query stays correct")
    func narrowingSequenceCorrectness() {
        let tracks = generateCorpus(count: 300)
        let index = SearchIndex(tracks: tracks)

        let sequence = ["e", "el", "ele", "elec", "electro", "electron", "electronic"]
        for query in sequence {
            let freeTerms = [Normalization.normalize(query)]
            let naiveSet = naiveMatch(tracks, freeTerms: freeTerms)
            let outcome = index.search(query)
            let resultSet = Set(outcome.scored.map { $0.track.uuid })
            if naiveSet.count >= 5 {
                #expect(resultSet == naiveSet)
            } else {
                #expect(naiveSet.isSubset(of: resultSet))
            }
        }
        #expect(index.narrowingStackDepth == sequence.count)
    }

    @Test("shrinking the query (backspacing) still produces correct results")
    func backspacingCorrectness() {
        let tracks = generateCorpus(count: 300)
        let index = SearchIndex(tracks: tracks)

        _ = index.search("electronic")
        _ = index.search("electro") // shorter — not a prefix-extension of "electronic"
        let outcome = index.search("electro")
        let freeTerms = [Normalization.normalize("electro")]
        let naiveSet = naiveMatch(tracks, freeTerms: freeTerms)
        let resultSet = Set(outcome.scored.map { $0.track.uuid })
        if naiveSet.count >= 5 {
            #expect(resultSet == naiveSet)
        } else {
            #expect(naiveSet.isSubset(of: resultSet))
        }
    }

    @Test("fuzzy fallback finds a near-miss typo when exact matches are scarce")
    func fuzzyFallback() {
        var tracks = generateCorpus(count: 40, seed: 99)
        let unique = makeTrack(index: 9001, title: "Serendipity Waltz", artist: "Unique Rarity")
        tracks.append(unique)
        let index = SearchIndex(tracks: tracks)

        let outcome = index.search("serendipitty") // one extra 't'
        #expect(outcome.usedFuzzy)
        #expect(outcome.scored.contains { $0.track.uuid == unique.uuid })
    }

    @Test("fuzzy fallback goes wide even when narrowing state exists")
    func fuzzyIsNonNarrowable() {
        var tracks = generateCorpus(count: 40, seed: 99)
        let unique = makeTrack(index: 9002, title: "Serendipity Waltz", artist: "Unique Rarity")
        tracks.append(unique)
        let index = SearchIndex(tracks: tracks)

        _ = index.search("serendipitty") // triggers fuzzy, frame marked non-narrowable
        // Extending the fuzzy query must not narrow from its (fuzzy) match set —
        // it should still find the exact-match track via a fresh full scan.
        let outcome = index.search("serendipitty waltz")
        #expect(outcome.scored.contains { $0.track.uuid == unique.uuid })
    }

    @Test("exact title match outranks a title-prefix match")
    func exactTitleOutranksPrefix() {
        let exact = makeTrack(index: 1, title: "Yesterday", artist: "The Beatles")
        let prefixOnly = makeTrack(index: 2, title: "Yesterday Once More", artist: "Carpenters")
        let filler = generateCorpus(count: 20, seed: 5)
        let index = SearchIndex(tracks: filler + [exact, prefixOnly])

        let outcome = index.search("yesterday")
        let exactScore = outcome.scored.first { $0.track.uuid == exact.uuid }?.score
        let prefixScore = outcome.scored.first { $0.track.uuid == prefixOnly.uuid }?.score
        #expect(exactScore != nil && prefixScore != nil)
        #expect(exactScore! > prefixScore!)
    }

    @Test("grouping ranks groups by best member and orders within a group by the given sort")
    func grouping() {
        let a1 = makeTrack(index: 1, title: "Air Song One", artist: "Air", album: "Moon Safari", trackNo: 2)
        let a2 = makeTrack(index: 2, title: "Air Song Two", artist: "Air", album: "Moon Safari", trackNo: 1)
        // Mid-word, non-prefix "air" hit — scores well below the Air group.
        let b1 = makeTrack(index: 3, title: "Debonair", artist: "Blur", album: "Leisure", trackNo: 1)
        let index = SearchIndex(tracks: [a1, b1, a2])

        let outcome = index.search("air")
        let groups = index.grouped(outcome.scored, by: .artist, sortedBy: [SortDescriptor(field: .trackNo)])
        #expect(groups.count == 2)
        #expect(groups.first?.key == "Air")
        let airGroup = groups.first { $0.key == "Air" }
        #expect(airGroup?.tracks.map(\.uuid) == [a2.uuid, a1.uuid])
    }

    @Test("play count contributes a scoring bonus")
    func playCountBonus() {
        let a = makeTrack(index: 1, title: "Repeat Track", artist: "Someone")
        let b = makeTrack(index: 2, title: "Repeat Track", artist: "Other One")
        let index = SearchIndex(tracks: [a, b], stats: [a.uuid: TrackStats(playCount: 50), b.uuid: TrackStats(playCount: 0)])

        let outcome = index.search("repeat track")
        let scoreA = outcome.scored.first { $0.track.uuid == a.uuid }?.score
        let scoreB = outcome.scored.first { $0.track.uuid == b.uuid }?.score
        #expect(scoreA != nil && scoreB != nil)
        #expect(scoreA! > scoreB!)
    }

    @Test("query filters: artist/year/genre/duration/rating")
    func filters() {
        let match = makeTrack(index: 1, title: "Filtered", artist: "Pink Something", year: 1997, genre: "Jazz", durationMs: 6 * 60_000)
        let wrongYear = makeTrack(index: 2, title: "Filtered", artist: "Pink Something", year: 2005, genre: "Jazz", durationMs: 6 * 60_000)
        let wrongArtist = makeTrack(index: 3, title: "Filtered", artist: "Someone Else", year: 1997, genre: "Jazz", durationMs: 6 * 60_000)
        let index = SearchIndex(
            tracks: [match, wrongYear, wrongArtist],
            stats: [match.uuid: TrackStats(rating: 5), wrongYear.uuid: TrackStats(rating: 5), wrongArtist.uuid: TrackStats(rating: 5)]
        )

        let byArtist = Set(index.search("artist:pink").scored.map(\.track.uuid))
        #expect(byArtist == [match.uuid, wrongYear.uuid])

        let byYear = Set(index.search("year:1990-1999").scored.map(\.track.uuid))
        #expect(byYear == [match.uuid, wrongArtist.uuid])

        let byDuration = Set(index.search("duration:>5m").scored.map(\.track.uuid))
        #expect(byDuration == [match.uuid, wrongYear.uuid, wrongArtist.uuid])

        let byRating = Set(index.search("rating:>=4").scored.map(\.track.uuid))
        #expect(byRating == [match.uuid, wrongYear.uuid, wrongArtist.uuid])

        let combined = index.search("artist:pink year:1990-1999").scored.map(\.track.uuid)
        #expect(combined == [match.uuid])
    }
}
