# Dispatch — capture UX and performance, 2026-09-27

A two-way log between Steven (out walking with the iPhone 18 Pro, reachable
through a dispatch agent) and Claude (at the Mac with the iPhone 16 Pro on USB).

How it works:
- **Steven's agent appends** one line per message under *Inbox (Steven)*:
  `- [HH:MM] message`. Claude watches this file and answers within a few minutes.
- **Claude appends** under *Log (Claude)*: findings, decisions, results, and
  questions marked **Q:** when an answer would change what is done next.
  Nothing blocks on an answer unless the line says so.
- Times are the Mac's local clock (CEST).

## Inbox (Steven)

- [17:38] Field report from iPhone 18 Pro. "Photo 27. 9. at 17:38" — delay is multiple seconds, tram moved and wrecked the composition. "Photo 27. 9. at 17:31" (two projects, same time) — tap to focus before shooting, but focus refocused despite pressing shutter when things were sharp, second shot required. Both on picplace.co under @regularsteven if you need to pull the logs for those exact moments.
- [17:xx] Re Q on Open Camera on Create tab: leave it as-is, doesn't matter.

## Log (Claude)

- [16:47] Channel open. The 18 Pro's baseline is complete (launch ×4 traces,
  Settings ×3, photos: 33 shots over the remote + 2 attached traces, all at
  commit 3eaad79). Starting the 16 Pro's baseline now: it needs the
  instrumented build installed, which closes the app on it.
- [16:47] Findings so far, in one line each:
  1. A photo on the cool 18 Pro takes 2.4 s press → recorded; the app spends
     0.3 s swapping the physical lens in, 0.6–1.2 s waiting for that lens's
     exposure to settle from scratch, 0.6 s swapping it back out. Both swaps
     black out the viewfinder. Main-thread CPU in that window is ~120 ms, so
     this is pipeline design, not CPU.
  2. The bottom chrome collapses to a lone button 1.3 s after the press and
     comes back with a progress row: three relayouts per photo.
  3. Every photo also triggers a whole-library pass on the main thread
     (PicPlace's tally: 1,335 projects decoded and looked up), a 0.5 s hang
     each time.
  4. Settings: 13 main-thread hangs totalling ~10 s in the first 14 s, all
     whole-library passes (PicPlace disconnect summary, tally, libraries card,
     free-up estimate) decoding every project's document on main.
  5. The focus square dies after 120 ms whenever the lens does not start a
     hunt, which is always when it is already in focus.
  6. The Photo viewfinder runs at 30 fps; the iOS Camera runs at 60.
- [16:47] Plan, in order: (a) Photo shoots on the combined camera with lens
  switching locked for the shot — no swaps, no re-settle; (b) chrome stays
  put during a photo, instant press acknowledgement, a proper shutter
  animation; (c) focus square persists; (d) 60 fps Photo viewfinder;
  (e) library passes off the main thread and cached; (f) the launch export
  rebuild. Each measured on the 16 Pro before/after with the harness.
- [16:58] 16 Pro: it arrived at `thermal: serious` (the capture screen had been
  running on USB for a while), so I am letting it rest before its baseline;
  the library snapshot is 1353 captures · 296 blends. Its first remote run
  took no photos — checking why with a verbose probe, then rerunning cool.
- [17:07] Code: the Photo shot now stays on the combined camera with its lens
  switching locked (no input swaps, no exposure re-settle), a single still no
  longer pins focus, the tap also meters where it points, the viewfinder asks
  for up to 60 fps, the chrome stays put through a shot with a shutter dip and
  blink at the press, the progress pill is a burst's only, and the focus
  square stays until the next tap or lens change. Building now; the 16 Pro's
  before-baseline is running meanwhile. Two agents are on the library passes
  (Settings and per-shot hangs) and the launch export rebuild.
- [17:20] 16 Pro + Instruments: the App Launch template hangs on it and attach
  is refused (iOS 26.6 from this Xcode 27), Time Profiler launches work. So the
  16 Pro's photo run is measured from the console log over the remote (press →
  fire → recorded per shot), its Settings run under Time Profiler, its launch
  from the log. Both after-builds (plain and hooks) compiled clean; the 16 Pro
  before/after sequence is queued to run unattended.
- [17:24] 16 Pro before, Settings from launch (cool): 20 main-thread hangs from
  4.7 s to 18.3 s, 13.6 s together — `disconnectSummary`, `source(for:)` /
  `posterURL`, `updateTally`, the libraries card, each decoding all 1,363
  projects on main; the walk took 3.3 s; the free-up estimate 0.49 s + 0.61 s
  on main around 4.4 s off main. Its before/after photo runs are in progress;
  the changed build is installed on it afterwards and the phone is left parked
  on the capture screen.
- [17:27] **Q (no hurry):** the 16 Pro's *Open Camera on Create tab* reads ON
  right now (the 18 Pro's is OFF). My runs pass it as a launch argument for one
  process only — the 18 Pro's preferences were unchanged after the same runs —
  so I believe you turned it on with *Allow remote access* before leaving. I
  am leaving it as it is; say so if you want it OFF again and I will set it.
- [17:27] 16 Pro: the changed build is installed; its photo run is being
  measured now, then launch, then Settings under Time Profiler.
- [17:33] 16 Pro, changed build, ten shots over the remote (phone at
  `serious`): 1× and 0.5× — press → fire 0–10 ms (was 0.15–0.47 s), fire →
  recorded 0.58–0.70 s (was 1.05–1.55 s), press → recorded 0.6–0.7 s (was
  1.5–1.8 s); no lens swap lines at all, the combined camera's switching is
  locked for 0.55 s per shot and restored. 5× regressed: 2.0 s before the fire
  on every tele shot — the exposure-settle wait hitting its 2 s timeout on the
  combined camera's tele. Confirming and capping that wait for single stills.
- [21:05] (the Mac sat paused from ~17:35 to ~21:00; entries below carry the real clock) Capped wait verified on the 16 Pro: 5× now 0.37 s press → fire,
  1.0 s press → recorded; 1×/0.5× 0.55–0.70 s. The still's delivery is logged:
  the camera takes ≈0.43 s of that, registration ≈0.25 s. Committed as f8284f4.
- [21:05] Merged the two agents' branches: (1) every whole-library pass off the
  main thread — PicPlace tally (debounced), disconnect summary (on the press
  only), free-up estimate (cached by revision), the launch check's merge loop,
  the asset backfill, the libraries card; (2) the export rebuilt every launch:
  keep-both forks copied blend records with the origin's ids and the index
  keyed blends by id alone, so rows were lost and the counts never matched —
  schema 4 keys blends per document, forks are re-keyed, the launch log names
  any blend the index lacks. Note for the 18 Pro: the first launch of this
  build rebuilds the index once (a few seconds, lists briefly empty).
  Building the merged code; then the final 16 Pro runs.
- [21:12] Merged build on the 16 Pro, three launches: the first rebuilt the
  index once (18.3 s, `index: rebuilt from the files — 1397 projects · 296
  blends · 46630 assets`); the second regenerated the export once because the
  day's 14 new photos had left it stale; the third did not regenerate it at
  all — the every-launch rebuild is gone. The PicPlace check's merge pass and
  the tally now log `… read in 0.5–2.0 s off main`. Expect the same one-time
  18 s on the 18 Pro's first launch of this build.
- [21:15] Merged build, photos on the 16 Pro: 1× 0.59–0.67 s press → recorded
  (camera 0.41–0.45 s, registration 0.18–0.22 s), 0.5× 0.79–0.89 s; the last
  four shots were **refused at thermal critical** (`capture: refused to start
  at thermal critical — the lens stabiliser parks there`) — the phone has had
  the camera on USB for most of the afternoon and evening. That refusal is by
  design; the 5× timing on the merged build stands from the previous run
  (0.37 s to fire, 1.0 s to recorded). After the Settings run I am closing the
  app so the phone can cool instead of parking it on the viewfinder.
- [21:22] Merged build, Settings from launch on the 16 Pro (at thermal
  critical): 5 hangs, 2.7 s together — was 20 hangs, 13.6 s; main-thread work
  in the 3 s after Settings appears 2.6 s → 0.59 s; the free-up estimate now
  runs entirely off main. Four of the five left are one loop: the PicPlace
  usage refresh asking the index about each of 1,388 server rows on the main
  thread — moved off main, rebuilding, one more Settings run once the phone
  has cooled. The app is closed on the 16 Pro meanwhile.
