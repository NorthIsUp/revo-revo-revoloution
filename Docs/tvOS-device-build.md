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

## iCloud Drive does not exist on tvOS — stop trying to make it work

**Apple does not offer iCloud Drive documents to tvOS apps** — still true on
tvOS 26 / Xcode 26.6, so this is not a version we can wait out. Apple's own
capability database, shipped inside Xcode, spells it out:

```
/Applications/Xcode.app/Contents/SharedFrameworks/DVTPortal.framework/
  Versions/A/Resources/DVTPortalCachedPortalCapabilities.json   → capability ICLOUD

  ubiquity-container-identifiers  supportedSDKs: IOS, MAC_OS, VISION_OS, WATCH_OS
  icloud-services "CloudDocuments" supportedSDKs: IOS, MAC_OS, VISION_OS, WATCH_OS
  icloud-services "CloudKit"       (unrestricted)
```

`TV_OS` appears in the capability's own `supportedSDKs` — which is why iCloud can
be switched on for the App ID at all — but it is absent from both entitlements
that iCloud Drive needs. Hence the profile only ever grants `CloudKit`, and
Xcode's Signing & Capabilities editor for a tvOS target offers just **Key-value
storage** and **CloudKit**, with no *iCloud Documents* checkbox to tick.

`-URLForUbiquityContainerIdentifier:` *is* declared available on tvos(9.0), so
the call compiles and simply returns nil forever, which is exactly what the app
sees. Everything below is the paper trail of chasing that nil before the cause
was understood; keep it so nobody repeats the search.

### Getting songs onto the box anyway

The TV cannot read iCloud Drive, but a Mac can, so sync from the Mac side:

```
./Utils/push-songs.py ~/Library/Mobile\ Documents/com~apple~CloudDocs/RRRevoloution/Songs 10.0.1.23
```

Point it at any `Songs/`-shaped folder (`<group>/<song>/`) — put that folder in
iCloud Drive and every device you own keeps it current for free. It posts one
request per song to the TV's upload server, and the server merges, so re-running
sends only what is new (`0 sent, 12 already present`). The IP is the one the TV
prints on screen at boot. Then Options → Reload Songs.

Consequences for this port:

- `UserDocumentsRoot()` always falls back to the sandbox on device. That is
  fine, and not a dead end: the upload server writes into the same directory the
  game mounts, so **the browser upload page is the supported way to load songs**.
- The iCloud materialize / conflict-resolution work (audit H1 and H3) cannot run
  on tvOS. It is left in place because it is harmless and would come back to
  life behind an iOS or macOS companion, but do not budget time on it for the TV.
- If cross-device song sync is ever wanted on the TV, CloudKit is the only
  route Apple supports, and it is a real project: songs would have to be
  modelled as CloudKit records and synced down into the sandbox.

## Historical: iCloud Drive needs `CloudDocuments`, and API-made profiles do not grant it

The v1.2.4 build on TestFlight shipped with these entitlements — note what is
*missing*, and check yours the same way before blaming the app:

```
codesign -d --entitlements :- Payload/RRRevoloution.app
  com.apple.developer.icloud-container-identifiers = [iCloud.com.northisup.rererevoloution]
  # ...and nothing else iCloud-related
```

`com.apple.developer.icloud-services` (`CloudDocuments`) and
`com.apple.developer.ubiquity-container-identifiers` were both requested by
`Xcode/RRRevoloution-tvOS.entitlements` and both dropped at re-sign, because
codesign keeps only what the profile grants. The profile grants
`icloud-services = [CloudKit]`. Without `CloudDocuments`,
`URLForUbiquityContainerIdentifier:` returns nil, `UserDocumentsRoot()` falls
back to the sandbox, and on tvOS that directory is unreachable — the app looks
permanently empty with no way to add songs.

The App ID capability is already `ICLOUD` / `ICLOUD_VERSION=XCODE_6` with the
container attached, and neither signing route fixes it:

- a profile freshly minted through `POST /v1/profiles` comes back
  `CloudKit`-only, and `XCODE_5` is worse (it drops the container identifiers
  entirely, leaving only the kv-store);
- **Xcode-managed signing does not help either.** An archive run with
  `-allowProvisioningUpdates` and the Admin key signs against "tvOS Team
  Provisioning Profile" with no warning, and the entitlements Xcode *requested*
  come out as just `application-identifier`, `team-identifier` and
  `icloud-container-identifiers`.

That last one is the tell, and it is worth checking before suspecting the build:

```
plutil -p build-tvos-device/build/RRRevoloution.build/Release-appletvos/RRRevoloution.app.xcent
```

`src/CMakeLists.txt:218` does point `CODE_SIGN_ENTITLEMENTS` at
`Xcode/RRRevoloution-tvOS.entitlements`, and the generated project carries the
right absolute path — Xcode reads the file and then silently drops every key the
App ID cannot grant. So the app never asks for `CloudDocuments` and iCloud Drive
cannot work no matter how the profile is generated.

Things that were tried and did **not** work, so nobody repeats them:

- deleting the `ICLOUD` capability and POSTing a fresh one — still `CloudKit`;
- dropping the legacy `ubiquity-container-identifiers` key from the
  entitlements, on the theory that one unsatisfiable key was poisoning the whole
  iCloud set — `icloud-services` is still pruned, so Xcode prunes per key and
  the value mismatch (`CloudDocuments` requested, `CloudKit` granted) is the
  whole story;
- `GET /v1/cloudContainers` and friends — 404; the API has no container
  resource at all.

The App ID page itself has no per-service toggle: the radio picks the
entitlement era ("requires Xcode 6" is Apple's 2014 label for the modern one —
keep it), and **Edit** only assigns containers. Which services an App ID
supports is registered by **Xcode.app's** Signing & Capabilities editor, through
a portal integration the public API does not expose. So: open the target in
Xcode once, add the **iCloud** capability with *iCloud Documents* ticked and the
container selected, and let it register. Afterwards an API-generated profile
picks the service up and CI can go back to manual signing unchanged.

Whatever route, verify by entitlements, never by the profile's name:

```
mise run tvos:export
codesign -d --entitlements :- build-tvos-device/export/*.ipa  # want CloudDocuments
```

Changing the App ID's capabilities invalidates every existing profile
(`profileState: INVALID`), including the one in `APP_STORE_PROFILE` — regenerate
and re-set the secret in the same sitting or the next CI run fails to export.

## Notes

- TestFlight build numbers must be unique; CI only uploads on a version bump for
  that reason. Bump `SM_VERSION_*` in `CMake/SMDefs.cmake` to ship a new build.
- Locally, `xcodebuild` uses your Xcode-cached Apple ID; the API key is only
  required for `tvos:upload`. In CI the API key drives the *archive's* automatic
  development signing (`-allowProvisioningUpdates`) and the TestFlight upload; the
  *export* re-signs with the imported Apple Distribution cert + profile (manual).
- Internal TestFlight testers install over the air on any Apple TV signed into
  their Apple ID — no UDID registration or cable needed.
