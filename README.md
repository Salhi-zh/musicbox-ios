# Musicbox iOS

A personal, single-user music player for iOS 16+. It syncs a library from your
own Musicbox server, lets you browse / search / sort it, and plays a track.

This repo is a **SwiftPM package + an iOS app**:

```
musicbox-ios/
├── Package.swift                     # vends the MusicboxCore library + tests
├── Sources/MusicboxCore/             # platform-agnostic core (Foundation only)
├── Tests/MusicboxCoreTests/          # 46 tests, run on Linux AND macOS CI
├── App/                              # the iOS app (SwiftUI, AVFoundation, iOS-only)
├── project.yml                       # XcodeGen manifest -> Musicbox.xcodeproj
├── ExportOptions.plist               # xcodebuild -exportArchive config (TestFlight)
├── APPLE_SETUP.md                    # one-time Apple/TestFlight setup checklist
├── .github/workflows/ios.yml         # CI: swift test + build app for the Simulator (every push)
└── .github/workflows/testflight.yml  # CI: archive, sign, upload to TestFlight (tag/manual only)
```

## MusicboxCore vs App

- **`MusicboxCore`** (`Sources/MusicboxCore/`) is **Foundation-only** and builds
  and tests on Linux. It owns the data model (`Track`, `PlayEvent`, …), text
  normalization, the search index, the sort/collation engine, the play queue,
  smart-playlist evaluation, and the sync-merge logic (`SyncClient`). It has **no
  UIKit / SwiftUI / AVFoundation** and must stay that way — that is what keeps
  the `swift test` gate green on Linux.
- **`App/`** (`App/`) is the iOS app. All iOS-only frameworks live *only* here.
  It depends on `MusicboxCore` as a **local, path-based** SwiftPM package and
  reuses the core models/algorithms rather than reimplementing them:
  - `SyncService` — an `actor` conforming to `MusicboxCore.SyncTransport`; drives
    `GET /v1/sync` and feeds pages to `SyncClient.syncAll`.
  - `LibraryStore` — a Codable-file snapshot in Application Support (excluded
    from iCloud backup, data-protected). *Future: GRDB.*
  - `LibraryModel` — orchestration; search/sort delegate to `SearchIndex` /
    `SortEngine`.
  - `ArtworkLoader` — downsampling image loader (`CGImageSourceCreateThumbnailAtIndex`)
    + in-memory cache.
  - `AudioPlayer` — a **minimal** `AVAudioEngine` single-track player. *Future:
    libopus + PCM ring buffer for gapless/crossfade/ReplayGain — the UI only
    depends on `currentTrack`/`isPlaying`, so the internals can be swapped.*

### Verify the core on Linux

```bash
source "$HOME/.local/share/swiftly/env.sh"
cd musicbox-ios && swift build && swift test   # expect 46 tests passing
```

The iOS app **cannot** compile on Linux (SwiftUI/AVFoundation). It is compiled
on macOS CI (below) and in Xcode.

## Open in Xcode

The `.xcodeproj` is generated (and git-ignored), not committed:

```bash
brew install xcodegen        # once
xcodegen generate && open Musicbox.xcodeproj
```

## How CI works

There are **two** workflows, deliberately split so a missing Apple account
never blocks ordinary development:

### `.github/workflows/ios.yml` — compile gate, every push

Runs on every `push`/`pull_request` on a `macos-15` runner:

1. checkout
2. select the latest installed Xcode
3. `swift test` — runs the **MusicboxCore** tests (same gate as Linux)
4. `brew install xcodegen` → `xcodegen generate`
5. `xcodebuild … -scheme Musicbox -destination 'platform=iOS Simulator,name=iPhone 15' build`
   — builds the app **unsigned** for the Simulator

SwiftPM output is cached. No signing, no Apple account, no secrets required
— it works out of the box on a fresh clone.

> The `swift test` step could be moved to a cheaper `ubuntu-latest` job (it is
> the exact Linux gate); it runs on `macos-15` here to keep everything in one
> job as specified.

### `.github/workflows/testflight.yml` — TestFlight release, tag/manual only

Runs **only** on a pushed `v*` tag (e.g. `v0.1.0`) or the manual "Run
workflow" button — never on a plain push, so it can't fail a normal PR just
because Apple secrets aren't set up yet. It archives the app, signs it
automatically using an App Store Connect API key, exports an `.ipa`, and
uploads it to TestFlight. Requires a one-time Apple Developer Program
enrollment and some repo secrets/variables — see **[`APPLE_SETUP.md`](APPLE_SETUP.md)**
for the full step-by-step checklist (Apple enrollment, API key, GitHub
secrets, and installing the build on your iPhone via the TestFlight app).

## Repo visibility & secrets

- **Make the repo PUBLIC.** macOS CI minutes are free for public repositories;
  private repos consume paid minutes quickly on `macos-15`.
- **Never commit secrets.** The server base URL and bearer token are entered at
  runtime in the app's Settings screen and stored on-device (UserDefaults for
  now; Keychain is the planned upgrade). Nothing sensitive belongs in this repo.

## Phase 0 activation checklist (do this yourself — CI/git is not run for you)

1. `gh auth login`
2. `gh repo create musicbox-ios --public --source=. --remote=origin` (or create
   it in the UI and add the remote)
3. `git add -A && git commit -m "Musicbox iOS skeleton + CI"`
4. `git push -u origin main`
5. Watch the **iOS** workflow go green in the Actions tab (first real compile of
   the app).
6. To install on your iPhone 12 you need either:
   - **SideStore** (free, no paid Apple account, re-signs every ~7 days), or
   - **TestFlight** (needs the $99/yr Apple Developer Program, but installs
     stay valid and updates are just a new tag push). Follow
     **[`APPLE_SETUP.md`](APPLE_SETUP.md)** for the full TestFlight setup —
     it also covers setting your own `PRODUCT_BUNDLE_IDENTIFIER` and
     `DEVELOPMENT_TEAM` in `project.yml` in place of the placeholders.
7. In the app's **Settings**, enter your server base URL (`http://<lan-or-tailscale-ip>:<port>`,
   no trailing `/v1`) and bearer token, tap **Check /v1/health**, then **Sync now**.

## Scope (this phase)

Implemented: sync the library, list/search/sort it, play one track, basic
lock-screen play/pause. **Not yet:** gapless/crossfade, ReplayGain DSP, a
queue UI, and the libopus engine — those are a later wave and have clean seams
(`// FUTURE:` markers) rather than fake stubs.
