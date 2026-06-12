# tvOS Signed Device Build & TestFlight (audit H2)

The Simulator build (`mise run tvos:build`, the `build` CI job) is a smoke test
and **cannot run iCloud** — simulator signing strips entitlements. To actually
run on Apple TV hardware with iCloud Drive, you need a **signed device build**.

Pipeline (local and CI share the same mise tasks):

```
tvos:configure-device   # cmake -DCMAKE_OSX_SYSROOT=appletvos  -> build-tvos-device/
tvos:archive            # xcodebuild archive                   -> RRRevoloution.xcarchive
tvos:export             # xcodebuild -exportArchive (method=app-store) -> export/*.ipa
tvos:upload             # xcrun altool --upload-app            -> TestFlight
```

## Local build (you, with Xcode signed in to your Apple ID)

`TVOS_DEV_TEAM` is already set in `.mise.local.toml` (`4BJBDQVY6M`).

```
mise run tvos:export    # runs configure-device -> archive -> export
```

Produces `build-tvos-device/export/*.ipa`. To push it to TestFlight you need an
API key (below), then `mise run tvos:upload`.

## One-time prerequisites in the Apple Developer portal / App Store Connect

1. **App ID** `com.northisup.rererevoloution`: enable the **iCloud** capability
   and associate container `iCloud.com.northisup.rererevoloution`
   (developer.apple.com → Certificates, IDs & Profiles → Identifiers).
2. **App record**: in App Store Connect → Apps → **＋** → New App, platform
   **tvOS**, bundle id `com.northisup.rererevoloution`. TestFlight needs the app
   to exist before the first upload.

## Creating the App Store Connect API key (for CI + `tvos:upload`)

1. Go to **App Store Connect → Users and Access → Integrations** tab → **App
   Store Connect API** → **Team Keys**.
2. Click **＋** (Generate API Key). Name it e.g. `revo-ci`. **Access: App
   Manager** (needed to manage signing/provisioning and upload builds).
3. **Download the `.p8`** — you can only download it once. Save it somewhere
   safe (e.g. `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8`).
4. Note two values from that page:
   - **Key ID** (next to the key, ~10 chars) → `ASC_KEY_ID`
   - **Issuer ID** (UUID at the top of the Keys page, shared by all keys) →
     `ASC_ISSUER_ID`

## GitHub Actions secrets

Add these to the repo (`gh secret set <NAME> --repo NorthIsUp/revo-revo-revoloution`):

| Secret | Value |
|---|---|
| `TVOS_DEV_TEAM` | `4BJBDQVY6M` |
| `ASC_KEY_ID` | the **Admin** key's Key ID (`238ATU74S4`) |
| `ASC_ISSUER_ID` | the Issuer ID (shared by all keys) |
| `ASC_KEY_P8` | base64 of the Admin `.p8`: `base64 -i AuthKey_<KEYID>.p8` |
| `DIST_CERT_P12` | base64 of the Apple Distribution `.p12` |
| `DIST_CERT_PASSWORD` | the `.p12` export password |
| `APP_STORE_PROFILE` | base64 of the `TVOS_APP_STORE` `.mobileprovision` |

Once set, the **device** CI job imports the distribution cert + profile, archives,
and exports a signed `.ipa` on every push to `apple-tv` (uploaded as an artifact).
On a version bump (`CMake/SMDefs.cmake`) it also uploads to **TestFlight**. Trigger
a manual run any time from the Actions tab (the workflow has `workflow_dispatch`).

## Distribution signing (why it's manual)

App Store / TestFlight needs an **Apple Distribution** certificate + an **App
Store provisioning profile**. `xcodebuild -exportArchive` cannot *cloud-create*
those headlessly (it fails with `Cloud signing permission error` even with an
Admin key), so we pre-create them once and CI imports them:

- The ASC API key must be **Admin** (App Manager can't create a distribution cert).
- The cert (`Apple Distribution`, id `4N5BSMD323`) + profile (`RRRevoloution tvOS
  App Store`) were created via the API; the `.p8` keys, the `.p12` (with the only
  copy of the distribution private key), and the `.mobileprovision` are stored in
  1Password (personal → Private → "RRRevoloution tvOS — Apple code signing (CI)").
- To recreate if lost: generate a keypair + CSR, `POST /v1/certificates`
  (`DISTRIBUTION`) and `POST /v1/profiles` (`TVOS_APP_STORE`) with the Admin key,
  then re-set `DIST_CERT_P12` / `DIST_CERT_PASSWORD` / `APP_STORE_PROFILE`.

## Notes

- TestFlight build numbers must be unique; CI only uploads on a version bump for
  that reason. Bump `SM_VERSION_*` in `CMake/SMDefs.cmake` to ship a new build.
- Locally, `xcodebuild` uses your Xcode-cached Apple ID; the API key is only
  required for `tvos:upload`. In CI the API key drives the *archive's* automatic
  development signing (`-allowProvisioningUpdates`) and the TestFlight upload; the
  *export* re-signs with the imported Apple Distribution cert + profile (manual).
- Internal TestFlight testers install over the air on any Apple TV signed into
  their Apple ID — no UDID registration or cable needed.
