import Testing
import Foundation
@testable import MusicboxCore

@Suite("PlayQueue")
struct PlayQueueTests {

    @Test("setContext makes the start track current and does not touch userQueue")
    func setContextBasics() {
        let a = makeTrack(index: 1, title: "a")
        let b = makeTrack(index: 2, title: "b")
        let c = makeTrack(index: 3, title: "c")

        var queue = PlayQueue()
        queue.setContext([a, b, c], startAt: 0)
        #expect(queue.currentTrack == a)
        #expect(queue.contextQueue.map(\.uuid) == [a, b, c].map(\.uuid))
    }

    @Test("userQueue survives a setContext (context change)")
    func userQueueSurvivesContextChange() {
        let a = makeTrack(index: 1, title: "a")
        let b = makeTrack(index: 2, title: "b")
        let x = makeTrack(index: 10, title: "x")
        let d = makeTrack(index: 20, title: "d")

        var queue = PlayQueue()
        queue.setContext([a, b], startAt: 0)
        queue.addToQueue(x)
        #expect(queue.userQueue.map(\.uuid) == [x.uuid])

        queue.setContext([d], startAt: 0)
        #expect(queue.userQueue.map(\.uuid) == [x.uuid], "userQueue must survive a context replacement")
        #expect(queue.currentTrack == d)
    }

    @Test("next() drains userQueue before the context queue")
    func nextDrainsUserQueueFirst() {
        let a = makeTrack(index: 1, title: "a")
        let b = makeTrack(index: 2, title: "b")
        let x = makeTrack(index: 10, title: "x")

        var queue = PlayQueue()
        queue.setContext([a, b], startAt: 0) // current = a
        queue.playNext(x) // userQueue = [x]

        let first = queue.next()
        #expect(first == x, "userQueue must drain before the context continues")
        #expect(queue.userQueue.isEmpty)

        let second = queue.next()
        #expect(second == b, "context resumes from its cursor (after a) once userQueue is empty")
    }

    @Test("playNext inserts at front, addToQueue appends at back")
    func playNextVsAddToQueue() {
        let x = makeTrack(index: 1, title: "x")
        let y = makeTrack(index: 2, title: "y")
        let z = makeTrack(index: 3, title: "z")

        var queue = PlayQueue()
        queue.addToQueue(x)
        queue.addToQueue(y)
        queue.playNext(z)
        #expect(queue.userQueue.map(\.uuid) == [z.uuid, x.uuid, y.uuid])
    }

    @Test("previous() walks history backwards")
    func previousWalksHistory() {
        let a = makeTrack(index: 1, title: "a")
        let b = makeTrack(index: 2, title: "b")
        let c = makeTrack(index: 3, title: "c")

        var queue = PlayQueue()
        queue.setContext([a, b, c], startAt: 0) // current = a
        _ = queue.next() // current = b, history = [a]
        _ = queue.next() // current = c, history = [a, b]

        #expect(queue.previous() == b)
        #expect(queue.previous() == a)
        #expect(queue.previous() == nil)
    }

    @Test("next() returns nil once both queues are exhausted")
    func nextExhausted() {
        let a = makeTrack(index: 1, title: "a")
        var queue = PlayQueue()
        queue.setContext([a], startAt: 0)
        #expect(queue.next() == nil)
        #expect(queue.next() == nil)
    }

    @Test("Codable snapshot round-trips")
    func codableRoundTrip() {
        let a = makeTrack(index: 1, title: "a")
        let b = makeTrack(index: 2, title: "b")
        let x = makeTrack(index: 10, title: "x")

        var queue = PlayQueue()
        queue.setContext([a, b], startAt: 0)
        queue.addToQueue(x)
        _ = queue.next()

        let data = try! JSONEncoder().encode(queue)
        let decoded = try! JSONDecoder().decode(PlayQueue.self, from: data)
        #expect(decoded == queue)
    }

    @Test("shuffleContext reshuffles only the context, keeping userQueue/history intact")
    func shuffleContextIsolated() {
        let tracks = generateCorpus(count: 30)
        let x = makeTrack(index: 999, title: "queued")

        var queue = PlayQueue()
        queue.setContext(tracks, startAt: 0)
        queue.addToQueue(x)
        _ = queue.next() // advance once so history is non-empty

        let userQueueBefore = queue.userQueue
        let historyBefore = queue.history

        queue.shuffleContext(seed: 777)

        #expect(queue.userQueue == userQueueBefore)
        #expect(queue.history == historyBefore)
        #expect(Set(queue.contextQueue.map(\.uuid)) == Set(tracks.map(\.uuid)))
    }
}
