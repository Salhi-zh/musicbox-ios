import SwiftUI

/// Root `TabView`: Library, Search, Settings — with the Now-Playing bar pinned
/// above the tab bar via `safeAreaInset` whenever something is loaded.
struct RootView: View {
    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Library", systemImage: "music.note.list") }

            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.currentTrack != nil {
                NowPlayingBar()
            }
        }
    }
}
