import Foundation
import Combine
import AVFoundation
import MediaPlayer
import MusicboxCore

/// A MINIMAL single-track player built on `AVAudioEngine` + `AVAudioPlayerNode`.
///
/// It plays a LOCAL file (resolved from `LocalLibraryService`) via `AVAudioFile`.
/// This is intentionally the simplest thing that plays one track well: queue
/// advance, audio-session correctness, and seek — but still no gapless, no
/// crossfade, no ReplayGain DSP.
///
/// FUTURE (the real engine): replace the internals of `loadAndPlay` with a
/// decoder feeding a PCM ring buffer that schedules buffers on the player
/// node, giving gapless playback, crossfade, and ReplayGain. The UI depends
/// ONLY on the published `currentTrack` / `isPlaying` and the play/pause/
/// next/previous/seek API below.
@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var currentTrack: Track?
    @Published private(set) var isPlaying = false
    @Published var lastError: String?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let library: LocalLibraryService

    private var didConfigureSession = false
    private var didConfigureRemoteCommands = false
    private var didObserveNotifications = false

    /// Retained for the lifetime of playback: `scheduleSegment` reads from
    /// this lazily during rendering, so it must outlive `loadAndPlay`.
    private var currentFile: AVAudioFile?

    /// The queue engine: context (what you tapped) + user "play next"/"add to
    /// queue" + history. `AudioPlayer` owns exactly one `PlayQueue` and drives
    /// it from `next()`/`previous()`/`handlePlaybackFinished()`.
    private var queue = PlayQueue()

    /// Frame (in the current file's own sample rate) that the current
    /// schedule started from. `AVAudioPlayerNode.stop()` resets the node's
    /// own sampleTime to 0, so elapsed-time math has to add this back in.
    private var seekBaseFrame: AVAudioFramePosition = 0

    /// Ticks ~1s while playing so the lock-screen scrubber tracks position.
    private var elapsedTimer: Timer?

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?

    init(library: LocalLibraryService) {
        self.library = library
        engine.attach(playerNode)
    }

    deinit {
        elapsedTimer?.invalidate()
        let center = NotificationCenter.default
        if let o = interruptionObserver { center.removeObserver(o) }
        if let o = routeChangeObserver { center.removeObserver(o) }
        if let o = mediaResetObserver { center.removeObserver(o) }
    }

    // MARK: Playback

    /// Play `track` as part of an ordered `context` (e.g. the currently
    /// displayed, sorted library rows, or a search result list). The queue's
    /// context is replaced wholesale and starts at `track`'s position;
    /// `next()`/`previous()`/auto-advance-on-finish then walk this list.
    func play(_ track: Track, in context: [Track]) async {
        let list = context.isEmpty ? [track] : context
        let startAt = list.firstIndex(of: track) ?? 0
        queue.setContext(list, startAt: startAt)
        await playCurrent()
    }

    /// Convenience for callers with no surrounding list — the track is its
    /// own one-item context.
    func play(_ track: Track) async {
        await play(track, in: [track])
    }

    func togglePlayPause() {
        guard currentTrack != nil else { return }
        if isPlaying { pause() } else { resume() }
    }

    /// Advance the queue (userQueue drains first, then the context
    /// continues) and play whatever's next. No-op at the end of the queue.
    func next() {
        guard queue.next() != nil else { return }
        Task { await playCurrent() }
    }

    /// If more than 3s into the current track, restart it; otherwise walk
    /// back into history. No-op (restarts current) if history is empty.
    func previous() {
        if let elapsed = currentElapsedSeconds(), elapsed > 3 {
            seek(to: 0)
            return
        }
        guard queue.previous() != nil else {
            seek(to: 0)
            return
        }
        Task { await playCurrent() }
    }

    /// Insert at the front of the user queue — plays right after the current track.
    func playNext(_ track: Track) {
        queue.playNext(track)
    }

    /// Append to the end of the user queue.
    func addToQueue(_ track: Track) {
        queue.addToQueue(track)
    }

    /// Reschedule playback of the current file starting at `seconds`.
    /// `AVAudioPlayerNode` has no "seek" primitive: we stop the node (which
    /// resets its sampleTime) and reschedule the segment from the target
    /// frame, remembering that frame as the new base for elapsed-time math.
    func seek(to seconds: Double) {
        guard let file = currentFile else { return }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return }
        let durationSeconds = Double(file.length) / sampleRate
        let clamped = max(0, min(seconds, durationSeconds))
        let startFrame = AVAudioFramePosition(clamped * sampleRate)

        let wasPlaying = isPlaying
        playerNode.stop()
        seekBaseFrame = startFrame
        scheduleSegment(of: file, fromFrame: startFrame)
        if wasPlaying {
            playerNode.play()
        }
        updateNowPlayingInfo(elapsed: clamped)
    }

    // MARK: Internals — loading / scheduling

    private func playCurrent() async {
        guard let track = queue.currentTrack else {
            currentTrack = nil
            isPlaying = false
            stopElapsedTimer()
            updateNowPlayingInfo(elapsed: nil)
            return
        }
        await loadAndPlay(track)
    }

    /// Loads `track`'s file, connects/starts the engine, and schedules
    /// playback from `startSeconds`. When `autoplay` is false the segment is
    /// scheduled and ready but the node is not started — used to rebuild
    /// state after `mediaServicesWereResetNotification` without surprising
    /// the user with sudden audio.
    private func loadAndPlay(_ track: Track, atSeconds startSeconds: Double = 0, autoplay: Bool = true) async {
        guard let fileURL = library.fileURL(for: track.uuid) else {
            lastError = "File not found for “\(track.title)”. Try Rescan."
            isPlaying = false
            return
        }
        configureSessionIfNeeded()
        configureRemoteCommandsIfNeeded()
        observeNotificationsIfNeeded()
        lastError = nil

        do {
            let file = try AVAudioFile(forReading: fileURL)

            if playerNode.isPlaying { playerNode.stop() }
            engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)
            if !engine.isRunning { try engine.start() }

            currentFile = file
            currentTrack = track

            let sampleRate = file.processingFormat.sampleRate
            let startFrame = sampleRate > 0 ? AVAudioFramePosition(max(0, startSeconds) * sampleRate) : 0
            seekBaseFrame = startFrame
            scheduleSegment(of: file, fromFrame: startFrame)

            if autoplay {
                playerNode.play()
                isPlaying = true
                startElapsedTimer()
            } else {
                isPlaying = false
                stopElapsedTimer()
            }
            updateNowPlayingInfo(elapsed: startSeconds)
        } catch {
            isPlaying = false
            // Covers both "file missing" (caught above) and "decode failed"
            // (here) — notably Opus-in-Ogg, which AVFoundation may not
            // support at all on some iOS versions.
            lastError = "Couldn’t play “\(track.title)”: \(error.localizedDescription)"
        }
    }

    private func scheduleSegment(of file: AVAudioFile, fromFrame startFrame: AVAudioFramePosition) {
        let remaining = file.length - startFrame
        guard remaining > 0 else { return }
        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(remaining),
            at: nil
        ) { [weak self] in
            Task { @MainActor in self?.handlePlaybackFinished() }
        }
    }

    private func resume() {
        guard currentTrack != nil else { return }
        if !engine.isRunning { try? engine.start() }
        playerNode.play()
        isPlaying = true
        startElapsedTimer()
        updateNowPlayingInfo(elapsed: currentElapsedSeconds())
    }

    private func pause() {
        playerNode.pause()
        isPlaying = false
        stopElapsedTimer()
        updateNowPlayingInfo(elapsed: currentElapsedSeconds())
    }

    private func handlePlaybackFinished() {
        isPlaying = false
        stopElapsedTimer()
        if queue.next() != nil {
            Task { await playCurrent() }
        } else {
            currentTrack = nil
            updateNowPlayingInfo(elapsed: nil)
        }
    }

    // MARK: Elapsed time

    /// Current position in the file, combining the frame we last (re)scheduled
    /// from with however far the node has rendered since then.
    private func currentElapsedSeconds() -> Double? {
        guard let file = currentFile,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        let renderedSinceSchedule = Double(playerTime.sampleTime) / sampleRate
        let base = Double(seekBaseFrame) / sampleRate
        return max(0, base + renderedSinceSchedule)
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickElapsed() }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func tickElapsed() {
        guard isPlaying, let elapsed = currentElapsedSeconds() else { return }
        updateNowPlayingInfo(elapsed: elapsed)
    }

    // MARK: AVAudioSession

    private func configureSessionIfNeeded() {
        guard !didConfigureSession else { return }
        didConfigureSession = true
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .default)
        try? audioSession.setActive(true)
    }

    // MARK: AVAudioSession notifications (interruption / route / media reset)

    private func observeNotificationsIfNeeded() {
        guard !didObserveNotifications else { return }
        didObserveNotifications = true

        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }

        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [weak self] note in
            Task { @MainActor in self?.handleRouteChange(note) }
        }

        mediaResetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.handleMediaServicesReset() }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            pause()
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                resume()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        // e.g. AirPods unplugged / disconnected — never keep blasting the
        // built-in speaker unexpectedly.
        if reason == .oldDeviceUnavailable {
            pause()
        }
    }

    private func handleMediaServicesReset() {
        // The whole audio server process died and restarted: the engine
        // graph and session are gone. Tear everything down, rebuild it, and
        // re-arm the current track (paused) rather than surprising the user
        // by resuming audio out of nowhere.
        stopElapsedTimer()
        let trackToRestore = currentTrack
        let elapsedAtReset = currentElapsedSeconds() ?? 0

        isPlaying = false
        currentFile = nil
        engine.stop()
        engine.reset()

        didConfigureSession = false
        configureSessionIfNeeded()

        guard let track = trackToRestore else { return }
        Task { await self.loadAndPlay(track, atSeconds: elapsedAtReset, autoplay: false) }
    }

    // MARK: Remote command center / Now Playing

    private func configureRemoteCommandsIfNeeded() {
        guard !didConfigureRemoteCommands else { return }
        didConfigureRemoteCommands = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlayingInfo(elapsed: TimeInterval?) {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyArtist] = track.artist ?? ""
        info[MPMediaItemPropertyAlbumTitle] = track.album ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = Double(track.durationMs) / 1000.0
        if let elapsed { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
