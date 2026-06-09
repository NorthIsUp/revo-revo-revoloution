# tvOS iCloud Drive — Audit Report

## 1. Verdict

iCloud Drive support is **wired correctly at the static-configuration layer but is not delivered or runtime-complete**. The identity plumbing is excellent: the container id `iCloud.com.northisup.rererevoloution` is spelled identically across the entitlements, `Info-tvOS.plist.in`, and the CMake bundle id, and the entitlements + `NSUbiquitousContainers` keys are syntactically correct. The default-on toggle degrades gracefully to the local sandbox when iCloud is unavailable. However, the feature fails its headline promise — "songs added via Files/icloud.com, synced across Apple TVs" — for two independent reasons: (1) **the engine never materializes evicted iCloud items**, so on a second Apple TV (or after eviction) content exists only as `.icloud` placeholders the POSIX "dir" driver cannot read; and (2) **every CI/released artifact is a Simulator build that strips the iCloud entitlement**, so the feature is undeliverable through the supported build flow. There is also no file-coordination (`NSFileCoordinator`/`NSFileVersion`), risking torn writes and lost scores on the very multi-device path the feature targets. Net: the config is right, but the runtime and delivery layers are incomplete.

| Dimension | Status | One-line rationale |
|---|---|---|
| config-identity | ✅ | Container id consistent everywhere; entitlements↔plist↔CMake all agree. |
| plist-ubiquity | ⚠️ | Keys correct, but two are tvOS no-ops and remote-surfacing is unverified. |
| runtime-mount | ❌ | No download/materialization of evicted items; blocking call on boot thread. |
| sync-semantics | ❌ | No `NSFileCoordinator`/`NSMetadataQuery`/`NSFileVersion`; conflicts/eviction unhandled. |
| build-signing | ❌ | Only Simulator builds ship; iCloud entitlement stripped from every release. |
| ux-settings | ⚠️ | Settings.bundle is well-formed but tvOS never renders it; toggle unreachable. |

## 2. Blockers & High-severity issues

### H1 — Evicted/non-materialized iCloud items are never downloaded (the core sync bug)
- **What's wrong:** The ubiquity Documents path is mounted with the `dir` driver (`RageFileDriverDirect`), which does plain POSIX `open()`/`stat()`/`readdir()`. iCloud Drive only guarantees a zero-byte `.<name>.icloud` placeholder on local disk until an app calls `-[NSFileManager startDownloadingUbiquitousItemAtURL:error:]` or drives an `NSMetadataQuery`. There is **no such call anywhere in `src/`**.
- **Why it matters to users:** On a *second* Apple TV (the headline "synced across Apple TVs" case) or after tvOS evicts content to reclaim space, songs/themes the user added via Files/icloud.com appear only as placeholders. `readdir()` returns `.Cooltune.icloud` (a hidden dotfile the song scan skips) instead of `Cooltune`, and `open()` of the real path fails `ENOENT` — songs silently vanish or fail to load even though they "exist" in iCloud.
- **Fix:** Before/while mounting, enumerate the Documents subtree (or use `NSMetadataQuery` with `NSMetadataQueryUbiquitousDocumentsScope`) and call `startDownloadingUbiquitousItemAtURL:` for any item whose `NSURLUbiquitousItemDownloadingStatusKey` is not `Current`; wait for status `Current` before scanning. At minimum, in the song-scan path detect a sibling `.<name>.icloud` placeholder and request download.
- **Where:** `src/arch/ArchHooks/ArchHooks_tvOS.mm:199-210, 254-260`.

### H2 — Shipped/CI artifacts are Simulator builds that strip the iCloud entitlement
- **What's wrong:** The only automated build path targets the tvOS Simulator: configure forces `-DCMAKE_OSX_SYSROOT=appletvsimulator` and build uses `-destination 'platform=tvOS Simulator'`. The author's own signing commit (`75094b0a33`) states simulator `xcodebuild` uses "Sign to Run Locally" and strips entitlements. CI then packages `RRRevoloution-debug.app` and uploads it as the GitHub release asset. There is no `appletvos` (device) sysroot, no `xcodebuild archive`/`exportArchive`, and no signed device build anywhere.
- **Why it matters to users:** Every released binary has **no iCloud entitlement** and cannot use the ubiquity container; a simulator slice cannot even install on real Apple TV hardware. The feature is never exercised or delivered through the supported flow.
- **Fix:** Add a device build/archive path: a second configure with `-DCMAKE_OSX_SYSROOT=appletvos`, `xcodebuild archive` + `-exportArchive` (with an `ExportOptions.plist`) signed against the team, and have CI release the device `.ipa`. Keep the simulator build for smoke-test only, clearly labeled non-iCloud-capable.
- **Where:** `.github/workflows/tvos.yml` (Configure/Build/Package), `mise_tasks/tvos/configure`, `mise_tasks/tvos/build`.

### H3 — Uncoordinated writes, conflicts, and eviction unhandled
- **What's wrong:** Truncating writes to `Save` race the iCloud sync daemon with no `NSFileCoordinator`/`NSFilePresenter` (torn files), there is no `NSFileVersion` conflict resolution (lost scores), and evicted songs are never re-downloaded. `grep` over `src/` finds zero uses of any of these APIs.
- **Why it matters to users:** Cross-device `Save` writes generate `NSFileVersion` conflicts that are silently lost — scores disappear — directly undermining the sync-across-Apple-TVs goal; concurrent writes can corrupt profile/score files.
- **Fix:** Wrap ubiquity-container I/O in `NSFileCoordinator`, resolve conflicts via `NSFileVersion`, and re-download on read failure. (Overlaps H1's materialization work.)
- **Where:** `src/arch/ArchHooks/ArchHooks_tvOS.mm:254`.

## 3. Medium / Low issues

### M1 — "Exposed in the Files app" premise is inaccurate for tvOS; remote surfacing unverified (medium)
The plist and `ArchHooks` comments ("expose the app's container Documents folder in the Files app and on icloud.com") describe iOS behavior. tvOS has no Files app and no on-device document browser. The feature can only work if tvOS actually registers its `NSUbiquitousContainers` document-scope metadata and syncs container writes to iCloud Drive on *other* devices — tvOS historically is not a full iCloud Drive document client. This is unverified on hardware and is the single biggest premise risk after H1. **Fix:** Verify on real hardware (see §6); correct the comments to say the Apple TV itself has no Files browser and management happens from other devices only. `Xcode/Info-tvOS.plist.in:37-38`.

### M2 — Directory-creation errors discarded; unwritable iCloud path still mounted (medium)
`PathForICloudDocuments()` calls `createDirectoryAtURL:...error:nil` and unconditionally returns the path even if creation failed; `MountUserFilesystems` ignores per-subdir failures and mounts regardless. A provisioned-but-not-yet-writable container (quota, transient error, account just signed in) yields a silent no-content state with only one `NSLog` of the chosen root. **Fix:** Capture the `NSError`; on failure (or a failed write-probe) fall back to the always-writable sandbox and log it. `src/arch/ArchHooks/ArchHooks_tvOS.mm:208, 243-248`.

### M3 — No `NSMetadataQuery`; new synced items not observed until relaunch (medium)
Raw `readdir` cannot track ubiquitous item names or download state, so items synced in while the app is running are not seen until the next boot scan. **Fix:** Use a live `NSMetadataQuery` (ubiquitous documents scope). `src/arch/ArchHooks/ArchHooks_tvOS.mm:254-260`.

### M4 — `DEVELOPMENT_TEAM` frozen at configure time and cached (medium)
`$ENV{TVOS_DEV_TEAM}` is baked into the generated `.xcodeproj` at configure time; the `tvos:configure` mise task's file-based sources/outputs don't re-trigger on env changes, so setting the team *after* first configure leaves a stale (often empty) team and a non-iCloud build with no indication why. **Fix:** Pass the team via a `-DTVOS_DEV_TEAM` cache variable (explicit reconfigure) or document that team changes require `mise run tvos:clean && tvos:configure`. `src/CMakeLists.txt:224-225` + `mise_tasks/tvos/configure`.

### L1 — `URLForUbiquityContainerIdentifier` called synchronously on the boot thread, twice (low)
Apple documents this call as potentially time-consuming and not for the main thread; it runs on the boot thread once in `MountUserFilesystems` and again in `StartUploadServer`. First launch with a signed-in account can stall the splash. **Fix:** Resolve once on a background queue, cache the path, reuse for both. `src/arch/ArchHooks/ArchHooks_tvOS.mm:203, 290`.

### L2 — iCloud root recomputed independently in mount vs. upload server (low)
Both paths read `ITGmaniaUseICloud` and call `PathForICloudDocuments()` separately rather than sharing a cached value, so a future refactor that defers `StartUploadServer` could let the two roots diverge (uploads land where the game never mounts). Practically near-zero today since the calls are microseconds apart. **Fix:** Resolve the root once and pass it to both consumers. `src/arch/ArchHooks/ArchHooks_tvOS.mm:222-238, 285-295`.

### L3 — `GetAppSetting` default disagrees with mount logic; Settings.bundle default never registered (low)
The mount path treats nil `ITGmaniaUseICloud` as **on**; the generic `GetAppSetting()` maps nil to `""` (**off**). `<DefaultValue>true</DefaultValue>` is never `registerDefaults:`'d. Latent today (only `ITGmaniaThemeReset` uses `GetAppSetting`), but any future read of this key via that API gets the wrong default. **Fix:** `registerDefaults:@{@"ITGmaniaUseICloud":@YES}` at launch and simplify the nil-special-casing. `ArchHooks_tvOS.mm:226-227, 298-321`; `Settings.bundle/Root.plist:24-25`.

### Info-level observations (no code change required)
- **tvOS does not render the Settings.bundle**, so the "Use iCloud Drive" toggle is effectively unreachable on Apple TV — users are stuck at the default. If the toggle must be user-changeable, surface it via in-app UI. *(ux-settings)*
- `UIFileSharingEnabled` (`Info-tvOS.plist.in:51-52`) and `LSSupportsOpeningDocumentsInPlace` (`53-54`) are **iOS/iPadOS-only no-ops on tvOS** — harmless but dead. Remove or annotate.
- `NSUbiquitousContainers` metadata is **read-once at first registration**; rebrand churn can leave testers with stale/invisible containers. Delete + reinstall when testing visibility.
- `Root.plist:5-6` references a nonexistent `Root.strings` (no `.lproj`); dead, falls back to inline strings.
- Preference keys keep the legacy `ITGmania` prefix despite the RRRevoloution rebrand (`Root.plist:23,41`) — internal-only inconsistency.
- Footer copy "Requires an iCloud account" overstates the requirement (the app falls back to local storage) — soften if/when the toggle is ever shown.
- **Positive:** default-on iCloud is safe — `wantICloud = (useICloud == nil) || boolValue` plus the empty-path → `PathForDirectory(NSDocumentDirectory)` fallback means a first launch with no iCloud account degrades gracefully (`ArchHooks_tvOS.mm:224-238, 286-294`).
- **Prerequisite (not a repo defect):** entitlements only work at runtime if the App ID `com.northisup.rererevoloution` has iCloud enabled, the container `iCloud.com.northisup.rererevoloution` is registered, and both are in the provisioning profile. Document this.

## 4. "Appropriate settings" checklist

Every entitlement / plist key / build setting required for iCloud Drive on tvOS:

| Item | Required value | Status | Location |
|---|---|---|---|
| `com.apple.developer.icloud-container-identifiers` | `iCloud.com.northisup.rererevoloution` | ✅ PRESENT | entitlements:7 |
| `com.apple.developer.icloud-services` | includes `CloudDocuments` | ✅ PRESENT | entitlements:9-12 |
| `com.apple.developer.ubiquity-container-identifiers` | `iCloud.com.northisup.rererevoloution` | ✅ PRESENT | entitlements:15 |
| `CFBundleIdentifier` | `com.northisup.rererevoloution` | ✅ PRESENT | Info-tvOS.plist.in:12 |
| `NSUbiquitousContainers` dict keyed by container id | dict | ✅ PRESENT | Info-tvOS.plist.in:41 |
| `NSUbiquitousContainerIsDocumentScopePublic` | `<true/>` | ✅ PRESENT | Info-tvOS.plist.in:43-44 |
| `NSUbiquitousContainerName` | `${SM_EXE_NAME}` | ✅ PRESENT | Info-tvOS.plist.in:45-46 |
| `NSUbiquitousContainerSupportedFolderLevels` | `Any` | ✅ PRESENT (correct for deep Songs nesting) | Info-tvOS.plist.in:47-48 |
| `XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS` | `${SM_XCODE_DIR}/RRRevoloution-tvOS.entitlements` | ✅ PRESENT | CMakeLists.txt:218-219 |
| `XCODE_ATTRIBUTE_CODE_SIGN_STYLE` | `Automatic` | ✅ PRESENT | CMakeLists.txt:222-223 |
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.northisup.rererevoloution` | ✅ PRESENT (matches CFBundleIdentifier) | CMakeLists.txt:221 |
| `XCODE_ATTRIBUTE_DEVELOPMENT_TEAM` | a real team id | ⚠️ PRESENT but sourced from unset `$ENV{TVOS_DEV_TEAM}`, no guard | CMakeLists.txt:224-225 |
| Device (`appletvos`) build/archive + signed export | required to ship entitlements | ❌ MISSING (only Simulator builds exist) | `.github/workflows/tvos.yml`, `mise_tasks/tvos/*` |
| `registerDefaults:` for `ITGmaniaUseICloud` | seed `@YES` | ❌ MISSING | (no call in `src/`) |
| iCloud item download/materialization (`startDownloadingUbiquitousItemAtURL:` / `NSMetadataQuery`) | required for sync | ❌ MISSING | (no call in `src/`) |
| `NSFileCoordinator` / `NSFileVersion` coordination | required for safe ubiquity I/O | ❌ MISSING | (no call in `src/`) |
| `UIFileSharingEnabled` | n/a on tvOS (no-op) | ➖ PRESENT but inert | Info-tvOS.plist.in:51-52 |
| `LSSupportsOpeningDocumentsInPlace` | n/a on tvOS (no-op) | ➖ PRESENT but inert | Info-tvOS.plist.in:53-54 |
| Apple Developer portal: App ID iCloud capability + registered container + profile | required out-of-band | ❓ UNVERIFIABLE from repo (document it) | external |

## 5. Recommended next actions (ordered by impact-over-effort)

1. **Add iCloud item materialization (H1).** Highest impact: without it the feature simply does not deliver content on a second device. Drive `NSMetadataQuery` / `startDownloadingUbiquitousItemAtURL:` before mounting and gate the song scan on download completion. *(Also resolves M3.)*
2. **Add a signed `appletvos` device build/export to CI (H2).** Without it nothing iCloud-capable ever ships. Add `archive` + `exportArchive` with an `ExportOptions.plist` and release the `.ipa`; keep the simulator job as a smoke test.
3. **Verify remote iCloud-Drive surfacing on real hardware (M1).** Cheap, and it determines whether the whole approach is viable on tvOS before investing further; correct the misleading comments either way.
4. **Coordinate ubiquity I/O with `NSFileCoordinator`/`NSFileVersion` (H3).** Protects scores/profiles from loss once multi-device sync is real.
5. **Harden the build/devex (M2, M4, L1–L3):** fall back to sandbox on dir-create failure with logging; pass `TVOS_DEV_TEAM` as a cache var (or add a configure-time guard); resolve the container once off the main thread and cache it; `registerDefaults:` to unify the toggle default.
6. **Cleanup (info):** remove the two inert iOS-only plist keys, drop or populate `StringsTable`, and decide on the `ITGmania*` key prefix before there is an installed base to migrate.

## 6. Manual verification steps (real Apple TV)

You need: two Apple TVs signed into the **same** Apple ID with iCloud Drive on, plus a Mac or iPhone/iPad on that Apple ID, and an iCloud-capable **device** build (see action #2).

1. **Prereqs:** In the Apple Developer portal confirm the App ID `com.northisup.rererevoloution` has iCloud enabled, the container `iCloud.com.northisup.rererevoloution` is registered and associated, and the tvOS provisioning profile embeds it. Build with `TVOS_DEV_TEAM` set to a real team, signed for `appletvos`.
2. **Container registration:** Launch the app on Apple TV #1 with iCloud on. On the Mac (Finder → iCloud Drive) or iOS Files app, confirm a folder named after `NSUbiquitousContainerName` (the exe name) appears with a `Documents` subfolder. If it never appears, tvOS is not registering the document-scope container — the approach needs rework (M1).
3. **Add a song from another device:** Drop a song pack into that `Documents/Songs/<Pack>/<Song>` folder via Mac Finder / iOS Files / icloud.com. Wait for it to finish uploading.
4. **First-device read:** Restart the app on Apple TV #1 and confirm the song appears in the song wheel and plays. (This is the originating-device-local path; it should already work today.)
5. **Second-device sync (the H1 test):** On Apple TV #2, launch the app. Confirm the song from step 3 appears and plays. **Expected to FAIL with the current code** — the item arrives as a `.icloud` placeholder and the POSIX driver cannot read it. After implementing materialization, it should download and appear (allow time on first launch).
6. **Eviction behavior:** Fill Apple TV #2's storage (or wait for the OS to purge) so the song is evicted to a placeholder, then relaunch. Confirm the app re-downloads it rather than showing the song as missing. With current code the song silently disappears.
7. **Conflict/score integrity (H3):** Play and earn a score on both Apple TVs while both are online, then let them sync. Confirm scores are merged rather than one overwriting the other / a conflict file appearing. Current code has no `NSFileVersion` handling, so expect lost scores.
8. **Fallback:** Sign out of iCloud (or set the device to no account) and launch. Confirm the app still starts and uses local sandbox Documents (graceful degradation) — this should pass today.
