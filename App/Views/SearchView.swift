import SwiftUI

/// Search tab: a relevance-ranked search over the library via
/// `MusicboxCore.SearchIndex` (supports free text plus field filters like
/// `artist:`, `genre:`, `year:1990-1999`, `duration:>3m`). Results are
/// computed by `LibraryModel.results(for:)`; this view holds only the query
/// and the returned rows, so it never mutates the Library tab's list.
struct SearchView: View {
    @EnvironmentObject private var library: LibraryModel

    @State private var query = ""
    @State private var results: [TrackRow] = []

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    prompt
                } else if results.isEmpty {
                    noMatches
                } else {
                    List(results) { row in
                        TrackRowView(row: row)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Search title, artist, album")
            .onChange(of: query) { newValue in
                results = library.results(for: newValue)
            }
        }
    }

    private var prompt: some View {
        ContentUnavailableCompat(
            title: "Search your library",
            systemImage: "magnifyingglass",
            message: "Try a title or artist. Filters: artist:, genre:, year:1990-1999, duration:>3m"
        )
    }

    private var noMatches: some View {
        ContentUnavailableCompat(
            title: "No matches",
            systemImage: "questionmark.circle",
            message: "Nothing matched “\(query)”."
        )
    }
}

/// iOS 16-compatible stand-in for `ContentUnavailableView` (which is iOS 17+).
private struct ContentUnavailableCompat: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
