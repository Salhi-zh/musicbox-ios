import Foundation
import Combine
import AVFoundation
import MediaPlayer
import MusicboxCore

/// A MINIMAL single-track player built on `AVAudioEngine` + `AVAudioPlayerNode`.
///
/// It plays a LOCAL file (resolved from `LocalLibraryService`) via `AVAudioFile`.
/// This is intentionally the simplest thing that plays one track: no gapless,
/// no crossfade, no ReplayGain DSP, no queue advance.
///
/// FUTURE (the real engine): replace the internals of `play(_:)` with a decoder
/// feeding a PCM ring buffer that schedules buffers on the player node, giving
/// gapless playback, crossfade, and ReplayGain. The UI depends ONLY on the
/// published `currentTrack` / `isPlaying` and the `play/toggle` API below.
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
    /// Retained for the lifetime of playback: `scheduleFile` reads from this
    /// lazily during rendering, so it must outlive `play(_:)`.
    private var currentFile: AVAudioFile?

    init(library: LocalLibraryService) {
        self.library = library
        engine.attach(playerNode)
    }

    // MARK: Playback

    func play(_ track: Track) async {
        guard let fileURL = library.fileURL(for: track.uuid) else {
            lastError = "File not found for “\(track.title)”. Try Rescan."
            return
        }
        configureSessionIfNeeded()
        configureRemoteCommandsIfNeeded()
        lastError = nil

        do {
            let file = try AVAudioFile(forReading: fileURL)

            if playerNode.isPlaying { playerNode.stop() }
            engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)
            if !engine.isRunning { try engine.start() }

            currentFile = file
            currentTrack = track
            playerNode.scheduleFile(file, at: nil) { [weak self] in
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
        // FUTURE: ask the PlayQueue for the next track and continue playback.
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
