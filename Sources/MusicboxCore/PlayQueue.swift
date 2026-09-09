import Foundation

/// The three-part queue model:
///
/// - `contextQueue`: what you tapped ("play this album/playlist/search
///   result"). Replaceable wholesale via `setContext`.
/// - `userQueue`: explicit "play next" / "add to queue" — survives a context
///   change.
/// - `history`: tracks that have already played, most-recent last.
///
/// Play order: `userQueue` drains first (FIFO), then `contextQueue`
/// continues from its cursor. Replacing the context never touches
/// `userQueue`. Shuffling re-seeds only the context.
///
/// `setContext` immediately makes `tracks[startAt]` the current track (the
/// way tapping an album/song starts playback right away in a real player).
/// `next()` then advances past it — draining `userQueue` first, falling
/// back to `contextQueue` continuing from `contextCursor`.
public struct PlayQueue: Codable, Equatable, Sendable {
    public private(set) var contextQueue: [Track]
    /// Index into `contextQueue` of the track that is "current" from the
    /// context's point of view (nil = context is empty / not started).
    public private(set) var contextCursor: Int?
    public private(set) var userQueue: [Track]
    public private(set) var history: [Track]
    public private(set) var currentTrack: Track?
    public private(set) var shuffleSeed: UInt64?

    public init(
        contextQueue: [Track] = [],
        contextCursor: Int? = nil,
        userQueue: [Track] = [],
        history: [Track] = [],
        currentTrack: Track? = nil,
        shuffleSeed: UInt64? = nil
    ) {
        self.contextQueue = contextQueue
        self.contextCursor = contextCursor
        self.userQueue = userQueue
        self.history = history
        self.currentTrack = currentTrack
        self.shuffleSeed = shuffleSeed
    }

    // MARK: Context

    /// Replaces the context wholesale and makes `tracks[startAt]` current
    /// immediately. The old current track (if any) is pushed to `history`.
    /// `userQueue` is left completely untouched.
    public mutating func setContext(_ tracks: [Track], startAt index: Int = 0) {
        if let current = currentTrack {
            history.append(current)
        }
        contextQueue = tracks
        if tracks.isEmpty {
            contextCursor = nil
            currentTrack = nil
        } else {
            let clamped = min(max(index, 0), tracks.count - 1)
            contextCursor = clamped
            currentTrack = tracks[clamped]
        }
    }

    /// Re-seeds and shuffles only the context queue (userQueue/history
    /// untouched). The currently-playing context track (if any) is kept in
    /// place at the front so reshuffling mid-play doesn't yank it away.
    public mutating func shuffleContext(seed: UInt64) {
        shuffleSeed = seed
        let current = contextCursor.flatMap { contextQueue.indices.contains($0) ? contextQueue[$0] : nil }
        var shuffled = SortEngine.shuffled(contextQueue, seed: seed)
        if let current, let newIndex = shuffled.firstIndex(of: current) {
            shuffled.remove(at: newIndex)
            shuffled.insert(current, at: 0)
            contextQueue = shuffled
            contextCursor = 0
        } else {
            contextQueue = shuffled
            contextCursor = shuffled.isEmpty ? nil : 0
        }
    }

    // MARK: User queue

    /// Insert at the FRONT of the user queue — plays immediately after the current track.
    public mutating func playNext(_ track: Track) {
        userQueue.insert(track, at: 0)
    }

    /// Append at the END of the user queue.
    public mutating func addToQueue(_ track: Track) {
        userQueue.append(track)
    }

    // MARK: Advancing

    /// userQueue drains first (FIFO); once empty, the context queue
    /// continues from `contextCursor`. Returns nil once both are exhausted.
    @discardableResult
    public mutating func next() -> Track? {
        if !userQueue.isEmpty {
            let track = userQueue.removeFirst()
            if let current = currentTrack { history.append(current) }
            currentTrack = track
            return track
        }
        guard !contextQueue.isEmpty else {
            if let current = currentTrack { history.append(current) }
            currentTrack = nil
            return nil
        }
        let nextCursor = (contextCursor ?? -1) + 1
        guard contextQueue.indices.contains(nextCursor) else {
            if let current = currentTrack { history.append(current) }
            currentTrack = nil
            contextCursor = contextQueue.count // parked past the end
            return nil
        }
        if let current = currentTrack { history.append(current) }
        contextCursor = nextCursor
        currentTrack = contextQueue[nextCursor]
        return currentTrack
    }

    /// Walks `history` backwards, making the popped entry current. Does not
    /// rewind `contextCursor` / re-enqueue anything into `userQueue` — it is
    /// a plain "go back to what played before" stack, not an undo of `next()`.
    @discardableResult
    public mutating func previous() -> Track? {
        guard let track = history.popLast() else { return nil }
        currentTrack = track
        return track
    }

    enum CodingKeys: String, CodingKey {
        case contextQueue, contextCursor, userQueue, history, currentTrack, shuffleSeed
    }
}
