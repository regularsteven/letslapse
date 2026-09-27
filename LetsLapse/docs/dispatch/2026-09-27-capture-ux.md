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
