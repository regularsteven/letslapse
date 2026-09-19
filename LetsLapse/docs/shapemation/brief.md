# Shape-mation — Developer Brief

Shape inventory, photo collections, tween-framed output, and a synthetic-data prototype.

*Filed verbatim 2026-09-19. The map of this brief against the code is
[`gap-map.md`](gap-map.md).*

---

## 1. Summary

Shape-mation builds a motion sequence from many individual stills rather than from video.

The user marks the subject in each photo with a shape. The app uses that shape as a **registration anchor** to align, sort, and scale the images so that playback reads as continuous movement. Example: one hundred photos of trams shot from the front, sorted smallest to largest and played back with accelerating frame timing, so the tram appears to approach the viewer — assembled entirely from separate photographs.

The concept is already working as a spike. This brief covers the work required to turn it into a durable, re-renderable feature, plus the prototype needed to prove the underlying logic.

The feature has two halves that should be understood separately:

- **Annotation** — placing and posing a shape on each image.
- **Sequencing** — aligning, ordering, framing, and rendering based on those shapes.

This feature inherently requires many photos to be worthwhile.

---

## 2. Shape inventory

Shapes become an **app-wide resource**, not a per-project one.

Today a project can carry a custom shape as a black-and-white alpha channel. This is different. The user maintains a personal **shape inventory** of vector outlines they care about — a tram face, a window frame, an arch, a cog, a triangle, whatever is relevant to their subject matter. The inventory belongs to the user's library and persists across all projects.

### Behaviour

- Inventory shapes appear alongside existing primitives (rectangle, circle) wherever a shape is added in the **Masks tab**.
- Adding is a single action: *add shape "tram" to image*. The shape is positioned, then adjusted.
- Once placed, a shape supports:
  - **Scale**
  - **Tilt** (rocker: leaning forward / back)
  - **Rotation on the horizontal axis** (viewed from the left / from the right)

This records the subject's approximate **pose**, not merely its bounds, which builds a richer profile of the subject than a plain bounding rectangle can.

### Perspective

Foreshortening should fall out of the transform itself — rotating a square outline naturally shortens the receding edge. Correcting barrel distortion or implementing true perspective projection is **explicitly out of scope**.

### Note

Shapes may also be used as masks. That is not the purpose of this feature and is not covered here.

---

## 3. Photo collections

Collections currently hold **blended clips only**. They must also support **stills**.

A photo Collection is the durable asset type that shape-mation produces. It carries:

- its member images
- each image's shape (geometry, scale, tilt, rotation)
- the sort order
- the output framing keyframes

Without this, there is no true asset behind the feature. The current spike simply pushes a finished video into the system, which means the sequence cannot be re-rendered at a different frame rate, with different speed ramping, or with alternative framing. Creating the Collection asset is the dependency that unlocks alternative versions.

---

## 4. Output framing and tweening

The user defines an **output rectangle** — for instance a square for an Instagram post — by setting it as a keyframe on the **first and last frames**. Additional keyframes may be supported, but first and last are the minimum.

Intermediate frames are **tweened** (perceptually, where that improves the result), so every frame receives its own position, scale, and crop adjustment. The framing drifts smoothly across the sequence rather than being derived independently per frame.

This is deliberate: it allows the subject to **travel within the output frame** — drifting from left, to centre, to right across the sequence — which is currently impossible. The end output is therefore a known, fixed shape with intentional motion inside it.

### Scrubbing

The sequence must be **scrubbable**, showing the exact output framing at any point. Scrubbing is not just a preview convenience: it is how the creator identifies shots that will land badly — poorly framed or poorly aligned — before committing to a render.

---

## 5. Crop feasibility and negative space

Punching in on the shape alone destroys composition, which is the part the photographer actually crafted. This is the core problem to solve.

### The problem

Across a set of photos there are two independent variables:

1. **Subject scale** — some trams large, some small, some medium.
2. **Subject position** — some dead centre, some drifted to any corner.

Cropping to the shape at a fixed aspect ratio can force the crop hard against an edge. Where there is room around the subject that may be acceptable; where there is not, it is not.

### The approach

The user should **never have to describe negative space**. They think about the object they care about; negative space is simply its inverse.

Derive it:

- Negative space is the complement of the shape within the image bounds.
- The **available margin on each side** is therefore computable from the shape bounds and the image bounds, with no additional drawing.
- For each photo, report that per-side margin.
- Where a photo cannot satisfy the requested framing **at its point in the tween**, exclude or flag it.

This means one shape per photo — which the user is drawing anyway for grouping — serves double duty: alignment anchor *and* crop-feasibility source. That matters, because tracing rectangles around hundreds of objects is monotonous, and anything that can be inferred should be inferred.

---

## 6. Compositional filtering

Add a coarse position classification using a **3×3 grid** (naming open: quadrant, sector, cell).

- A shape falling **entirely within one cell** earns a high-confidence classification for that cell.
- Otherwise, record the **percentage overlap** across the cells it touches.

This enables **filtering by composition** — assembling a sequence from photos that already share a compositional family — rather than relying on the crop to repair mismatches after the fact. For example, selecting only subjects sitting in the left column to produce a consistent animation with negative space on the right.

Anchoring may be to the grid cell or to the shape itself; this is still open.

---

## 7. Sequencing controls

- **Per-image frame duration** — increase or decrease the number of frames each image is held for, enabling acceleration and speed ramping.
- **Sort by shape size** — smallest to largest, or the reverse.
- **Sort by alignment** — each successive image chosen for closeness of shape to the previous one.

---

## 8. Prototype and synthetic data

The prototype is built against a **synthetic scene generator**, not real photographs.

### The generator

An SVG-based arrangement engine composes scenes from a library of parts:

- skies across times of day and light levels (daylight, night, light, dark)
- hills and city skylines
- fields and roads
- trams from multiple viewpoints: left angle, right angle, front, slightly above, slightly below

Because every element is positioned programmatically, the **true scale, centre, and pose** of the tram in each scene is known exactly. Registration accuracy can therefore be scored numerically rather than judged by eye.

### The generator must emit the shape

The bounding shape must be generated **inside the engine**. The engine is the only component that knows where the subject truly is; generating a shape afterwards would require re-detecting the subject, which is a different problem and out of scope.

Each generated scene emits **two** shapes:

1. **Ground truth** — exact, used only for scoring.
2. **Perturbed** — used as the actual pipeline input.

### Perturbation must be parameterised

The perturbation is deliberate, not incidental. It applies random variance to:

- scale
- centre offset
- rotation

The **magnitude must be dialable**, so the prototype can be swept from clean shapes, through mild sloppiness, to genuinely bad ones. The point at which alignment visibly breaks is a **deliverable in its own right**: it defines how accurately real users need to draw their shapes, which is otherwise a guess.

Without this, the pipeline would be tested against input it will never actually receive.

### One code path, two sources

Real-world input consists of hand-drawn shapes — largely rectangles and four-point polygons — already created at varying quality. The logic proven on synthetic data must apply to them **unchanged**. Approximate shapes are expected and acceptable; at fast playback, approximate registration should be good enough.

### Phase 0 — SVG output (current)

The generator currently outputs SVG scenes. This is acceptable for initial development.

### Phase 1 — Rasterised `.lapse` packages (real deliverable)

SVG output is not representative: it carries clean vector geometry the app would never see. The real deliverable is a generator that produces:

- **JPEGs**, as a real capture would
- a **shape** written into the mask structure of a project
- packaged in the **self-contained `.lapse` project format**, structured exactly as a regular LetsLapse photo project

Each generated scene set then becomes an importable project. This removes any separate ingest path for test data — synthetic projects come through the same door as real ones — and forces an honest test of the raster case rather than the vector one.

---

## 9. Build order

1. **Shape-based alignment and sorting.**
2. **Tween-framed output and crop feasibility.**

Alignment first, for three reasons:

- **Dependency.** The framing stage consumes whatever alignment produces. If registration is off by a few pixels or the sort order jitters, every downstream framing problem is ambiguous — it cannot be determined whether the crop logic is wrong or merely inheriting bad input.
- **Scoreability.** Alignment is where ground truth is cleanest and can be scored numerically. Crop feasibility is partly a matter of taste, which is a poor thing to debug against while the foundation is unproven.
- **Cost of failure.** If shape-based alignment does not hold up across a hundred varied scenes, the feature needs rethinking — better to learn that before building the keyframe and tween machinery on top of it.

---

## 10. Deferred / out of scope

- **Subject-angle matching** — distinguishing a three-quarter view from a dead-on view to avoid jump cuts between frames. On the radar, but a later feature. The pose data captured in §2 lays the groundwork.
- **Camera-mode shape overlay** — superimposing an inventory shape in the viewfinder as a capture guide, so the photographer knows where to shoot from. Noted for later; not in this scope.
- **Barrel distortion and true perspective correction** — not attempted.

---

## 11. Open questions

- Naming for the 3×3 grid cells: quadrant, sector, or cell.
- Whether anchoring is to the grid cell or to the shape.
- Whether output framing supports keyframes beyond first and last.
