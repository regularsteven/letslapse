# PicPlace uploads in the background — plan

**Raised:** 2026-09-24, Steven: *"make a plan for background uploads — the
current phone-on and unlocked requirement is really limiting."* ·
**Status:** plan, not started · **Depends on:** the upload jobs built the same
day (below), and three answers from the PicPlace developer (§5).

## 1. Where uploads stand today

An 11.55 GB upload (922 originals, “Stack 23. 9. at 21:04”, iPhone 18 Pro)
ran 16:43 → 17:19 on 2026-09-24 with the phone on the table, unlocked, on
Wi-Fi, LetsLapse in front. That is the whole limitation: the PUTs run on a
foreground `URLSession` inside the app, and iOS suspends an app that leaves
the screen after the ~30 s `beginBackgroundTask` grants
(`PicPlaceBackgroundActivity`). Nine seconds after that upload confirmed, the
phone reported mobile data and went to the background. Had either happened
at minute 20, the old build would have started all 11.55 GB again.

The same day's upload jobs (`App/PicPlace/PicPlaceUploadJobs.swift`, TODO
"PicPlace uploads as jobs") made a stop cheap but not rare:

- the run confirms files **eight at a time as they finish**, and stops
  **between files** when asked — Pause, *Only on Wi-Fi* on mobile data, iOS
  about to suspend the app (the background task's expiry) — so any stop
  costs the files in flight (≤ 4) plus at most 7 finished-but-unconfirmed;
- the **job** (`meta.uploadJobs` in `PicPlace/sync-state.json`) remembers the
  rest: it resumes at launch, in front again, when the network changes, and
  after an interruption with a backoff (10 s, 30 s, 2 min, 10 min);
- *Only on Wi-Fi* holds a person's upload too; **Use mobile data** lets one
  job through, never the setting.

What is still true: **nothing moves while the phone is locked or LetsLapse
is not on screen.** The job waits, it does not upload.

## 2. What iOS offers

| Tool | What it does | Fit |
| --- | --- | --- |
| **Background `URLSession`** (`URLSessionConfiguration.background(withIdentifier:)`) | The system's transfer daemon runs the uploads outside the app: while it is suspended, while the phone is locked, even after iOS terminates it. Uploads must come **from a file** (`uploadTask(with:fromFile:)` — ours are files); delegate callbacks only, no completion handlers; the app is **relaunched in the background** when tasks finish (`application(_:handleEventsForBackgroundURLSession:completionHandler:)`, or SwiftUI's `.backgroundTask(.urlSession(_:))`). Per-request `allowsExpensiveNetworkAccess` / `allowsConstrainedNetworkAccess` carry *Only on Wi-Fi* and the per-job override. | **The durable answer** for a person's upload. |
| **`BGContinuedProcessingTask`** (iOS 26+) | A task a person starts in front that keeps **the app itself** running after it leaves the screen, with the system's own progress UI; the app must keep reporting progress, and the system (or the person) can end it. | **The quick win**: today's run code keeps going unchanged. How long it holds on a locked phone, for a 40-minute upload, is the thing to measure. |
| **`BGProcessingTask`** | Deferred work iOS runs when it chooses — typically at night, optionally only on power and network. | The **automatic** originals queue (*Upload originals automatically*), not a person's Upload. |
| `beginBackgroundTask` | ~30 s. | What we have; stays as the fallback. |
| Audio / location background modes | Keep an app alive by pretending. | **No** — App Review, battery, honesty. |

Two traps from Apple's documentation that shape the design:

- **A force-quit cancels background transfers.** Swiping LetsLapse away in
  the app switcher stops the daemon's uploads too. The job survives
  (it is on disk); the next launch resumes it.
- **Background relaunches are rate-limited.** Each time iOS wakes the app to
  deliver finished tasks, the next wake is delayed further. A design that
  hands the daemon one file, waits to be woken, then hands it the next,
  crawls. **Hand the daemon the whole job (or a large wave) at once.**
  Transfers queued while the app is in front are not discretionary; queued
  from the background, they are — another reason to queue at the press.

## 3. The design

### Stage 1 — keep the app running for a person's upload (iOS 26+, small)

When an upload job starts **from a person's press in front** (Upload,
Resume, Use mobile data), submit a `BGContinuedProcessingTaskRequest`
(*Uploading “Stack 23. 9. at 21:04” to PicPlace*, subtitle *132 of 922
files*). Feed the run's `PicPlaceSyncProgress` into the task's `Progress`
(bytes). End it when the job finishes, pauses or waits for Wi-Fi. Its
expiration handler is today's `onExpire`: stop between files, hold
`.interrupted`, resume in front. Availability-gated — the floor stays iOS 17,
where today's behaviour continues. Check against the SDK before building:
the request's identifier pattern in `BGTaskSchedulerPermittedIdentifiers`
(a wildcard suffix per job), the submission strategy (queue vs fail when the
system declines), and whether a job resumed automatically (a network change,
not a press) may submit one.

What it buys: lock the phone, pocket it, and the upload keeps going for as
long as iOS allows, with its progress on the Lock Screen. What it doesn't:
a guarantee. Measure it (§6) before deciding how much of Stage 2 is urgent.

### Stage 2 — the daemon does the PUTs (the durable one, medium)

- **One background session per library**, identifier
  `com.regularsteven.letslapse.picplace.uploads.<library uuid>`, created at
  launch and again on a background relaunch; its delegate lives on the
  controller for that library (a library switch must not orphan it).
- **A job's run becomes: claim → negotiate → hand off → release.** Negotiate
  as today (confirmed files come back *unchanged* and are skipped), then
  hand every pending PUT to the session in one go — `uploadTask(with:
  request, fromFile: url)`, the request carrying the presigned headers
  exactly as signed, `taskDescription` = job id · asset id · name · sha256 —
  and release the claim: the PUTs need no claim, the server signed them.
- **A small transfer table**, `PicPlace/transfers.json`: task id → asset id,
  name, sha256, bytes, job id, state (sent / finished / failed). It is the
  truth across relaunches; `session.getAllTasks` rebuilds what is still
  running if it is lost.
- **Confirming.** Finished tasks are confirmed in batches — eight at a time
  while in front (as now), everything finished on a background wake — each
  batch is claim → `assets/confirm` → release. The completion handler iOS
  passed in is called only after the wake's confirm lands (or fails and is
  left for the next wake).
- **The Wi-Fi rule moves into the requests.** `allowsExpensiveNetworkAccess
  = job.allowsMobileData || !wifiOnly` (and constrained) per task: on mobile
  data the daemon simply doesn't run those tasks; back on Wi-Fi it does —
  the phone in a pocket walking out of the house needs no app code at all.
  Turning *Only on Wi-Fi* on or off, or pressing *Use mobile data*, re-issues
  the job's unfinished tasks with the new flag (cancel + hand off again;
  finished ones are kept).
- **Pause** cancels the job's unfinished tasks and keeps the job; **Resume**
  negotiates again (confirmed skipped; finished-but-unconfirmed confirmed
  first from the table) and hands off the rest. **Cancel** cancels and drops
  the job, keeping what is confirmed.
- **Progress** comes from `urlSession(_:task:didSendBodyData:…)` in front and
  from the table after a wake — the card and the drawer read the job, not a
  live run.
- **An expired URL** (403 on a task) → that asset is re-negotiated at the
  next wake or in front and handed off again.
- **The Mac** keeps the foreground session — it is never suspended — unless
  one code path is simpler; decide while building.

**The one hard constraint is the URL lifetime.** Presigned PUTs last
**60 minutes** (`letslapse.storage.upload_url_minutes`, advertised as
`upload_url_ttl_seconds` in `/status`). Handing the daemon 922 files at once
means the last ones may start hours later — at 2 MB/s, 11.55 GB takes 1 h 40.
Either the server signs longer (§5 ask 1, preferred), or the client hands
off in **waves** sized to finish inside the lifetime at the measured pace
(bytes/s × 45 min), topping up at each wake — which the relaunch rate limit
throttles. Waves are the fallback, not the plan.

### Stage 3 — the automatic originals queue at night (small, after Stage 2)

Register a `BGProcessingTask` (requires network; power optional, a setting
later) that runs the originals walk — negotiate each project and hand its
PUTs to the Stage 2 session — so *Upload originals automatically* works on a
phone charging overnight, not only while LetsLapse is open. The walk's
existing rules stand: one project at a time, stops on a pause, never on
mobile data unless the person switched *Only on Wi-Fi* off.

## 4. What does not change

The job model, the card's and drawer's lines (*Uploading · 132 of 922 files*,
*Waiting for Wi-Fi — Use mobile data*, *Upload paused — Resume*), the
confirm-then-verify contract (a file counts as on PicPlace only when
`verified`), the claim (held only while talking to the API), free up space's
per-file check. Stage 2 swaps the engine under the job, not the job.

## 5. What PicPlace needs (asks for the developer)

1. **A longer upload URL for background transfers** — 12–24 h, e.g. a
   `ttl_seconds` the client may ask for on negotiate (capped server-side), or
   a bulk re-sign: `POST /projects/{uuid}/assets/resign {ids}` → fresh URLs
   for pending assets. Without one of these, Stage 2 needs waves.
2. **Confirm needs the claim** (`claimHeldBy($device)` in
   `AssetController::confirm`). That works — a wake claims, confirms,
   releases — but a claim held by another device then blocks confirming
   uploads that already finished. Could a pending asset be confirmed by the
   device that negotiated it without the claim? If not, we retry at the
   next wake, which is acceptable.
3. **Keep pending uploads until confirmed.** Today nothing purges them
   (`letslapse:reconcile-storage` treats pending objects as held). A phone in
   a drawer for a week must still be able to confirm what it sent. Tell us
   if a window is ever introduced.
4. **Optional: "already uploaded" on negotiate.** After a force-quit the
   transfer table can be gone; negotiate then hands out a new URL for a
   pending asset whose object is already complete, and the file goes again.
   If negotiate could see (a HEAD of the pending key, size match) that the
   bytes are there and answer *confirm it*, nothing is re-sent.

## 6. How to test it

- **Stage 1 on the 18 Pro (iOS 27):** a throwaway 1–2 GB project; Upload;
  lock at ~10 %; leave it 15 minutes; unlock; the log's *uploading N of M*
  lines and the server's list say how far it got while locked. Repeat on
  battery vs charging, and with the phone warm. `devicectl` cannot reach a
  locked phone — pull logs after unlocking.
- **Stage 2:** the same, plus: walk out of Wi-Fi range with the phone locked
  (Steven) — tasks must wait, not move to mobile data; *Use mobile data* on
  one job — only its tasks move; force-quit mid-way → relaunch → the job
  resumes, the table confirms what finished; a URL expiry forced by a short
  TTL on picplace.test (`upload_url_minutes = 2`).
- **Bench plumbing on the Mac** (a background session runs there too) for the
  table, the batches and the re-issue on a rule change; the Simulator is not
  trusted for background transfer timing.
- Throwaway projects only; physical devices use picplace.co only after the
  developer has seen the plan.

## 7. Size

Stage 1: about a day with the device test. Stage 2: two to three days plus
the server asks. Stage 3: half a day after Stage 2. The SVG mirrors for the
job lines (card, drawer) are owed either way (TODO "PicPlace uploads as jobs").
