# LetsLapse web

The WordPress front for letslapse.com, built from two Claude Design sources:
`LetsLapse Homepage.dc.html` (project `8c667d54-8244-4ac4-a5bb-c91d55f1df4d`)
for the blend machine, and `LetsLapse Loading Animation.dc.html` (project
`7d8fda74-dede-42c1-a8cd-5c73f43e5a64`) for the rig hero.

```
web/
  themes/letslapse/   the installable theme
  tools/              package.sh, deploy.sh
  preview/            a WordPress-free harness for looking at the homepage
  dist/               build output (git-ignored)
```

The iOS design-sync contract in `/CLAUDE.md` covers the app's SVG specs and does
not apply here — the Claude Design project is this theme's spec.

## Where the homepage lives

The homepage is **page-driven**: `templates/front-page.html` is a thin shell
(header part → `post-content` → footer part), and the actual hero and sections
are blocks in whichever page is set under Settings → Reading. Edit the copy in
the normal page editor; the theme stays a deployable package.

`patterns/homepage.php` is the canonical copy of that body. On a fresh install:
create a page, insert the **LetsLapse homepage** pattern, set it as the front
page. Editing the pattern file afterwards does not touch pages already built
from it — by design, so a deploy can never overwrite someone's copy.

Avoid editing the homepage through Appearance → Editor. Saving a template there
writes a database override that permanently shadows the theme file, so later
`deploy.sh` runs stop reaching the front end. (If that happens: Appearance →
Editor → Templates → the template → **Clear customizations**.) Template parts —
header, footer, navigation — are the exception; that is where they are meant to
be edited.

## The machine

The block is the canvas and its controls — nothing else. Headings, standfirsts
and any surrounding prose are ordinary blocks on the page, so copy lives where
an editor expects to find it. Everything lives in `inc/blocks/hero-machine/`;
nothing outside that directory renders it.

It has two **modes**, offered as separate items in the inserter (block
variations) and switchable afterwards under **Presentation**:

| Mode | What it shows |
| --- | --- |
| **Stack & blend** | The machine itself: frames feed in, average, and play back. |
| **Traditional vs LetsLapse** | The same footage with and without blending, with the machine one click away. |

It is a dynamic block, **and** the same renderer is exposed as a shortcode:

```
[letslapse_hero blend_ratio="20" output_count="6" show_timeline="false"]
```

Every block attribute has a snake_case shortcode equivalent. Both paths call
`render.php`, so they can never diverge.

### What it actually does

Each source frame is composited onto the stack at `1/N` opacity, N being the
frame's position in the stack. That is an exact running mean — every frame ends
up contributing equally — which is the same computation the app performs. The
blends on screen are averaged in the browser from real footage, not
pre-rendered.

Desktop lays it out two-up: the source strip and the finished-output row stack
in a left column, and the square stage fills the right one. The stage size and
the column width depend on each other, so `relayout()` settles them in four
passes — the stage ends up exactly as tall as strip + gap + outputs. Below 600px
it becomes a single column: strip, a large stage, the output row, the timeline.

The timeline is not just a progress bar. The segment currently being built fills
in proportion to how many frames have stacked into it, so the bar grows a
fifteenth at a time as the machine runs.

The frames come from a sprite atlas (`assets/img/tram-atlas-11x11.webp`, 11×11
grid of 320px cells, 121 cells of which 120 are used). Swap it from the block's
**Footage** panel and set columns / frame count / frame size to match.

### Traditional vs LetsLapse

The left column becomes three bands — a strip of traditional stills, the
controls, a strip of blends — and the stage on the right plays whichever is in
focus. Both strips are the same eight moments of the same footage at the same
playback rate; the only difference is that traditional keeps one frame in
fifteen and LetsLapse averages all fifteen. Nothing is dimmed or warmed to make
the point.

Two details carry that honesty:

- The traditional still is the **middle** frame of each window, not the first.
  A blend's centroid in time is its middle, so this is the still that sits at
  the same instant as the blur. Take the first frame instead and the subject
  jumps sideways every time the comparison switches.
- The switch only ever lands on **frame 0**, so the two are phase-locked and a
  cut reads as a change of treatment rather than a jump in time.

The comparison drives itself — four loops a side by default — until the reader
clicks either view or drags the divider, which ends the cycle for good. The
`AUTO` marker is there to say so, and disappears when they take over.

**Show LetsLapse workflow** dips the canvas to the page colour, runs the real
stack-and-blend machine, and hands back with LetsLapse in focus and the
auto-cycle intact. It is a sub-view rather than a second block, so both share
one canvas — sized to the taller of the two layouts with each centred inside it,
because otherwise the reveal would reflow the page under the reader.

**Comparison stage** picks how the two are put side by side. Both drive the same
divider position, so they differ only in how it travels:

| Stage | Transition |
| --- | --- |
| **Toggle** | Hard cut on a loop boundary — a blink comparator. |
| **Wipe** | The divider sweeps across, and the reader can drag it, arrow-key it, or grab anywhere on the stage. |

The three controls are real DOM, not canvas: canvas-drawn buttons would lose
focus, keyboard and screen readers. The pair are toggle buttons rather than
radios, because in wipe mode the divider can sit between them. Their height is
whatever the theme's font makes it, so the layout **measures the row and
re-solves** rather than assuming.

### Settings

| Panel | Settings |
| --- | --- |
| Presentation | mode, and in compare mode the comparison stage and loops before switching |
| Comparison copy | the two row labels, the three buttons, the auto marker, the status line |
| Copy / Machine copy | source row, output row, timeline row, replay button, and the status line in each phase (stacking, playing, restarting) plus the reduced-motion note |
| Display | show the timeline row, show the blend counter |
| Blend | source frames per blend, blended frames produced, source capture rate |
| Pacing | start rate, acceleration per blend, maximum rate, playback rate |
| Footage | sprite sheet, columns, frames to use, frame size |

Every label is a block attribute — clear a field to hide that label entirely.
Braced tokens are substituted as the machine runs: `{seconds}`, `{ratio}` and
`{srcFps}` on the timeline row; `{stacked}`, `{ratio}`, `{blend}` and
`{outputs}` while stacking; `{index}` and `{total}` while playing. The playing
label has no tokens by default — the **Show the blend counter** toggle appends
"1 / 8" for you. Put `{index}`/`{total}` in the label yourself and they win.

Numeric defaults and bounds live in one place — `letslapse_hero_schema()` in
`inc/config.php` — and copy defaults in `letslapse_hero_label_defaults()`. Both
are handed to the editor at runtime, so nothing has to be kept in sync by hand.
Filters: `letslapse_hero_schema`, `letslapse_hero_config`,
`letslapse_hero_labels`, `letslapse_hero_atlas_url`.

### Behaviour

- **Reduced motion** renders the finished stack as a still diagram, no
  animation. In compare mode it holds the split down the middle — both
  treatments at once, whichever stage the block uses, on the frame with the most
  movement in it. A toggle that cannot toggle would show one treatment and never
  the other, and the one it happens to hold is the one worth seeing least.
- **Off-screen or hidden tab**: the loop idles, but one frame is always painted
  so the machine is never a blank rectangle.
- **Colours and the label font** are read from CSS custom properties on
  `.ll-machine__stage` (`--ll-machine-bg`, `--ll-machine-accent`, …), so the
  canvas follows the theme rather than hardcoding hexes.
- **No atlas**: a text description replaces the canvas.
- **Single column** below 600px. Compare mode reorders to stage → controls →
  the two strips, so the strips stay adjacent and comparable. The stack layout's
  gate sits 8px in from the column edge there: the brackets overhang their frame
  by 6px and are stroked 3px wide, and on desktop the gutter through to the
  stage is what gives them that room.

## The rig hero

`letslapse/rig-hero`, **Rig hero**. The mark builds itself out of its own parts
on load — legs punch down, the body floods in behind its own outline, the board
draws, the lens opens — and hands over to the copy once it has settled. Roughly
2 s door to door. It is the app's launch animation, ported beat for beat from
`LetsLapse Loading Animation.dc.html`, and the geometry is the app icon's, so
what it lands on *is* the logo (`img/letslapse-icon-dark.svg`, minus the plate).

Copy is **nested blocks**, not attributes: put a heading, a standfirst and a
button row inside the block and they rise in after the build, one line behind
the next. Everything the block needs lives in `inc/blocks/rig-hero/`:

| File | What it is |
| --- | --- |
| `mark.svg` | The rig — one drawing, every moving part classed. `{{uid}}` is swapped per instance so two rigs on a page can't collide over gradient ids. |
| `style.css` | Which parts move, when, in both variants — plus the hero shell. |
| `rig.php` | Bounds, copy defaults, the SVG loader. |
| `render.php` | Server render. |
| `view.js` | The two things CSS can't decide (below). |
| `index.js`, `editor.css` | Editor. |

### Settings

| Panel | Settings |
| --- | --- |
| Animation | what the rig does (build once / keep running), speed, mark size |
| Layout | arrangement (mark above the copy, or beside it), stage panel on/off |
| Photograph | background image, focal point, scrim |
| Copy | wordmark and its text, replay control and its label, mark description |

**Build once** is the launch animation. **Keep running** is the design's loop
state — for work with no known end time: nothing rebuilds, an amber head runs
the body, the board rocks and the legs bob. Speed is the design's own Motion
tweak: 1 is as authored, lower is slower, and the beats keep their proportions
because every duration is `× (1 / speed)`.

Mark size is a cap, not a fixed width — the rig shrinks with the viewport, and
`inline` becomes stacked below 700px. Clear the mark description when the copy
beside it already says the same thing; the mark then goes decorative and screen
readers skip it.

Numbers and copy defaults live in `letslapse_rig_schema()` and
`letslapse_rig_label_defaults()` (`inc/blocks/rig-hero/rig.php`) and are handed
to the editor at runtime, so the preview cannot drift from the front end.
Filters: `letslapse_rig_schema`, `letslapse_rig_config`, `letslapse_rig_labels`.

### The photograph behind it

The hero takes an optional background image — the **Photograph** panel: pick
one, drag its focal point, and set the **scrim**, which is how far the picture
is dimmed under the copy. That number is the whole job: a photograph behind a
headline is only worth having if the headline still reads. It ships at 0.82,
which suits the sunset shots; a darker picture wants less.

The image goes through `wp_get_attachment_image()`, so it arrives with srcset
and sizes, and it loads eagerly at high priority because a hero photograph is
the page's largest paint. It is marked decorative (`alt=""`) — the copy beside
it and the mark's own description already say what is there.

### Motion, JavaScript and reduced motion

The animation is CSS and runs on load, so it is not waiting on a script: with
JavaScript off, a visitor still sees the rig build and the copy arrive.
`view.js` only adds what a stylesheet cannot decide —

- a rig **below the fold** shouldn't have built itself before anyone scrolled to
  it, so it is paused at frame zero and released when it comes into view;
- **replay**, on demand. The control ships hidden and is revealed only where the
  browser can actually drive it (`document.getAnimations`), so it never offers
  something it can't do.

`prefers-reduced-motion: reduce` stops all of it, and hides nothing: the SVG's
resting values are the *settled* ones — rim and board cooled, lens open, glint
on — so the mark reads as the finished logo and the copy is simply there.

## The brand mark

`letslapse/brand-mark` puts the app icon on the page as an `<img>` from
`assets/img/letslapse-icon-dark.svg` (or `-light.svg` for light backgrounds), at
a size you choose, with the corners rounded the way the App Store shows it.
The header and footer template parts use it.

An `<img>` rather than inline SVG on purpose: the artwork needs no theming from
outside, it stays cacheable, and two inline copies on one page would collide
over gradient ids. Alt text is empty by default — beside the site title the mark
says nothing the title hasn't.

If no site icon is set under Settings → General, the theme also points the
browser tab at the same file (`letslapse_favicon_fallback()`); setting a real
site icon always wins.

## Photography

The homepage carries six photographs from the media library — the rig in the
field, shot in 2021 for the original letslapse.com. They arrive as ordinary
core blocks wearing two theme block styles:

| Style | Block | What it is |
| --- | --- | --- |
| **Field shot** (`is-style-ll-shot`) | Image | A framed picture in a column: hairline border, 12px radius, caption underneath. Used three-up in **In the field**. |
| **Band** (`is-style-ll-band`) | Image, Cover | A full-width photograph with no copy on it, capped at `min(46vh, 420px)` and faded top and bottom into the page. |

Two things worth knowing if you move them around:

- **Full-width blocks need the theme's breakout rule.** Core cancels the
  `alignfull` negative margins for a padded container nested inside another one
  — which is exactly our shape, except the inner one adds no padding. `style.css`
  hands the breakout back for `.alignfull` inside the post content. Without it a
  band sits at content width and looks like a mistake.
- **Patterns must resolve image URLs at render time.** Core saves absolute URLs
  into block markup, so a URL typed into a pattern still points at the machine
  it was written on. `patterns/homepage.php` calls
  `letslapse_pattern_image_url( $id, $size )` (`inc/blocks.php`) instead, which
  keeps the pattern right on any install sharing this media library and
  harmlessly empty on one that does not.

The standalone preview has no database, so `preview/index.php` carries a small
table of the attachments the pattern asks for and stubs
`wp_get_attachment_image()` around it. Add to that table if a pattern starts
using another image, or point `LETSLAPSE_UPLOADS_BASE` at another host.

## Copy around the machine

The heading and standfirst that used to be baked into the block are core
Heading and Paragraph blocks now, formatted with block style variations
registered in `inc/blocks.php`:

| Block | Style | Use |
| --- | --- | --- |
| Heading | **Display** | The big hero heading |
| Paragraph | **Standfirst** | The lead paragraph under it |
| Paragraph | **Caption** | Small print, e.g. the frame-count line |
| Paragraph | **Chip** | The dashed pill, e.g. "coming soon" |

They appear in the editor's Styles panel, so the copy stays formattable without
anyone hand-editing class names.

## Theming

`theme.json` owns the palette, type scale, spacing and layout width. `style.css`
mirrors the palette into `--ll-*` custom properties for the hand-written section
styles. Change a colour in `theme.json` and both the page and the canvas follow.

## Preview without WordPress

```bash
php -S 127.0.0.1:8787 -t web
```

Then open <http://127.0.0.1:8787/preview/>. The harness stubs the handful of WP
functions the theme calls and approximates the markup core would emit — good
enough to check the hero and the page rhythm, **not** proof of WordPress output.

## Package and deploy

```bash
./web/tools/package.sh
```

…builds `web/dist/letslapse-<version>.zip` with a single top-level `letslapse/`
directory, ready for Appearance → Themes → Add New → Upload Theme.

```bash
./web/tools/deploy.sh --dry-run
./web/tools/deploy.sh
```

…rsyncs into `~/Sites/letslapse/public_html/wp-content/themes/letslapse` (override
with `--dest` or `LETSLAPSE_THEME_DEST`). It refuses to overwrite a directory
that is not this theme, and never activates anything — switch themes yourself in
Appearance → Themes.

For letslapse.com, use the zip or point `--dest` at that server's themes
directory.

## Requirements

WordPress 6.5+, PHP 7.4+. No build step and no npm: the editor script is plain
ES5 against the `wp.*` globals, so the checked-in files are the shipped files.

## Notes

- **"Tricky stuff made simple"** on the homepage is the old letslapse.com's
  copy, carried over word for word — the multi-day shooting problem the system
  was built for. It is ordinary blocks in the page, next to the lens close-up.
- The **For implementation** section on the homepage is the design's own
  developer-facing copy about the animation's internals. It is ordinary blocks
  in the homepage page (and in `patterns/homepage.php` for new installs) —
  delete that group if the public site should not carry it.
- The header and footer marks were placeholder line art until 0.3.0. They are
  the real icon now, through the brand mark block. If you have already edited
  those template parts in Appearance → Editor, your database copy wins — reset
  them there to pick the change up.
- The caption line and the "coming soon" chip under the machine were drawn by
  the block before 0.2.0. The design dropped them, so they are page blocks now —
  the words survive, but the caption's numbers no longer follow the block's
  settings. Delete both if the cleaner presentation is what you want.
- The atlas is 3.4 MB. It is preloaded with `fetchpriority="high"` because it is
  the hero's LCP asset, but it is the page's weight. A shorter loop or a smaller
  cell size is the lever if that matters.
- Numbers quoted in the "How it works" and "For implementation" prose, and in
  the caption under the machine, are the block's defaults written out. If you change the block's settings, update that
  copy too — it is plain editable text, deliberately not templated.
- The machine prints its atlas `<link rel="preload">` inside `.ll-machine__stage`,
  not beside the section. As a sibling it counted as a layout child, which cost
  the block its `:first-child` status and earned it a stray block gap.
- Core's constrained layout centres anything narrower than the content width
  using `margin-inline: auto !important`. Any measure-limited copy (the
  standfirst) or flex container whose children should stay put (the cards) has
  to say so explicitly — see `.is-style-ll-standfirst` and `.ll-card > *`.
