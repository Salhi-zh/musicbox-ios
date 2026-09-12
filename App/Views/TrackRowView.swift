import SwiftUI
import MusicboxCore

/// One library/search row: artwork + precomputed title/subtitle + duration.
/// Tapping plays the track. No formatting happens here — `TrackRow` is already
/// render-ready (see `LibraryModel`).
struct TrackRowView: View {
    let row: TrackRow
    /// The ordered list this row lives in (Library rows or Search results),
    /// so tapping starts the `PlayQueue` context at this track. Defaults to
    /// a one-item context for any caller that doesn't have a surrounding list.
    var context: [Track]? = nil

    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        Button {
            let tracks = context ?? [row.track]
            Task { await player.play(row.track, in: tracks) }
        } label: {
            HStack(spacing: 12) {
                ArtworkView(uuid: row.id, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.body)
                        .lineLimit(1)
                    if !row.subtitle.isEmpty {
                        Text(row.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(row.duration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
