# PicPlace two-device bench

The scratch rig the sync v2 stages were verified with (see
`docs/picplace-sync-v2-handover.md` § "How it was tested"). Two scratch
library roots on this Mac act as two devices against `picplace.test`:

- a root bound to the account (copy the play-pen's `PicPlace/account.json`
  into `<root>/PicPlace/`) signs in silently from the login keychain;
- the second "device" is the same build launched with
  `-letslapse.deviceID <any uuid>` — the argument domain gives it its own
  device id without touching the install's defaults;
- an UNBOUND scratch root never borrows the install's session (Debug guard),
  so a wrong root cannot rotate the person's tokens.

Scripts:

- `launch_wait.sh <root> <log-pattern> [LL_*=… ] [-- <args>]` — launch on a
  root, wait for a new log containing the pattern, print its picplace lines.
- `clone_project.py <project-folder> <Projects-dir> <name>` — copy a project
  under a fresh id (capture id + origin id re-minted, blends re-keyed): a
  throwaway to push, edit, conflict and delete. **Only ever test on
  throwaways** — a rename made on a real project reaches every device.
- `edit_project.py <project.json> <name>` — an on-disk edit (name +
  `modifiedAt`) the next launch's walk picks up: "this device moved".

Typical run (A pushes, B pulls, both edit, B keeps both):

    A=…/roots/a/picplace.test/regularsteven; B=…/roots/b/picplace.test/regularsteven
    T=$(python3 clone_project.py "$SRC" "$A/Projects" "throwaway")
    ./launch_wait.sh "$A" "check (launch)" LL_TAB=projects
    ./launch_wait.sh "$B" "check (launch)" LL_TAB=projects -- -letslapse.deviceID 7B7B7B7B-0000-4000-8000-00000000000B
    python3 edit_project.py "$A/Projects/$T/project.json" "edited on A"; python3 edit_project.py "$B/Projects/$T/project.json" "edited on B"
    ./launch_wait.sh "$A" "check (launch)" LL_TAB=projects
    ./launch_wait.sh "$B" "resolved by" LL_TAB=projects LL_PICPLACE_RESOLVE=both -- -letslapse.deviceID 7B7B7B7B-0000-4000-8000-00000000000B
    ./launch_wait.sh "$A" "check (launch)" LL_TAB=projects LL_PICPLACE_DELETE=$T     # tombstone it when done

The hooks (`LL_PICPLACE_*`) are listed in `CLAUDE.md`. Server-side checks:
`php artisan tinker` in the picplace repo — e.g.
`\App\Models\LetsLapseProject::withTrashed()->get()` and
`\App\Models\LetsLapseAsset::where("project_id", $uuid)->get()`.
