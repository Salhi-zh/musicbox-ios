import Foundation
@testable import MusicboxCore

/// Deterministic UUID from an integer index — keeps generated corpora and
/// their expected orderings fully reproducible across runs/machines.
func deterministicUUID(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
}

func makeTrack(
    index: Int,
    title: String,
    artist: String? = nil,
    albumArtist: String? = nil,
    album: String? = nil,
    trackNo: Int? = nil,
    discNo: Int? = nil,
    year: Int? = nil,
    genre: String? = nil,
    durationMs: Int = 200_000,
    bitrate: Int? = 1000,
    fileSize: Int = 10_000_000,
    addedAt: Int = 1_700_000_000,
    modifiedAt: Int = 1_700_000_000,
    rev: Int = 1
) -> Track {
    Track(
        uuid: deterministicUUID(index),
        title: title,
        artist: artist,
        albumArtist: albumArtist ?? artist,
        album: album,
        trackNo: trackNo,
        discNo: discNo,
        year: year,
        genre: genre,
        durationMs: durationMs,
        codec: "flac",
        samplerate: 44_100,
        channels: 2,
        bitrate: bitrate,
        fileSize: fileSize,
        sha256: String(format: "%064x", index),
        rgTrackGain: nil,
        rgTrackPeak: nil,
        ytVideoId: nil,
        sourceUrl: nil,
        addedAt: addedAt,
        modifiedAt: modifiedAt,
        rev: rev
    )
}

let testArtistPool = [
    "Björk", "Sigur Rós", "Mötley Crüe", "Beyoncé", "Café Tacvba", "Röyksopp",
    "The Beatles", "Radiohead", "Daft Punk", "Kraftwerk", "Nirvana",
    "Aphex Twin", "Portishead", "Massive Attack", "Air", "Deerhunter",
    "Tame Impala", "Boards of Canada",
]

let testAlbumPool = [
    "Homework", "Kid A", "In Rainbows", "OK Computer", "Vespertine",
    "Ágætis byrjun", "Discovery", "Nevermind", "Dummy", "Mezzanine",
    "Moon Safari", "Music Has the Right to Children", "Currents",
    "Selected Ambient Works",
]

let testGenrePool = [
    "Electronic", "Rock", "Ambient", "Trip-Hop", "Alternative", "Pop",
    "Post-Rock", "Grunge", "Jazz", "Classical",
]

let testTitleWordPool = [
    "Part", "Track", "Song", "Interlude", "Theme", "Reprise", "Intro",
    "Outro", "Movement", "Sketch",
]

/// A ~300-track synthetic corpus, fully deterministic given `seed`.
func generateCorpus(count: Int = 300, seed: UInt64 = 42) -> [Track] {
    var rng = SeededGenerator(seed: seed)
    var tracks: [Track] = []
    tracks.reserveCapacity(count)
    for i in 0..<count {
        let artist = testArtistPool[Int.random(in: 0..<testArtistPool.count, using: &rng)]
        let album = testAlbumPool[Int.random(in: 0..<testAlbumPool.count, using: &rng)]
        let genre = testGenrePool[Int.random(in: 0..<testGenrePool.count, using: &rng)]
        let word = testTitleWordPool[Int.random(in: 0..<testTitleWordPool.count, using: &rng)]
        let trackNo = Int.random(in: 1...20, using: &rng)
        let title = "\(word) \(trackNo)"
        let year = Int.random(in: 1990...2023, using: &rng)
        let durationMs = Int.random(in: 60_000...480_000, using: &rng)
        tracks.append(makeTrack(
            index: i,
            title: title,
            artist: artist,
            album: album,
            trackNo: trackNo,
            year: year,
            genre: genre,
            durationMs: durationMs
        ))
    }
    return tracks
}

/// Naive reference implementation of the free-term AND-substring match rule,
/// independent of `SearchIndex`'s internals — used to property-test
/// `SearchIndex` against.
func naiveMatch(_ tracks: [Track], freeTerms: [String]) -> Set<UUID> {
    guard !freeTerms.isEmpty else {
        return Set(tracks.map(\.uuid))
    }
    var result: Set<UUID> = []
    for track in tracks {
        let haystack = [track.title, track.artist ?? "", track.albumArtist ?? "", track.album ?? "", track.genre ?? ""]
            .map(Normalization.normalize)
            .joined(separator: " ")
        if freeTerms.allSatisfy({ haystack.contains($0) }) {
            result.insert(track.uuid)
        }
    }
    return result
}
