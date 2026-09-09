import SwiftUI

/// The full library: a sortable, searchable `List`. Sorting/search are done in
/// `MusicboxCore` via `LibraryModel`; this view just renders `library.rows`.
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        NavigationStack {
            Group {
                if library.rows.isEmpty {
                    emptyState
                } else {
                    List(library.rows) { row in
                        TrackRowView(row: row)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { sortMenu }
                ToolbarItem(placement: .navigationBarLeading) {
                    if library.isSyncing { ProgressView() }
                }
            }
            .refreshable { await library.syncNow() }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $library.sort) {
                ForEach(LibrarySort.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Your library is empty")
                .font(.headline)
            Text("Pull to refresh, or tap Sync in Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
