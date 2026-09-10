import SwiftUI

/// Owns the app's long-lived objects and wires their dependencies once.
///
/// Everything hangs off a single `LocalLibraryService` (the on-device library —
/// no server). Sub-objects are created here and injected into the view tree as
/// individual `environmentObject`s so each view observes exactly what it uses.
@MainActor
final class AppModel: ObservableObject {
    let libraryService: LocalLibraryService
    let library: LibraryModel
    let player: AudioPlayer
    let artwork: ArtworkLoader

    init() {
        let service = LocalLibraryService()
        self.libraryService = service
        self.library = LibraryModel(service: service)
        self.player = AudioPlayer(library: service)
        self.artwork = ArtworkLoader(library: service)
    }

    func scan() {
        Task { await library.rescan() }
    }
}

@main
struct MusicboxApp: App {
    @StateObject private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app.library)
                .environmentObject(app.player)
                .environmentObject(app.artwork)
                .environmentObject(app.libraryService)
                .task { app.scan() }               // scan on launch
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { app.scan() }     // pick up files dragged in via Files
        }
    }
}
