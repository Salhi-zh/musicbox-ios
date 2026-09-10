import SwiftUI

/// Local library settings: song count, rescan, and how to add music.
struct SettingsView: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Library") {
                    LabeledContent("Songs", value: "\(library.trackCount)")
                    Button {
                        Task { await library.rescan() }
                    } label: {
                        HStack {
                            Text("Rescan")
                            if library.isScanning {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(library.isScanning)
                    if let message = library.lastMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Adding music") {
                    Text("Use Import on the Library tab, or open the Files app and copy songs into “On My iPhone → Musicbox”, then Rescan.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("Musicbox stores your music on this device only — no account, no server.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
