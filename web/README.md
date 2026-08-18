# LetsLapse web

The WordPress front for letslapse.com, built from the Claude Design source
`LetsLapse Homepage.dc.html` (project `8c667d54-8244-4ac4-a5bb-c91d55f1df4d`).

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

## The hero

The heading, standfirst, canvas and caption row are one self-contained unit:
`inc/blocks/hero-machine/`. Nothing outside that directory renders it, so it can
be reworked without touching the header, the navigation or any template.

It is a dynamic block, **and** the same renderer is exposed as a shortcode:

```
[letslapse_hero blend_ratio="20" output_count="6" play_fps="4"]
```

Every block attribute has a snake_case shortcode equivalent. Both paths call
`render.php`, so they can never diverge.

### What it actually does

Each source frame is composited onto the stack at `1/N` opacity, N being the
frame's position in the stack. That is an exact running mean — every frame ends
up contributing equally — which is the same computation the app performs. The
page's claim that it is "not a mock" stays true: the blends on screen are
averaged in the browser from real footage, not pre-rendered.

The frames come from a sprite atlas (`assets/img/tram-atlas-11x11.webp`, 11×11
grid of 320px cells, 121 cells of which 120 are used). Swap it from the block's
**Footage** panel and set columns / frame count / frame size to match.

### Settings

| Panel | Settings |
| --- | --- |
| Layout & copy | heading level, caption on/off and override, chip on/off, replay label |
| Blend | source frames per blend, blended frames produced, source capture rate |
| Pacing | start rate, acceleration per blend, maximum rate, playback rate |
| Footage | sprite sheet, columns, frames to use, frame size |

Defaults and bounds live in one place — `letslapse_hero_schema()` in
`inc/config.php` — and are handed to the editor at runtime, so nothing has to be
kept in sync by hand. Filters: `letslapse_hero_schema`, `letslapse_hero_config`,
`letslapse_hero_atlas_url`.

### Behaviour

- **Reduced motion** renders the finished stack as a still diagram, no animation.
- **Off-screen or hidden tab**: the loop idles, but one frame is always painted
  so the machine is never a blank rectangle.
- **Colours and the label font** are read from CSS custom properties on
  `.ll-hero__machine` (`--ll-machine-bg`, `--ll-machine-accent`, …), so the
  canvas follows the theme rather than hardcoding hexes.
- **No atlas**: a text description replaces the canvas.

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

- The **For implementation** section on the homepage is the design's own
  developer-facing copy about the animation's internals. It is ordinary blocks
  in the homepage page (and in `patterns/homepage.php` for new installs) —
  delete that group if the public site should not carry it.
- The atlas is 3.4 MB. It is preloaded with `fetchpriority="high"` because it is
  the hero's LCP asset, but it is the page's weight. A shorter loop or a smaller
  cell size is the lever if that matters.
- Numbers quoted in the "How it works" and "For implementation" prose are the
  block's defaults written out. If you change the block's settings, update that
  copy too — it is plain editable text, deliberately not templated.
- The hero prints its atlas `<link rel="preload">` inside `.ll-hero__machine`,
  not beside the section. As a sibling it counted as a layout child, which cost
  the hero its `:first-child` status and earned it a stray block gap.
