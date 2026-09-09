import SwiftUI

/// Owns the app's long-lived objects and wires their dependencies once.
///
/// Everything hangs off a single `SettingsStore` (the source of truth for the
/// server config). The sub-objects are created here, in order, and then
/// injected into the view tree as individual `environmentObject`s so each view
/// observes exactly what it uses.
@MainActor
final class AppModel: ObservableObject {
    let settings: SettingsStore
    let syncService: SyncService
    let library: LibraryModel
    let player: AudioPlayer
    let artwork: ArtworkLoader

    init() {
        let settings = SettingsStore()
        let syncService = SyncService()
        self.settings = settings
        self.syncService = syncService
        self.library = LibraryModel(settings: settings, sync: syncService)
        self.player = AudioPlayer(settings: settings)
        self.artwork = ArtworkLoader(settings: settings)
    }
}

@main
struct MusicboxApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app.settings)
                .environmentObject(app.library)
                .environmentObject(app.player)
                .environmentObject(app.artwork)
        }
    }
}
