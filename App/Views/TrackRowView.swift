import SwiftUI

/// One library/search row: artwork + precomputed title/subtitle + duration.
/// Tapping plays the track. No formatting happens here — `TrackRow` is already
/// render-ready (see `LibraryModel`).
struct TrackRowView: View {
    let row: TrackRow

    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        Button {
            Task { await player.play(row.track) }
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
