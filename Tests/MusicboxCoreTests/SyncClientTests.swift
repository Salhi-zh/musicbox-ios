import Foundation
import Testing
@testable import MusicboxCore

private struct FakeTransport: SyncTransport {
    let pages: [Int: SyncResponse] // keyed by "since"
    func fetchSync(since: Int) async throws -> SyncResponse {
        pages[since] ?? SyncResponse(rev: since, tracks: [], tombstones: [])
    }
}

@Suite("SyncClient")
struct SyncClientTests {

    @Test("applySync upserts tracks and applies tombstones")
    func upsertsAndTombstones() {
        let a = makeTrack(index: 1, title: "a", rev: 1)
        let b = makeTrack(index: 2, title: "b", rev: 1)

        var state = SyncState()
        let page1 = SyncResponse(rev: 1, tracks: [a, b], tombstones: [])
        #expect(SyncClient.applySync(page1, into: &state) == 1)
        #expect(Set(state.tracksByUUID.keys) == [a.uuid, b.uuid])

        // Page 2: update a, delete b.
        var aUpdated = a
        aUpdated.title = "a updated"
        aUpdated.rev = 2
        let page2 = SyncResponse(rev: 2, tracks: [aUpdated], tombstones: [Tombstone(uuid: b.uuid, rev: 2)])
        #expect(SyncClient.applySync(page2, into: &state) == 2)
        #expect(state.tracksByUUID[a.uuid]?.title == "a updated")
        #expect(state.tracksByUUID[b.uuid] == nil)
        #expect(state.rev == 2)
    }

    @Test("applySync rev only ever advances (max), never regresses")
    func revMonotonic() {
        var state = SyncState(rev: 10)
        let staleTrack = makeTrack(index: 1, title: "stale", rev: 3)
        let page = SyncResponse(rev: 3, tracks: [staleTrack], tombstones: [])
        SyncClient.applySync(page, into: &state)
        #expect(state.rev == 10)
    }

    @Test("syncAll pages through a fake transport until it stops advancing")
    func syncAllPagesThroughFakeTransport() async throws {
        let a = makeTrack(index: 1, title: "a", rev: 1)
        let b = makeTrack(index: 2, title: "b", rev: 2)
        let transport = FakeTransport(pages: [
            0: SyncResponse(rev: 1, tracks: [a], tombstones: []),
            1: SyncResponse(rev: 2, tracks: [b], tombstones: []),
            2: SyncResponse(rev: 2, tracks: [], tombstones: []), // no advancement -> stop
        ])
        var state = SyncState()
        try await SyncClient.syncAll(&state, transport: transport)
        #expect(state.rev == 2)
        #expect(Set(state.tracksByUUID.keys) == [a.uuid, b.uuid])
    }

    @Test("divergence hash detects a dropped delta")
    func divergenceHashDetectsDrift() {
        let a = makeTrack(index: 1, title: "a", rev: 1)
        let b = makeTrack(index: 2, title: "b", rev: 1)
        let c = makeTrack(index: 3, title: "c", rev: 1)

        var state = SyncState()
        SyncClient.applySync(SyncResponse(rev: 1, tracks: [a, b, c], tombstones: []), into: &state)
        let localHash = SyncClient.divergenceHash(state.tracks)

        // Server applied a further update to `b` that this client never
        // received (a dropped delta) — the server's authoritative hash now differs.
        var bUpdated = b
        bUpdated.title = "b updated"
        bUpdated.rev = 2
        var serverState = state
        serverState.tracksByUUID[b.uuid] = bUpdated
        let serverHash = SyncClient.divergenceHash(serverState.tracks)

        #expect(serverHash != localHash)

        var caught: SyncError?
        do {
            try SyncClient.verifyDivergence(state.tracks, expected: serverHash)
        } catch let error as SyncError {
            caught = error
        } catch {
            Issue.record("unexpected non-SyncError thrown: \(error)")
        }
        #expect(caught == .divergenceDetected(expected: serverHash, actual: localHash))

        // No drift: verifying against the hash that actually matches succeeds.
        #expect(throws: Never.self) {
            try SyncClient.verifyDivergence(state.tracks, expected: localHash)
        }
    }

    @Test("divergence hash is order-independent and deterministic")
    func divergenceHashDeterministic() {
        let a = makeTrack(index: 1, title: "a", rev: 1)
        let b = makeTrack(index: 2, title: "b", rev: 1)
        #expect(SyncClient.divergenceHash([a, b]) == SyncClient.divergenceHash([b, a]))
        #expect(SyncClient.divergenceHash([a, b]) == SyncClient.divergenceHash([a, b]))
    }

    @Test("play events merge as an append-only union, deduped by id")
    func playEventMergeDedupes() {
        let id1 = UUID()
        let id2 = UUID()
        let trackUUID = deterministicUUID(1)

        let existing = [PlayEvent(id: id1, trackUUID: trackUUID, playedAt: 100, msPlayed: 5000, completed: true, device: "phone")]
        let incoming = [
            PlayEvent(id: id1, trackUUID: trackUUID, playedAt: 100, msPlayed: 5000, completed: true, device: "phone"), // duplicate
            PlayEvent(id: id2, trackUUID: trackUUID, playedAt: 200, msPlayed: 3000, completed: false, device: "watch"),
        ]
        let merged = SyncClient.mergePlayEvents(existing, with: incoming)
        #expect(merged.count == 2)
        #expect(Set(merged.map(\.id)) == [id1, id2])
    }
}
