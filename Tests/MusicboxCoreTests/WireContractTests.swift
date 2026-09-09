import Testing
import Foundation
@testable import MusicboxCore

/// Guards the Python Librarian ↔ Swift client wire contract. The JSON below is
/// captured verbatim from a real `GET /v1/sync?since=0` response. If either side
/// drifts (a renamed field, a timestamp reverting to an ISO string, a non-null
/// where the client expects null), this decode fails — catching the break here
/// on Linux instead of at runtime on the phone.
@Suite("Wire contract (real server payload)")
struct WireContractTests {

    static let realSyncJSON = """
    {
      "rev": 4,
      "tracks": [
        {
          "uuid": "d2d3b5ac-1a5e-4dbe-80c5-0f6e799f4595",
          "title": "Official Blender Foundation Short Film",
          "artist": "Big Buck Bunny 60fps 4K",
          "album_artist": "Big Buck Bunny 60fps 4K",
          "album": "Official Blender Foundation Short Film",
          "track_no": null,
          "disc_no": null,
          "year": 2014,
          "genre": null,
          "duration_ms": 634601,
          "codec": "opus",
          "samplerate": 48000,
          "channels": 2,
          "bitrate": 126780,
          "file_size": 10250949,
          "sha256": "b9f3ecb725afaccbf102b758b1da52986f3ebb767b72c5795defc29831555f63",
          "rg_track_gain": 0.75,
          "rg_track_peak": 1.243083,
          "yt_video_id": "aqz-KE-bpKQ",
          "source_url": "https://www.youtube.com/watch?v=aqz-KE-bpKQ",
          "added_at": 1788893076,
          "modified_at": 1788894568,
          "rev": 4
        }
      ],
      "tombstones": []
    }
    """

    @Test("real /v1/sync payload decodes and round-trips")
    func decodesRealPayload() throws {
        let data = Data(Self.realSyncJSON.utf8)
        let resp = try JSONDecoder().decode(SyncResponse.self, from: data)

        #expect(resp.rev == 4)
        #expect(resp.tracks.count == 1)
        #expect(resp.tombstones.isEmpty)

        let t = resp.tracks[0]
        #expect(t.year == 2014)
        #expect(t.addedAt == 1788893076)      // must be an Int epoch, not an ISO string
        #expect(t.modifiedAt == 1788894568)
        #expect(t.durationMs == 634601)

        // Re-encode and decode again; the model must be a faithful mirror.
        let again = try JSONDecoder().decode(SyncResponse.self,
                                             from: try JSONEncoder().encode(resp))
        #expect(again == resp)
    }
}
