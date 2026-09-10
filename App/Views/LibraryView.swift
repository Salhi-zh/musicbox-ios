import SwiftUI
import UniformTypeIdentifiers

/// The full library: a sortable, searchable `List` of on-device songs.
/// Sorting/search run in `MusicboxCore` via `LibraryModel`; this view renders
/// `library.rows` and offers Import + Rescan.
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryModel

    @State private var showImporter = false

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
                    if library.isScanning {
                        ProgressView()
                    } else {
                        Button {
                            showImporter = true
                        } label: {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }
                    }
                }
            }
            .refreshable { await library.rescan() }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: true
            ) { result in
                if case let .success(urls) = result {
                    Task { await library.importFiles(urls) }
                }
            }
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
            Text("Tap Import to add audio files, or open the Files app and drop songs into “On My iPhone → Musicbox”, then pull to refresh.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showImporter = true
            } label: {
                Label("Import songs", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding()
    }
}
