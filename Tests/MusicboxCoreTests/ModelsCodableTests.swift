import Foundation
import Testing
@testable import MusicboxCore

@Suite("Models Codable")
struct ModelsCodableTests {

    static let sampleSyncJSON = """
    {
      "rev": 42,
      "tracks": [
        {
          "uuid": "11111111-1111-4111-8111-111111111111",
          "title": "Track One",
          "artist": "Artist A",
          "album_artist": "Artist A",
          "album": "Album X",
          "track_no": 3,
          "disc_no": 1,
          "year": 2001,
          "genre": "Rock",
          "duration_ms": 215000,
          "codec": "flac",
          "samplerate": 44100,
          "channels": 2,
          "bitrate": 900,
          "file_size": 12345678,
          "sha256": "abc123",
          "rg_track_gain": -6.5,
          "rg_track_peak": 0.98,
          "yt_video_id": null,
          "source_url": null,
          "added_at": 1700000000,
          "modified_at": 1700000100,
          "rev": 10
        },
        {
          "uuid": "22222222-2222-4222-8222-222222222222",
          "title": "Track Two",
          "duration_ms": 180000,
          "codec": "mp3",
          "file_size": 5000000,
          "sha256": "def456",
          "added_at": 1700000200,
          "modified_at": 1700000200,
          "rev": 11
        }
      ],
      "tombstones": [
        {"uuid": "33333333-3333-4333-8333-333333333333", "rev": 12}
      ]
    }
    """

    @Test("decodes the sample sync payload, including optional fields absent entirely")
    func decodeSampleSyncPayload() throws {
        let data = Self.sampleSyncJSON.data(using: .utf8)!
        let response = try JSONDecoder().decode(SyncResponse.self, from: data)

        #expect(response.rev == 42)
        #expect(response.tracks.count == 2)
        #expect(response.tombstones.count == 1)
        #expect(response.tombstones[0].rev == 12)

        let t1 = response.tracks[0]
        #expect(t1.title == "Track One")
        #expect(t1.artist == "Artist A")
        #expect(t1.albumArtist == "Artist A")
        #expect(t1.trackNo == 3)
        #expect(t1.discNo == 1)
        #expect(t1.year == 2001)
        #expect(t1.rgTrackGain == -6.5)
        #expect(t1.rgTrackPeak == 0.98)
        #expect(t1.ytVideoId == nil)
        #expect(t1.rev == 10)

        // Second track omits most optional keys entirely (not just `null`).
        let t2 = response.tracks[1]
        #expect(t2.title == "Track Two")
        #expect(t2.artist == nil)
        #expect(t2.albumArtist == nil)
        #expect(t2.album == nil)
        #expect(t2.trackNo == nil)
        #expect(t2.discNo == nil)
        #expect(t2.year == nil)
        #expect(t2.genre == nil)
        #expect(t2.samplerate == nil)
        #expect(t2.channels == nil)
        #expect(t2.bitrate == nil)
        #expect(t2.rgTrackGain == nil)
        #expect(t2.rgTrackPeak == nil)
        #expect(t2.ytVideoId == nil)
        #expect(t2.sourceUrl == nil)
        #expect(t2.durationMs == 180_000)
        #expect(t2.codec == "mp3")
        #expect(t2.fileSize == 5_000_000)
        #expect(t2.sha256 == "def456")

        // Round-trip: encode back to JSON, decode again, must be identical.
        let encoded = try JSONEncoder().encode(response)
        let decodedAgain = try JSONDecoder().decode(SyncResponse.self, from: encoded)
        #expect(decodedAgain == response)
    }

    @Test("Track encodes using the exact snake_case wire keys")
    func codingKeysSnakeCase() throws {
        let track = makeTrack(index: 1, title: "x", artist: "y", album: "z", trackNo: 1, discNo: 1, year: 2000, genre: "g")
        let data = try JSONEncoder().encode(track)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let expectedKeys = [
            "uuid", "title", "artist", "album_artist", "album", "track_no", "disc_no",
            "year", "genre", "duration_ms", "codec", "samplerate", "channels", "bitrate",
            "file_size", "sha256", "added_at", "modified_at", "rev",
        ]
        for key in expectedKeys {
            #expect(obj[key] != nil, "missing expected snake_case key: \(key)")
        }
    }

    @Test("PlayEvent encodes using snake_case keys")
    func playEventSnakeCase() throws {
        let event = PlayEvent(id: UUID(), trackUUID: UUID(), playedAt: 1, msPlayed: 2, completed: true, device: "phone")
        let data = try JSONEncoder().encode(event)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["track_uuid"] != nil)
        #expect(obj["played_at"] != nil)
        #expect(obj["ms_played"] != nil)
    }
}
