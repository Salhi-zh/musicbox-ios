# Apple / TestFlight setup

One-time setup to get Musicbox onto your iPhone 12 via TestFlight. Written
for a solo, personal app — no team, no App Store review needed for internal
testing.

Everything in this checklist is a manual step you do yourself in a browser
(and, at the end, on the iPhone). This repo's CI cannot do any of it for
you — it only runs after you've done steps 1-6 once.

## Checklist

### 1. Enroll in the Apple Developer Program

Do this **first** — it can take anywhere from a few hours to ~2 days for
Apple to approve, and nothing else below works until it's active.

1. Go to https://developer.apple.com/programs/enroll/
2. Enroll as an **Individual** ($99/year).
3. Wait for the confirmation email that your membership is active before
   continuing.

### 2. Create the app in App Store Connect

1. Decide on your bundle id now, e.g. `com.<yourname>.musicbox`. You'll use
   this exact string in three places: the Developer portal, App Store
   Connect, and this repo (steps below).
2. In the [Apple Developer portal](https://developer.apple.com/account) ->
   **Certificates, Identifiers & Profiles** -> **Identifiers** -> **+**:
   register an **App ID** with that bundle id (explicit, not wildcard).
   You don't need to tick any capabilities for this app yet.
3. In [App Store Connect](https://appstoreconnect.apple.com) -> **Apps** ->
   **+** -> **New App**: platform iOS, name "Musicbox" (or whatever you
   like — it's private to you), primary language, and select the bundle id
   you just registered. SKU can be anything (e.g. `musicbox-ios`).
4. That's it for this step — you do **not** need to manually create a
   provisioning profile or certificate. `testflight.yml` runs
   `xcodebuild ... -allowProvisioningUpdates` with automatic signing, which
   creates and renews the distribution certificate + provisioning profile
   for you on every run.

### 3. Create an App Store Connect API key

This is what lets CI authenticate to Apple without your Apple ID password
(and without you generating/rotating certificates by hand).

1. App Store Connect -> **Users and Access** -> **Integrations** tab ->
   **App Store Connect API** (older Xcode docs call this the "Keys" tab).
2. Click **Generate API Key** (or the **+** button). Name it e.g.
   `musicbox-ci`. Access level: **App Manager** is enough (Admin also
   works).
3. Note down the **Key ID** and **Issuer ID** shown on that page — you'll
   need both.
4. Click **Download API Key** to get `AuthKey_<KEYID>.p8`. **Apple only
   lets you download this once.** Save it somewhere safe (e.g. your
   password manager) — if you lose it, revoke the key and generate a new
   one.
5. Base64-encode the file (this is the value the `ASC_KEY_P8_BASE64` secret
   below wants):
   ```bash
   base64 -w0 AuthKey_XXXXXXXXXX.p8
   ```
   (macOS: `base64 -i AuthKey_XXXXXXXXXX.p8` if `-w0` isn't available —
   just make sure it's a single line with no line wraps.)

### 4. Find your Team ID

Developer portal -> **Membership** (or **Account** -> **Membership
details**). It's a 10-character alphanumeric string, e.g. `A1B2C3D4E5`.
This is **not** secret — it's fine as a plain GitHub Actions variable.

### 5. Add secrets and variables to the GitHub repo

Repo -> **Settings** -> **Secrets and variables** -> **Actions**.

**Secrets** tab (key material — never printed in logs):

| Name | Value |
|---|---|
| `ASC_KEY_ID` | the Key ID from step 3 |
| `ASC_ISSUER_ID` | the Issuer ID from step 3 |
| `ASC_KEY_P8_BASE64` | the base64 output from step 3.5 |

**Variables** tab (non-secret config):

| Name | Value |
|---|---|
| `APPLE_TEAM_ID` | the Team ID from step 4 |
| `APP_BUNDLE_ID` | the bundle id from step 2, e.g. `com.<yourname>.musicbox` |

### 6. Set the same bundle id in `project.yml`

Open `project.yml` and change the placeholder:

```yaml
PRODUCT_BUNDLE_IDENTIFIER: com.yourname.musicbox
```

to the same bundle id you used in steps 2 and 5. (Strictly, `testflight.yml`
overrides this at archive time with `vars.APP_BUNDLE_ID`, so CI would work
even if you forgot — but a local `xcodegen generate && open
Musicbox.xcodeproj` will use whatever's in this file, so keep them in
sync.) Run `xcodegen generate` again after editing.

### 7. Trigger the TestFlight workflow

Either:
- Push a version tag:
  ```bash
  git tag v0.1.0
  git push origin v0.1.0
  ```
- Or go to the **Actions** tab -> **TestFlight** -> **Run workflow**.

The job archives, exports, and uploads the `.ipa` (~5-10 min on the
runner). After upload, Apple takes another ~5-15 min to finish
"processing" the build in App Store Connect before it's installable —
watch the **TestFlight** tab of your app in App Store Connect for the
build to go from "Processing" to ready.

### 8. Install on the iPhone 12

1. Install the **TestFlight** app from the App Store.
2. Sign in with the same Apple ID you used for App Store Connect (internal
   testing only works for the account(s) with a role on the app — as the
   sole developer, that's you).
3. Once the build shows as available (you may get an email, or just check
   the TestFlight app), accept and install it.
4. Internal testing (which is all a solo/personal app needs) has **no
   Apple beta review** — the build is installable as soon as it finishes
   processing.

## Build numbers

Apple rejects an upload whose `CFBundleVersion` (build number) matches one
already uploaded for the app. `testflight.yml` handles this for you: the
archive step passes `CURRENT_PROJECT_VERSION=${{ github.run_number }}`,
and `project.yml`'s `Info.plist` properties reference
`$(CURRENT_PROJECT_VERSION)`, so every CI run gets a fresh, always-
incrementing build number automatically. You never need to bump anything
by hand for CI builds. (`MARKETING_VERSION`, i.e. the user-facing "1.0"
version string, is separate and only needs to change when you want it to.)

## Troubleshooting

- **"No profiles for '\<bundle id\>' were found" / signing fails during
  archive.** Almost always means `-allowProvisioningUpdates` didn't run, or
  the API key can't manage this app (needs at least App Manager role — see
  step 3.2), or the bundle id in `vars.APP_BUNDLE_ID` doesn't match the App
  ID registered in the Developer portal (step 2.2). Double check all three.

- **Bundle id mismatch between App Store Connect and the build.** The
  bundle id baked into the archive (`vars.APP_BUNDLE_ID` in the workflow,
  or `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` for a local build) must
  be *exactly* the string you registered as an App ID and used to create
  the app record in App Store Connect. A typo here shows up as a cryptic
  signing or upload failure, not a friendly "bundle id doesn't match"
  message.

- **API key path / "Unable to find authentication key" errors.** The
  workflow writes the `.p8` to
  `~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8` and also passes
  `-authenticationKeyPath` explicitly. If you're reproducing this locally
  on a Mac, make sure the filename is exactly `AuthKey_<KEYID>.p8` (the Key
  ID must match the actual key you downloaded) and that `ASC_KEY_P8_BASE64`
  decodes to a valid `.p8` file (`base64 --decode` it and check the file
  starts with `-----BEGIN PRIVATE KEY-----`).

- **Build number already exists / "redundant binary upload".** You
  re-uploaded without a new `CURRENT_PROJECT_VERSION`. This shouldn't
  happen via `testflight.yml` (it always uses `github.run_number`, which
  only increases) — it usually means a manual/local upload with a stale
  archive. Re-archive, or bump `CURRENT_PROJECT_VERSION` by hand.

- **Missing capability/entitlement errors** (e.g. push notifications,
  background modes not declared). Musicbox currently only declares the
  `audio` background mode (already in `project.yml`). If you add a
  capability that needs an entitlement (push, iCloud, etc.), add it under
  the target's `entitlements`/`capabilities` in `project.yml` *and* enable
  it for the App ID in the Developer portal — automatic signing will not
  invent capabilities you haven't registered.

- **Workflow exits immediately with "Missing required GitHub Actions
  config".** The guard step (top of `testflight.yml`) tells you exactly
  which secret or variable is unset — go back to step 5.
