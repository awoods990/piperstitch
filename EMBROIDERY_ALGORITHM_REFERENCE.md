# Embroidery Algorithm Reference

This document records what was actually studied in public embroidery
codebases, what was learned, and how that knowledge was used (or
deliberately not used) in StitchPilot's digitizing engine. It exists so
that future work has a written record of *why* an algorithm looks the way
it does, rather than needing to re-derive it or re-read the reference
projects from scratch.

**Ground rule followed throughout:** source code from GPL-licensed projects
(Ink/Stitch) was read for algorithmic understanding only. No Ink/Stitch code
is copied, transliterated, or vendored anywhere in this repository — every
technique described below was reimplemented independently in Swift, in
StitchPilot's own architecture, informed by understanding *what* the
reference project does and *why*, not by translating *how* its code is
written. MIT-licensed code (pyembroidery) is held to the same
no-code-copying standard for the digitizing engine specifically — see
`FORMATS.md` for the one place this project does port pyembroidery's exact
byte-level logic (file format binary layouts, which are factual
interoperability data, not creative digitizing decisions).

## Repositories studied

| Repository | License | What was examined |
|---|---|---|
| [inkstitch/inkstitch](https://github.com/inkstitch/inkstitch) | GPL-3.0 | `lib/elements/satin_column.py`, `lib/stitches/fill.py`, `lib/stitches/auto_satin.py`, `lib/stitches/contour_fill.py`, `lib/stitches/running_stitch.py` — read via GitHub's raw source, not cloned or vendored |
| [EmbroidePy/pyembroidery](https://github.com/EmbroidePy/pyembroidery) | MIT | Already the reference for `DSTFormat.swift`/`PESFormat.swift`'s byte layouts (see `FORMATS.md`); revisited here for its `EmbPattern` object model as a second "neutral representation" data point |
| [EmbroidePy/samples](https://github.com/EmbroidePy/samples) | MIT | Two files (`random1-ew.dst`, `random1-ew.pes`) vendored into `Tests/StitchPilotCoreTests/Fixtures/ThirdPartySamples/` under that MIT license, used as independently-authored real-world files to validate StitchPilot's readers (see `ThirdPartySampleTests.swift`) |

No Ink/Stitch sample files were vendored — they ship under the same GPL-3.0
terms as the codebase, and StitchPilot's own synthetic `TestArtwork/` (built
specifically to avoid third-party licensing questions, per `TESTING.md`)
already serves the same "known test input" role for source artwork. The
EmbroidePy samples were used instead for the one thing they're uniquely
useful for and clearly licensed to permit: validating format *reading*
against files this project didn't write.

## What Ink/Stitch actually does, and what StitchPilot took from it

### Satin columns: a fundamentally different input model

Ink/Stitch's `SatinColumn` assumes the *human digitizer* has already drawn
two explicit parallel rail paths plus perpendicular "rung" lines marking
where the rails divide into corresponding sections
(`satin_column.py`'s `rails`/`rungs`/`_synthesize_rungs` machinery). That's
the right model for a tool built around a human doing the digitizing inside
a vector editor — but it's the opposite of StitchPilot's problem, which is
deriving a column automatically from a single closed boundary with no
human-drawn rails at all. `SatinColumnGenerator`'s PCA + edge-based
end-cap-splitting approach (documented in `DIGITIZING_ENGINE.md`) has no
direct analog in Ink/Stitch for this reason — it was developed
independently to solve the auto-derivation problem Ink/Stitch's design
doesn't need to.

**What transferred directly:**

- **Three distinct underlay types, not one.** Ink/Stitch's satin underlay
  is `center_walk_underlay` (a running stitch down the centerline),
  `contour_underlay` (walks each rail, inset), and `zigzag_underlay` (a
  wider-spaced, inset zigzag) — used in combination (their code comments
  cite the "German underlay" technique: contour-walk + zigzag together) for
  wider columns that need more than a single center line to stay stable.
  StitchPilot had only the center-walk equivalent for satin. **Added:**
  `UnderlayType.zigzag` (see Phase 3 section below) for wider columns,
  chosen automatically by width — this is a direct, real improvement
  sourced from this study.
- **Explicit width-based splitting.** `SatinColumn.split()` exists
  specifically to break an overly wide or oddly-shaped column into
  sections rather than forcing one continuous (and potentially unstable)
  zigzag across the whole thing. StitchPilot doesn't implement general
  splitting (the PCA-derived single-column model doesn't have an
  equivalent "cut point" concept yet), but the *principle* — an overly wide
  column is a solvable problem, not just a rejection — motivated changing
  `SatinColumnGenerator`'s behavior from *always throwing* on
  `columnTooWide` to *falling back to tatami fill automatically* in
  `DigitizePipeline` (see below), which is the simplest form of "don't just
  fail, produce something sewable."
- **Push compensation as a distinct concept from pull compensation.**
  Ink/Stitch tracks `pull_compensation_px` and `push_compensation_px`
  separately (pull narrows a column from the sides; push affects it along
  the stitch direction as stitches physically displace fabric forward).
  StitchPilot currently only models pull compensation
  (`PullCompensationCalculator`) — push compensation is recorded here as a
  known gap, not implemented this round (see "Known remaining
  weaknesses").
- **Randomized width/spacing jitter** (`random_width_decrease`,
  `random_zigzag_spacing`, etc.) to avoid a mechanically perfect look.
  Deliberately not adopted: it's a real technique but orthogonal to the
  correctness/decision-quality work this round focused on, and StitchPilot
  has no calibration data yet to know what jitter amount would actually
  look better versus just noisier — a candidate for a future, carefully
  benchmarked addition rather than a blind port.

### Fill: validated the core algorithm, found no "auto angle" to borrow

`fill.py`'s `intersect_region_with_grating` does exactly what
`TatamiFillGenerator` already does: rotate the shape so the fill angle
becomes axis-aligned, compute scanline intersections, rotate back. Finding
that a completely independently-developed implementation converged on the
same core technique is a good sign the approach is sound, not a case of
one project copying the other.

**What did *not* transfer, and why that matters:** Ink/Stitch's fill angle
is a user-set parameter with no automatic selection logic anywhere in
`fill.py` — professional digitizing software generally leaves this
decision to the human. StitchPilot's automatic fill-angle selection
(Phase 6 work, below) is therefore **not** "borrowed from Ink/Stitch" — it
is new work motivated by general digitizing knowledge (rows running
perpendicular to a region's elongation resist pull along the direction
that matters most) that goes beyond what even a mature, human-oriented
tool automates. This is called out explicitly so it isn't misread as
attributed-but-uncredited technique transfer.

### `contour_fill.py`: a real technique, deliberately not implemented yet

Ink/Stitch's contour fill builds a tree of nested inward offsets of a
shape's boundary (via `shapely.offset_curve` + `networkx`) and stitches
them as connected concentric rings — visually distinct from tatami's
parallel rows, and often preferred for shapes with a lot of local width
variation. This is a non-trivial graph-based algorithm; StitchPilot doesn't
have a general polygon-offset library (`PolygonGeometry.offsetPolygon` is a
naive single-pass per-vertex offset, not a robust repeated-offset primitive
that handles self-intersection at repeated inward steps) or a graph
traversal layer for turning nested rings into one continuous path. Recorded
here as the reference technique to implement against when `ContourFill`
becomes a priority, rather than attempted this round with an inadequate
offset primitive.

### `auto_satin.py`: graph-based sequencing, the clearest lead for Phase 11/12

The most directly relevant discovery for object sequencing: `auto_satin`
builds a graph where satin/stroke segments are nodes and possible jump
connections between their endpoints are edges (`build_graph`,
`_route_single_satin`), then finds a path through that graph that visits
every segment while minimizing jumps — a real (if scoped-down) instance of
path optimization applied to embroidery sequencing, not just "sort by
position." StitchPilot's current sequencing is still document-order plus
same-color-run consolidation (`DigitizePipeline.flatten`) — a graph-based
reordering pass informed by this technique is recorded as the highest-value
remaining sequencing improvement (see "Recommended next improvements"),
scoped down from Ink/Stitch's version (which also handles satin-segment
splitting/merging that doesn't apply to StitchPilot's object model).

### `running_stitch.py`: confirmed existing techniques, one naming clarification

`bean_stitch()` (repeat each segment N times) confirms `DigitizePipeline`'s
triple-run implementation (forward/backward/forward, a fixed 3-repeat bean
stitch) is a real, named technique, not an ad hoc invention — worth stating
plainly since `DIGITIZING_ENGINE.md` described it functionally without the
name. `zigzag_stitch()` (turning a plain stroke into a fixed-width zigzag)
is the "satin from a thin stroke via a configured width" technique
mentioned for completeness; StitchPilot's `StitchTypeClassifier` decides
stitch type from an already-2D shape's estimated width rather than a
1D-stroke-plus-width parameter, so this doesn't transfer directly, but it's
a reasonable model for a future explicit "stroke width" input path (e.g.
SVG strokes with a `stroke-width`, as opposed to filled shapes).

## Architecture comparison: does StitchPilot avoid "IMAGE → DST"?

The spec for this work is explicit that the architecture must not collapse
to `image -> machine format` directly. Checking StitchPilot's actual
pipeline against the required stage separation:

```
SOURCE ARTWORK        -> SVGImporter / ImageImporter (raw PNG/JPG/SVG in)
ARTWORK ANALYSIS      -> ColorQuantizer, connected-component labeling,
                          background detection (ImageImporter)
SEMANTIC OBJECTS      -> VectorShape + detected/matched color, per region
DIGITIZATION DECISIONS -> StitchTypeClassifier (running/satin/fill),
                          UnderlayGenerator, PullCompensationCalculator
STITCH GENERATION     -> RunningStitchGenerator / SatinColumnGenerator /
                          TatamiFillGenerator, then StitchFilter
ROUTING & SEQUENCING  -> DigitizePipeline.flatten (tie-in/out, trims,
                          jumps, color-run consolidation)
NORMALIZED DESIGN     -> StitchPlan (format-independent)
MACHINE EXPORT        -> DSTFormat / PESFormat (adapters only)
```

This was already true before this round of work — `ARCHITECTURE.md`
documents the `StitchDocument`/`StitchPlan` split as a Phase 1 decision —
but it's worth stating explicitly here, cross-checked against this spec's
required pipeline, as confirmation the existing architecture doesn't need
restructuring to support the improvements below. The internal model is
already format-independent (`StitchPlan` has no notion of DST/PES); the
work in this round is entirely about making the *digitization decisions*
stage smarter, which is exactly where the spec says the real value has to
come from.

## Licensing summary (see also `ARCHITECTURE.md`'s dependency table)

| Asset | License | Where it lives | How it's used |
|---|---|---|---|
| Ink/Stitch source | GPL-3.0 | Not vendored — read via GitHub only | Algorithm study only; zero code copied |
| pyembroidery source | MIT | Not vendored — read via GitHub/local pip install only | Reference for DST/PES *byte layout* (see `FORMATS.md`); zero digitizing-decision code copied |
| `random1-ew.dst`, `random1-ew.pes` | MIT (EmbroidePy/samples) | `Tests/StitchPilotCoreTests/Fixtures/ThirdPartySamples/` | Read-only test fixtures validating StitchPilot's format readers against real third-party files |

## Algorithms improved this round (see `CHANGELOG.md` for full detail)

1. **PES reader/writer offset handling** — not something this study set out
   to find, but the first thing `ThirdPartySampleTests` caught: the reader
   assumed a fixed byte offset for the embedded PEC block instead of
   reading PES's actual offset-pointer mechanism, silently mis-parsing any
   real-world PES file with different leading metadata. Fixed in both
   directions (writer now emits a real offset field; reader follows it).
2. **Satin auto-fallback to fill** when a column would exceed the
   practical satin width, instead of throwing and abandoning the object.
3. **Zigzag underlay for satin** on wider columns (the "German underlay"
   technique), alongside the existing center-run underlay for narrow ones.
4. **Automatic fill-angle selection** via principal-axis analysis, replacing
   a fixed default angle — original work, not an Ink/Stitch technique (see
   above).
5. *(See `CHANGELOG.md` for the complete, final list — this document is
   written before the full implementation pass to satisfy the "study
   before modification" ordering the spec requires; later entries are
   appended to `CHANGELOG.md` and `DIGITIZING_ENGINE.md` as they land.)*

## Known remaining weaknesses

- No push compensation (pull compensation only).
- No graph-based object sequencing (Ink/Stitch's `auto_satin` routing is
  the clear reference for this; not yet implemented).
- No contour fill (needs a robust repeated polygon-offset primitive this
  project doesn't have yet).
- Satin "too wide" handling falls back to *whole-object* fill rather than
  splitting into sections that could stay satin where the width allows it —
  a coarser response than Ink/Stitch's `split()`.
- Fill angle candidates are evaluated by a geometric heuristic (principal
  axis), not by the fuller scoring spec §6 describes (visual appearance,
  travel efficiency, neighboring-object direction) — those additional
  signals aren't wired in yet.
- No physical stitch-out calibration exists for any of this — all
  compensation/density values remain rule-based estimates pending real
  sew-out data, consistent with `PullCompensationCalculator`'s existing
  documented caveat.

## Recommended next improvements, in priority order

1. Graph-based object sequencing informed by `auto_satin.py`'s approach
   (highest expected impact on perceived "professional" output quality
   per unit effort, since it's the area with the clearest reference
   technique and the current implementation is the most naive).
2. Width-aware satin splitting (partial fallback instead of whole-object).
3. Push compensation.
4. Contour fill, once a real polygon-offset primitive exists.
