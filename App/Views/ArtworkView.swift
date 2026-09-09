import SwiftUI
import UIKit
import MusicboxCore

/// Async album-art thumbnail. Shows a placeholder immediately and fills in the
/// downsampled image when it arrives. Loading is keyed on the track UUID so
/// row reuse doesn't show stale art.
struct ArtworkView: View {
    let uuid: UUID
    var size: CGFloat = 44

    @EnvironmentObject private var artwork: ArtworkLoader
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: uuid) {
            image = artwork.cachedImage(for: uuid)
            if image == nil {
                image = await artwork.image(for: uuid)
            }
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.secondary.opacity(0.15))
            .overlay(
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
                    .font(.system(size: size * 0.4))
            )
    }
}
