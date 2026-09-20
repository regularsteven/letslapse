# Shape-mation — the interaction prototype (Claude Design hand-off, 2026-09-20)

The disposable HTML/JS prototype the brief (`../prototype-brief.md`) asked for,
as exported from Claude Design: `Shape-mation Prototype.dc.html` (the shell and
the Notes pages — Hand-off, Assumptions, States, Decisions, Departures),
`ShapemationSteps.dc.html` (every step, including the Sequence board),
`model.js` (brief §4 as one computation) and `support.js` (the dc-runtime;
it loads React and Babel from unpkg, so it needs a network). `kit` is a
symlink to `../../design/kit` — the prototype reads
`kit/compositions/manifest.json` and the SVGs by that path. `github.md` and
`HANDOFF-README.md` are the export's own notes (its `branch: main` is Claude
Design's sync target, not this repo's — the design docs live on `ios-app`).

Open `Shape-mation Prototype.dc.html` in a browser to use it. The review that
tested its model on the real tram library is `../prototype-review.md`; the
code is not carried over — the Swift implementation works from the review, the
States and Decisions tabs and this prototype as the design reference until the
SVG mirrors are redrawn.
