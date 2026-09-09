import Foundation
import Combine
import AVFoundation
import MediaPlayer
import MusicboxCore

/// A MINIMAL single-track player built on `AVAudioEngine` + `AVAudioPlayerNode`.
///
/// It downloads `GET /v1/media/{uuid}` to a cache file and plays it via
/// `AVAudioFile`. This is intentionally the simplest thing that plays one
/// track: no gapless, no crossfade, no ReplayGain DSP, no queue advance.
///
/// FUTURE (the real engine): replace the internals of `play(_:)` /
/// `mediaFileURL(for:)` with a libopus-backed decoder feeding a PCM ring
/// buffer that schedules buffers on the player node, giving gapless playback,
/// crossfade, and ReplayGain gain application. The UI depends ONLY on the
/// published `currentTrack` / `isPlaying` and the `play/toggle` API below, so
/// that swap won't touch any view.
///
/// OPUS NOTE: the server serves Ogg/Opus. `AVAudioFile` decodes Opus on recent
/// iOS, but this is NOT guaranteed across all versions/containers — if a file
/// fails to open, that surfaces as a play error here and is exactly the case
/// the libopus engine above will own. This minimal player is the fallback.
@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var currentTrack: Track?
    @Published private(set) var isPlaying = false
    @Published var lastError: String?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let settings: SettingsStore
    private let session: URLSession

    private var didConfigureSession = false
    private var didConfigureRemoteCommands = false
    private let mediaCacheDir: URL
    /// Retained for the lifetime of playback: `scheduleFile` reads from this
    /// lazily during rendering, so it must outlive `play(_:)`.
    private var currentFile: AVAudioFile?

    init(settings: SettingsStore, session: URLSession = .shared) {
        self.settings = settings
        self.session = session

        let caches = (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = caches.appendingPathComponent("MusicboxMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.mediaCacheDir = dir

        engine.attach(playerNode)
    }

    // MARK: Playback

    func play(_ track: Track) async {
        guard let config = settings.config else {
            lastError = "Set the server URL and token in Settings first."
            return
        }
        configureSessionIfNeeded()
        configureRemoteCommandsIfNeeded()
        lastError = nil

        do {
            let fileURL = try await mediaFileURL(for: track, config: config)
            let file = try AVAudioFile(forReading: fileURL)

            if playerNode.isPlaying { playerNode.stop() }
            // (Re)connect with this file's processing format.
            engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)
            if !engine.isRunning { try engine.start() }

            currentFile = file
            currentTrack = track
            playerNode.scheduleFile(file, at: nil) { [weak self] in
                // Completion fires on an internal AVAudioEngine thread; hop back.
                Task { @MainActor in self?.handlePlaybackFinished() }
            }
            playerNode.play()
            isPlaying = true
            updateNowPlayingInfo(elapsed: 0)
        } catch {
            isPlaying = false
            lastError = "Playback failed: \(error.localizedDescription)"
        }
    }

    func togglePlayPause() {
        guard currentTrack != nil else { return }
        if isPlaying { pause() } else { resume() }
    }

    private func resume() {
        guard currentTrack != nil else { return }
        if !engine.isRunning { try? engine.start() }
        playerNode.play()
        isPlaying = true
        updateNowPlayingInfo(elapsed: nil)
    }

    private func pause() {
        playerNode.pause()
        isPlaying = false
        updateNowPlayingInfo(elapsed: nil)
    }

    private func handlePlaybackFinished() {
        isPlaying = false
        // FUTURE: ask the PlayQueue for the next track and continue playback
        // (this is where gapless scheduling of the next file will hook in).
    }

    // MARK: Media fetch (download-to-file fallback)

    private func mediaFileURL(for track: Track, config: ServerConfig) async throws -> URL {
        let destination = mediaCacheDir.appendingPathComponent(track.uuid.uuidString, isDirectory: false)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        guard let request = MusicboxAPI.mediaRequest(for: track.uuid, config: config) else {
            throw URLError(.badURL)
        }
        // FUTURE: stream with HTTP Range + ETag(sha256) validation instead of a
        // full download; the real engine will pull ranges into its ring buffer.
        let (tempURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        // Encrypted at rest but readable for background playback after first unlock.
        try? (destination as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey
        )
        return destination
    }

    // MARK: AVAudioSession

    private func configureSessionIfNeeded() {
        guard !didConfigureSession else { return }
        didConfigureSession = true
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .default)
        try? audioSession.setActive(true)
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
        // FUTURE: next/previous wired to PlayQueue once the queue engine lands.
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
