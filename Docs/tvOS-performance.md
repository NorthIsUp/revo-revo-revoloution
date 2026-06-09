# Apple TV (tvOS) Performance — Review & Recommendations

## 1. Executive Summary

**Can RRRevoloution hold a hitch-free, audio-synced 60fps on Apple TV today? No — not reliably, and not by design.** The tvOS port inherits StepMania's desktop assumptions in the two places a rhythm game cannot afford them: the **frame-present path** and the **memory model**. Both are structurally wrong for a fanless, jetsam-constrained A-series box.

The single largest defect is the presentation architecture in `src/arch/LowLevelWindow/LowLevelWindow_tvOS.mm:153-356`. Instead of rendering into a CAEAGLLayer and calling `presentRenderbuffer` (the idiomatic, vsync-synchronized, zero-copy GLES path), the port renders to an **offscreen FBO** and ships pixels to a `UIImageView` — either via a per-frame full-frame `glReadPixels` + ~8.3 MB `malloc` + CPU row-flip + `CGImage`/`UIImage` build (readback/simulator path), or via `glFlush` + `dispatch_async` layer-contents swap (CV path on device). **Neither path is synchronized to the 60 Hz panel.** `FrameLimitPercent` defaults to `0.0` (`src/RageDisplay.cpp:68`), `SwapBuffers` never blocks, and `GameLoop::RunGameLoop` (`src/GameLoop.cpp:293-315`) free-runs. The result is uneven frame delivery and jittery delta-times feeding the judgment engine — exactly what causes missed/misjudged steps — plus an uncapped loop that pegs the CPU and thermally throttles a fanless box. On desktop GL there is also an unconditional per-frame `glFinish()` (`src/RageDisplay_OGL.cpp:921`) that hard-serializes CPU/GPU.

The second systemic risk is **memory / jetsam**. There is **no memory-pressure handling anywhere** (no `didReceiveMemoryWarning`, no `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`; `SMMain_tvOS.mm:131-145` lifecycle methods are empty stubs), so tvOS escalates straight to killing the app rather than the app shedding caches. The FFmpeg movie decoder preallocates a fixed 50-frame ring **and** retains the entire compressed packet stream (`MovieTexture_FFMpeg.cpp:136-139, 217-239`), textures upload uncompressed 32-bit RGBA with no ASTC/ETC2 (`RageDisplay_GLES2.cpp:707-745`), and the image/banner caches are unbounded and library-size-proportional. The two most likely kill points: **entering gameplay on a movie-background song**, and **a song-select screen over a large iCloud library**.

The third risk is **iCloud I/O on timing-critical threads**. User content now lives in the ubiquity container, mounted with the plain `dir` driver and **zero download-on-demand coordination** anywhere in the tree. Gameplay music streams with `precache=false` (`GameSoundManager.cpp:144`), so a mid-song eviction/download stall can starve the audio buffer and break A/V sync.

The core music clock (`mach_absolute_time`-based, `RageSoundDriver_AU.mm`) is sound. But there is **no `AVAudioSession` configuration at all**, the driver runs 44.1k against 48k hardware (forcing realtime SRC), and `GetPlayLatency()` ignores HDMI/AVR output latency — so latency compensation fires early.

**Bottom line:** the boot path is slow-but-survivable; the *gameplay* path is where smoothness and sync break. The top wins are: a real vsync-locked present path, frame pacing, a memory-pressure handler, bounding the movie decoder, and pinning gameplay audio locally before play.

---

## 2. Per-Subsystem Assessment

| Subsystem | Health | Notes |
|---|---|---|
| Startup / boot | 🟠 At risk | Serial single-thread boot; black screen entire boot (`LoadingWindow_Null`, no UI); blocking iCloud container resolution called **twice** (`ArchHooks_tvOS.mm:203, :290`). Survivable but slow; cold first-launch could approach watchdog. |
| Song loading / cache | 🔴 Poor | Whole library parsed up-front and held resident; caches live in **purgeable** `NSCachesDirectory` (`ArchHooks_tvOS.mm:262-273`) → random full-reparse cold boots; `LOW_RES_PRELOAD` holds every banner resident; uncapped thread pool. |
| Rendering | 🔴 Poor | Offscreen FBO → UIImageView present, no CAEAGLLayer/vsync; client-side vertex arrays + per-quad `std::vector` + full state thrash per draw (`RageDisplay_GLES2.cpp:1041-1109`); uncompressed 32-bit textures. |
| Audio sync | 🟠 At risk | Core clock is correct; but **no `AVAudioSession`**, 44.1k↔48k SRC on realtime thread, `GetPlayLatency()≈0` over HDMI, no interruption/route-change handling. |
| Memory / jetsam | 🔴 Poor | No memory-pressure handler at all; movie decoder ~100MB+ resident; unbounded texture & image caches; desktop texture defaults (32-bit, 2048). Most likely kill source. |
| iCloud I/O | 🔴 Poor | Plain `dir` driver over ubiquity container; **zero** download-on-demand coordination; gameplay music streams from iCloud (`precache=false`); `.icloud` placeholders break globs; render-thread banner reads can stall. |
| Threading / pacing | 🟠 At risk | Game logic correctly off the UIKit thread and loading parallelized (good), but the present/pacing path is the dominant hitch source: free-running loop, `glFinish`, per-frame readback/UIImage churn. |

---

## 3. Prioritized Recommendations (sorted by impact-over-effort)

| Title | Area | Impact | Effort | File | Expected gain |
|---|---|---|---|---|---|
| Add tvOS memory-pressure + backgrounding cache purge | Memory | High | Low | `SMMain_tvOS.mm:131-145`; `RageTextureManager.cpp:266`; `ImageCache.cpp` | Converts jetsam kills into graceful eviction; survives pressure spikes mid-song |
| Remove per-frame `glFinish()` (guard out on tvOS) | Threading | Med | Low | `RageDisplay_OGL.cpp:921` | Restores CPU/GPU overlap; reclaims several ms/frame of game-thread idle |
| Run audio chain at 48 kHz; drop `kRenderQuality_Max` | Audio | Med | Low | `RageSoundDriver_AU.mm:162,172,190-197` | Removes per-callback SRC from realtime thread; steadier IO CPU |
| Default banner cache to `LOW_RES_LOAD_ON_DEMAND` on tvOS | Song-load | Med | Low | `PrefsManager.cpp:182`; `Song.cpp:445-449` | Drops boot RAM + frees banners before gameplay |
| tvOS texture defaults: 1024 max + 16-bit | Memory | Med | Low | `StepMania.cpp:404-413` | ~4× per-texture resident-byte reduction for BG/banners |
| Cap loader thread pool; offload group-banner decode | Song-load | Med | Low | `SongManager.cpp:474,668` | Less iCloud I/O thrash + thermal load; shorter boot |
| Bound the movie decoder (shrink ring, stream demux) | Memory | High | Med | `MovieTexture_FFMpeg.cpp:136-139,217-239` | Cuts worst-case ~100-400MB alloc → tens of MB; removes top gameplay kill |
| Add real frame pacing / vsync wait (CADisplayLink) | Threading | High | Med | `GameLoop.cpp:300-315`; `RageDisplay.cpp:838-874` | Stable ~16.7ms frames; less thermal throttle; tighter sync |
| Pin gameplay audio locally before play (precache/download) | iCloud | High | Med | `GameSoundManager.cpp:144,306`; `RageSound.cpp:218-219` | Eliminates mid-song underruns / sync breakage from iCloud stalls |
| Batch draws through a VBO; stop per-draw state thrash | Rendering | High | Med | `RageDisplay_GLES2.cpp:1041-1137` | Large per-frame CPU draw-submission cut; fewer spikes |
| Cap/disable background movies on tvOS (pref) | Rendering | High | Med | `MovieTexture_FFMpeg.cpp`; `RageDisplay_GLES2.cpp:747-758` | Lower gameplay GPU overdraw + CPU decode; less throttling |
| Report true output latency (HDMI/AVR) | Audio | Med | Med | `RageSoundDriver_AU.mm:243-255` | Correct latency compensation for assist/keysounds/start |
| Configure `AVAudioSession` (category/buffer/rate) | Audio | Med | Med | `RageSoundDriver_AU.mm:122-211` | Deterministic low latency; non-ducked routing |
| Handle interruptions/route-changes/media-reset | Audio | Med | Med | `RageSoundDriver_AU.mm:206`; `AU.h:39` | Prevents silent audio death on route/HDMI changes |
| Eliminate per-frame readback `malloc`s (ring buffer) | Threading | Med | Med | `LowLevelWindow_tvOS.mm:302,328,335` | Removes ~8MB×(1-2) malloc/free + full-frame CPU copy per frame |
| GPU fence before publishing IOSurface (CV path) | Rendering | Med | Low | `LowLevelWindow_tvOS.mm:258-268` | Removes intermittent torn/partial frames |
| Stop per-quad `std::vector` alloc in draw path | Rendering | Med | Low | `RageDisplay_GLES2.cpp:1092-1109` | Removes per-sprite heap alloc; cuts allocator micro-hitches |
| Move `/Cache` out of purgeable `NSCachesDirectory` | Song-load | Med | Med | `ArchHooks_tvOS.mm:262-273` | Eliminates random full-library reparse cold boots |
| Bound ImageCache resident surfaces (LRU/byte budget) | Memory | Med | Med | `ImageCache.cpp:60,478-480` | Bounds song-select memory independent of library size |
| Aggregate cap on preloaded sound buffers | Memory | Med | Low | `RageSoundReader_Preload.cpp:23-24` | Caps audio residency for keysound-heavy charts |
| RageTextureManager byte budget + LRU | Memory | Med | High | `RageTextureManager.cpp:266-312` | Hard ceiling on texture residency for asset-heavy themes |
| Replace offscreen-FBO present with CAEAGLLayer + `presentRenderbuffer` | Rendering | High | High | `LowLevelWindow_tvOS.mm:153-356` | Removes readback/malloc/flip churn; foundation for true vsync |
| Upload textures GPU-compressed (ASTC/ETC2) | Rendering | High | High | `RageDisplay_GLES2.cpp:707-745` | 4-8× texture memory + bandwidth reduction |
| Incremental/lazy per-group library loading | Song-load | High | High | `SongManager.cpp:274-678` | Time-to-interactive = one group; memory scales with browsed groups |
| iCloud download coordination + prefetch (+timeout wrap) | iCloud | High | High | `ArchHooks_tvOS.mm:254-260`; `RageFileDriverDirect.cpp` | Converts unbounded sync stalls into prefetched resident reads |
| Resolve iCloud container once / off boot path | Startup | Med | Med | `ArchHooks_tvOS.mm:199-210,229,290` | Removes duplicate blocking call; cuts time-to-first-frame |
| Native UIKit loading overlay (kill black screen) | Startup | Med | Med | `LoadingWindow.cpp:18-19`; `SMMain_tvOS.mm:18-21` | Eliminates "looks hung" black boot; shows progress |
| Defer iCloud subdir creation off boot mount | Startup | Med | Low | `ArchHooks_tvOS.mm:208,243-248` | Removes ~8 sync coordinated-FS ops from boot |
| Handle `.icloud` placeholders in dir scans | iCloud | Med | Med | `RageFileDriverDirectHelpers.cpp:277-314` | Stops songs vanishing as iCloud evicts cold files |
| Reuse input-event vector (avoid per-frame realloc) | Threading | Low | Low | `StepMania.cpp:1355-1363`; `InputFilter.cpp:450-453` | Removes small recurring alloc from input→judgment path |
| Guard `IMGCACHE_FULL` preload on tvOS | Memory | Low | Low | `SongManager.cpp:719-752` | Prevents guaranteed jetsam kill if user enables full cache |

---

## 4. Top 5 "Do These First"

### 1. Add a tvOS memory-pressure handler + backgrounding cache purge — *High impact, Low effort*
**Current:** `SMMain_tvOS.mm:131-145` implements `applicationWillResignActive` / `DidEnterBackground` / `WillEnterForeground` / `DidBecomeActive` as empty bodies; terminate only sets a quit flag. A repo-wide grep for `didReceiveMemoryWarning` / `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` / `os_proc_available_memory` returns **nothing**. The app never voluntarily sheds memory, so tvOS jetsams it outright.
**Change:** Install a `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` source (and/or observe `UIApplicationDidReceiveMemoryWarningNotification`). On WARN/CRITICAL, **post to the game thread** (do not mutate texture/image state from the UIKit callback — `RageTextureManager` is not thread-safe and the warning fires on the main thread) to run `TEXTUREMAN->DeleteCachedTextures()`/`DoDelayedDelete()` (`RageTextureManager.h:73,76`) and `IMAGECACHE->UnloadAllImages()` (`ImageCache.cpp:184`) when not on song-select, drop `SongManager::m_TexturePreload`, and free refcount-0 preloaded sounds. On `applicationDidEnterBackground`, purge non-essential caches. Run the GC at a frame boundary, never mid-frame.
**Why:** A jetsam kill mid-song is the worst possible failure for this game. This is the cheapest path from "hard crash" to "graceful, observable cache churn," and is the safety net the other memory recs lean on.

### 2. Bound the FFmpeg movie decoder — *High impact, Med effort*
**Current:** `MovieDecoder_FFMpeg` ctor unconditionally preallocates **50** `FrameHolder`s (the inline comment literally says "Roughly translates to 100mb of ram", `MovieTexture_FFMpeg.cpp:136-139`), and `HandleNextPacket()` appends a `PacketHolder` per packet until EOF, setting `total_frames_ = packet_buffer_.size()` — i.e. the **entire compressed video** is held in RAM (`:217-239`). No platform/resolution gating; identical on tvOS and desktop. A looping background fills the whole ring.
**Change:** Gate the decode ring behind `TARGET_OS_TV` and shrink it to ~4-8 frames (better: size from a byte cap, not a frame count). The ring already uses `frame_buffer_.size()` as the modulus (`:201,:258`) and a shrink branch exists (`:240-243`), so the reduction is low-risk. Longer term, switch to streaming demux with a bounded packet window instead of buffering every packet (note: looping/seek depend on packet timestamps, so this part is more invasive).
**Why:** This is the most likely **gameplay** jetsam-kill — entering a movie-background song. Cutting the worst case from ~100-400MB to tens of MB frees budget for stable 60fps.

### 3. Add real frame pacing / a vsync wait — *High impact, Med effort*
**Current:** `TryVideoMode` advertises `vsync=true`/`rate=60` (`LowLevelWindow_tvOS.mm:230-231`) but nothing enforces it. `SwapBuffers` (`:254`) returns immediately (CV path: `glFlush` + `dispatch_async`). `FrameLimitPercent` defaults to `0.0` (`RageDisplay.cpp:68`), so `FrameLimitBeforeVsync` (`:838-874`) is a no-op during focused gameplay. `RunGameLoop` (`GameLoop.cpp:300-315`) spins uncapped, feeding `g_GameplayTimer.GetDeltaTime()` highly variable deltas (`GameLoop.cpp:257-259`).
**Change:** Drive `Update`/`Draw` from a `CADisplayLink` locked to the panel refresh (`preferredFrameRateRange` = 60), or add per-present backpressure so at most one frame is in flight. As an interim, set a per-frame deadline sleep or non-zero `FrameLimitPercent`. (Note: the "presentRenderbuffer provides vsync back-pressure" framing assumes a CAEAGLLayer this port does not yet have — pace via CADisplayLink/deadline here, not presentRenderbuffer.)
**Why:** A fanless A-series box running uncapped throttles thermally and drops frames late in a session; variable delta-times directly degrade step timing. Panel-locked cadence is the single most important property for judgment accuracy.

### 4. Pin gameplay audio locally before play — *High impact, Med effort*
**Current:** `StartMusic()` on the MusicThread calls `pSound->Load(ToPlay.m_sFile, false, &params)` — `bPrecache=false` (`GameSoundManager.cpp:144`, also `:306`). `RageSound::Load` leaves the source file-backed in `RageSoundReader_ThreadedBuffer` (`RageSound.cpp:218-219`); the `.ogg` is read incrementally during play via blocking POSIX reads (`RageFileDriverDirect.cpp:393-401`) with no iCloud awareness. The streaming buffer is ~128K frames (~3s); a multi-hundred-ms iCloud download/eviction stall mid-song underruns it.
**Change:** Before gameplay starts (at song-select / screen transition), call `-[NSFileManager startDownloadingUbiquitousItemAtURL:error:]` on the music (and chart/BG) file and block the **non-realtime** load on a bounded wait for `NSURLUbiquitousItemDownloadingStatusKey == Current` (NSMetadataQuery or polling). Surface a brief "downloading…" state rather than starting a song whose bytes aren't local. Optionally force `bPrecache=true` once confirmed resident (caveat: a decoded multi-minute stereo song is ~80MB — weigh against jetsam).
**Why:** This is the direct A/V-sync correctness hazard. The music clock vs render clock must stay drift-free; an iCloud stall on the streaming read is exactly what breaks it during the timing-critical phase.

### 5. Remove the per-frame `glFinish()` + batch draws / kill per-draw state thrash — *Med-High impact, Low-Med effort*
**Current (a):** `RageDisplay_Legacy::Present()` calls `glFinish()` unconditionally every frame (`RageDisplay_OGL.cpp:921`, comment: "we WANT to block"). On a tile-based A-series GPU this drains the whole queue and defeats CPU/GPU overlap; in the tvOS PBO present path it actively forces the just-issued async `glReadPixels` to complete synchronously, defeating its own double-buffering.
**Current (b):** Every primitive routes through `SetupShaderAndDraw` (`RageDisplay_GLES2.cpp:1041-1090`): `glUseProgram`, MVP recompute (2× `RageMatrixMultiply`), uniform uploads, `glEnableVertexAttribArray`×3, `glVertexAttribPointer` to **client memory** (no VBO → driver copies vertices every call), `glDrawArrays`, then disable×3 + `glUseProgram(0)`. `DrawQuadsInternal` also heap-allocates a fresh `std::vector` per call (`:1097`). This is the live path for *all* 2D drawing on tvOS.
**Change:** Guard out `glFinish()` on tvOS (replace with at most `glFlush`, or gate behind a debug pref). Bind the program + enable attributes once per frame; stream vertices into a persistent orphaned/ring VBO; re-upload MVP only when the matrix stack changes; reuse a scratch buffer (or a static index buffer + `glDrawElements`) for quad expansion. Verify CPU/GPU now overlap with a GL/Metal frame capture.
**Why:** Together these remove a guaranteed per-frame GPU stall plus hundreds of per-draw state-setup cycles and per-sprite heap allocations — the dominant per-frame CPU cost and a frequent micro-hitch source on dense charts/busy themes.

---

## 5. Memory Budget Risk (Jetsam) & A/V Sync Callouts

### Where jetsam is most likely to fire
1. **Entering gameplay on a movie-background song** — FFmpeg ring (50 frames) + full retained packet stream (`MovieTexture_FFMpeg.cpp:136-139,217-239`), ~100-400MB, on top of an uncompressed full-screen background texture (`RageDisplay_GLES2.cpp:707-745`). **#1 gameplay kill.**
2. **Song-select over a large iCloud library** — `LOW_RES_PRELOAD` holds a decoded surface for **every** banner resident, never evicted in preload mode (`ImageCache.cpp:60,478-480`); `Demand()` loads the *whole* library's low-res banners on screen entry (`ScreenSelectMusic.cpp:216`). Grows linearly with library size, no byte budget.
3. **Asset-heavy theme (Simply Love)** — `RageTextureManager` has no aggregate byte budget or LRU; evicts only by refcount at screen transitions (`RageTextureManager.cpp:266-312`). 2048×2048 32-bit = 16MB each.
4. **Present-queue growth (readback/simulator path)** — uncapped game thread enqueues 8MB UIImages to the main queue faster than they drain (`LowLevelWindow_tvOS.mm:302-354`). On real-HW CV path this is bounded (single reused `g_PixelBuffer`), so this is mainly a simulator/fallback risk.
5. **No pressure valve** — with no memory-warning handler (rec #1), every one of the above escalates straight to a kill instead of an eviction.

**Compounding factor:** caches live in `NSCachesDirectory` (`ArchHooks_tvOS.mm:262-273`), which tvOS purges under the *same* storage pressure — so a pressure event can both threaten a kill *and* wipe the caches that make the next boot fast.

### A/V sync risk callouts
- **iCloud stream starvation (highest sync risk):** gameplay music streams from iCloud with `precache=false` (rec #4). A mid-song download stall underruns the buffer and desyncs note timing.
- **Unpaced render clock:** free-running loop with variable delta-times (rec #3) feeds the judgment engine jittery frame intervals.
- **Latency under-reporting:** `GetPlayLatency()≈0` on tvOS (`RageSoundDriver_AU.mm:243-255`) ignores HDMI/AVR output latency (tens to >100ms), so assist-tick / autokeysounds / beat-aligned starts fire early. Partly nulled by manual `GlobalOffset`, but route changes break it.
- **Realtime-thread SRC:** 44.1k driver vs 48k hardware forces `kRenderQuality_Max` SRC in the IO callback (`RageSoundDriver_AU.mm:162,190-197`) — steady CPU tax that raises underrun risk under thermal load.
- **Silent audio death:** no interruption/route-change/`mediaServicesWereReset` observers (`m_pNotificationThread` declared but never started, `AU.h:39`); an HDMI/AVR renegotiation can stop RemoteIO with no restart.

---

## 6. How to Measure on Apple TV

Validate every change with a **before/after** capture on **real hardware** (the simulator exercises the readback present path, not the device CV path, and has no jetsam budget). Use a known dense chart + a movie-background song as the fixed test case.

**1. Frame timing — os_signpost + Instruments "os_signpost" / "Points of Interest"**
- Instrument the loop boundaries in `GameLoop::RunGameLoop` (`GameLoop.cpp:300-315`) and `RageDisplay_GLES2::EndFrame` (`:508-518`) with `os_signpost` intervals (one per Update, one per Draw, one per SwapBuffers). Add a signpost event carrying `g_GameplayTimer.GetDeltaTime()`.
- Success = a tight cluster at ~16.7ms with **no outliers**, not a good *average*. Watch the delta-time event stream flatten after rec #3.

**2. Time Profiler (CPU)**
- Confirm `glFinish` (`RageDisplay_OGL.cpp:921`) disappears from game-thread stalls after rec #5a; confirm `SetupShaderAndDraw` / client-array copies and `DrawQuadsInternal`'s `std::vector` ctor shrink after rec #5b.
- Watch the audio IO render thread: 48k change (rec) should remove the AU SRC frames.

**3. Metal System Trace / GPU capture**
- Verify CPU and GPU work **overlap** (they cannot today, given `glFinish`). Inspect overdraw on a full-screen movie + danger overlay (rec: cap background movies). Capture a frame to confirm draw-call count drops after VBO batching.

**4. Allocations + VM Tracker**
- Track resident growth entering a movie-background song (rec #2 target) and the song wheel (rec: ImageCache/texture budget). Mark generations at screen transitions.
- Watch the per-frame ~8MB `malloc`/free in the readback path (`LowLevelWindow_tvOS.mm:302-354`) — should vanish after the ring-buffer / CAEAGLLayer work.

**5. jetsam / memory limit**
- Use the device's **Memory Limit** Instruments template (or `os_proc_available_memory()` sampled each frame, logged) to see headroom against the jetsam ceiling during gameplay and song-select. Confirm rec #1's pressure handler actually fires and reclaims before the limit.

**6. Audio latency / sync**
- Measure true output latency via `AVAudioSession.outputLatency + IOBufferDuration` once configured (rec) and compare against a clap-vs-frame capture (mic + high-speed camera, or an HDMI capture box) to validate `GetPlayLatency()` now reflects reality.

Order of validation: rec #1 (survive pressure) → #3 (stable frames) → #5 (CPU/GPU overlap) → #2/#4 (memory headroom) → #4-audio (sync). Each should move exactly one metric; if it doesn't, the change isn't doing what the analysis predicted.
