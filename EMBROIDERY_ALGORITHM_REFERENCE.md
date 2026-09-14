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
| [EmbroidePy/samples](https://github.com/EmbroidePy/samples) | MIT | Six files (`random1-ew.{dst,pes}`, `random1-wilcom.dst`, `random1-brother-v6.pes`, `scene.{dst,pes}`) vendored into `Tests/StitchPilotCoreTests/Fixtures/ThirdPartySamples/` under that MIT license, spanning multiple exporters and designs, used as independently-authored real-world files to validate StitchPilot's readers (see `ThirdPartySampleTests.swift`). The full upstream repository (654 files, every design × every supported machine format) was cloned separately and run once through both readers as a broader one-off pass — all parsed successfully; see `CHANGELOG.md` |
| [CreativeInquiry/PEmbroider](https://github.com/CreativeInquiry/PEmbroider) | GPLv3 / Anti-Capitalist License | `src/processing/embroider/PEmbroiderHatchSpine.java`, `PEmbroiderTSP.java`, `PEmbroiderHatchSatin.java` — read via a shallow local clone for algorithmic understanding only, same ground rule as Ink/Stitch below; nothing copied or vendored |

No Ink/Stitch or PEmbroider source or sample files were vendored — they ship
under GPL-3.0-family terms, and StitchPilot's own synthetic `TestArtwork/`
(built specifically to avoid third-party licensing questions, per
`TESTING.md`) already serves the same "known test input" role for source
artwork. The EmbroidePy samples were used instead for the one thing they're
uniquely useful for and clearly licensed to permit: validating format
*reading* against files this project didn't write.

### PEmbroider: confirms the sequencing approach, flags a real fill-direction gap

- **`PEmbroiderTSP.java`** — a "Basic TSP implementation: Greedy + 2-Opt,"
  by its own header comment, sequencing stitch groups to minimize travel.
  This is exactly `ObjectSequencer.swift`'s own approach (greedy nearest-
  neighbor construction, then 2-opt refinement — see `CHANGELOG.md`'s
  Phase 4 entry), arrived at independently. Useful confirmation that this
  isn't an idiosyncratic choice; no change made.
- **`PEmbroiderHatchSpine.java`** — a materially different fill technique
  from `TatamiFillGenerator`'s: rather than scanning at one fixed angle
  across the whole shape (`FillAngleSelector`'s job here), it computes the
  shape's medial axis/skeleton (via raster morphological thinning) and
  generates hatch lines that follow *that*, so fill direction bends with a
  curved or tapered shape instead of staying constant across it — the
  standard professional technique for organic shapes (a curved letter, a
  leaf, a tapered limb) where one fixed angle looks visibly wrong on part
  of the shape. **Not implemented here**: it requires a raster-based
  skeletonization pass this codebase doesn't have (StitchPilot's fill
  pipeline is polygon-based, not raster-based, once past `ImageImporter`'s
  initial vectorization), a genuinely different feature rather than a
  tweak to the existing angle-selection logic. Recorded here as the
  clearest concrete lead for whenever curved/organic fill shapes become a
  priority — see "Recommended next improvements" below.

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
  This round adds push compensation to `PullCompensationCalculator`
  (`estimatePush`, reusing the same formula as pull rather than inventing
  a differently-shaped one with no calibration data to justify it) — see
  "Algorithms improved this round" below.
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
2. **Satin auto-fallback to fill** (`DigitizePipeline`) when a column would
   exceed the practical satin width, instead of throwing and abandoning the
   object — the whole-object version of Ink/Stitch's `split()` idea (see
   above); a per-section fallback remains future work.
3. **Zigzag underlay for satin** (`UnderlayGenerator`) on columns averaging
   wider than a configurable threshold (default 4mm) — the "German
   underlay" technique (contour-walk + zigzag together) sourced from
   studying Ink/Stitch's three-underlay-type satin model; narrower columns
   keep the existing center-run underlay, since a single centerline is
   adequate for those.
4. **Automatic fill-angle selection** (`FillAngleSelector`) via
   principal-axis analysis (rows run perpendicular to a shape's elongation
   by default), replacing an always-fixed angle — original work, not an
   Ink/Stitch technique (see above); still overridable per object.
5. **Containment-based object sequencing** (`ObjectSequencer`): when one
   object's bounding box fully contains another's but the smaller one is
   currently scheduled to sew first, they're swapped so the larger
   (background) object sews first — a conservative first step toward the
   graph-based sequencing `auto_satin.py`'s routing approach points toward
   (see "Recommended next improvements").
6. **Generalized `ObjectSequencer` scheduler** (this round): replaced the
   pairwise containment-swap loop with a proper topological scheduler —
   containment still defines a strict "must sew before" partial order (it
   can't cycle, since the containment test requires a >5% area margin),
   but objects with no containment relationship to each other are now free
   to be reordered, and the scheduler greedily picks, from whatever's
   currently sewable, (a) the same thread color as whatever was just
   placed — every color switch costs a trim and a manual machine stop for
   a thread change, the single most expensive thing in the sequencing
   budget — then (b) whichever candidate is nearest (bounding-box center
   distance) to what was just placed, to shorten the same-color jumps a
   machine executes without operator intervention. This is a genuine
   step toward the jump/color-minimizing goal `auto_satin.py`'s routing
   points at, though it's still a greedy heuristic over a cheap geometric
   proxy (bounding-box centers), not the real graph-based routing over
   actual stitch-path endpoints that a fuller version would need.
7. **Width-aware satin splitting** (`SatinColumnGenerator.generatePartial`,
   this round): replaces the whole-object satin-to-fill fallback from item
   #2 above with a genuine partial one, closer to what item #2's own note
   said was still missing. Crossings are classified narrow/wide against
   `maxSatinWidthMM` per-crossing (not by one average for the whole
   column); contiguous wide runs of two or more crossings become a tatami
   fill sub-region built from that run's own rail points, while narrow
   runs stay real satin — closer to Ink/Stitch's `SatinColumn.split()`
   idea than converting the entire object. `DigitizePipeline` now calls
   `generatePartial` for every `.satin` object; the original `generate`
   (which still throws `columnTooWide` for any violation, whole-object) is
   kept as the strict variant for direct/test use and any future
   validation check that wants a hard yes/no answer.
8. **Push compensation** (`PullCompensationCalculator.estimatePush`, this
   round): fabric pushes apart *along* the stitching direction (as opposed
   to pull, which narrows a design perpendicular to it), so satin/fill
   objects now shorten slightly along their length before sewing, the
   same way they already widen slightly across their width for pull. For
   satin, this can't be done by trimming the rail *polylines* by arc
   length — each rail's first/last few millimeters are a perpendicular
   "jog" from the shared end-cap midpoint out to the boundary corner (see
   `SatinColumnGenerator`'s own doc comment on tapered end caps), not
   travel along the column's real length, so arc-length trimming would eat
   into that sideways jog almost without shortening the column at all.
   Instead, crossings are dropped based on their midpoint's projection
   onto the column's principal axis — the real length axis, immune to the
   end-cap jog. For fill, each scanline row's overall span (not each
   individual enter/exit pair, which would incorrectly nibble at a hole's
   boundary) is inset at its two outermost ends before resampling.
9. **Endpoint-based object sequencing** (`ObjectSequencer.sequenceGenerated`,
   this round): item #6's bounding-box-center proxy is exactly the
   limitation item #6 itself named. `DigitizePipeline` now generates every
   object's stitch points *first* (generation never depends on sew order),
   then sequences the *results* using each path's real first/last points
   for the proximity heuristic instead of a geometric proxy, and can
   *reverse* a path (sewing it end-first) when that's the closer approach
   from wherever the previous object left off — the machine sews the same
   shape either way, so there's no reason not to pick whichever direction
   shortens the jump into it. `sequence` (the bounding-box-center version)
   is kept for callers that don't have generated points yet.
10. **True polygon containment for `ObjectSequencer`** (this round):
    `isBackground` now tests whether every point of the candidate's outer
    boundary actually falls inside the containing shape's outer polygon
    (`PolygonGeometry.pointInPolygon`, a new even-odd ray-casting test,
    plus polygon area via the existing `signedArea` instead of bounding-box
    area), not just whether the bounding boxes nest. A concave (e.g.
    L-shaped) object can have a bounding box that encloses something
    sitting entirely in its notch, outside its real area — a case the
    previous bounding-box-only check would misclassify as containment and
    wrongly reorder. The bounding-box check is kept as a cheap pre-check
    before the real (more expensive) polygon test.
11. **Minimum satin width, for lettering quality** (this round):
    `StitchTypeClassifier` already had a hairline-width cutoff (a shape
    whose *average* width is too thin for satin sews as running stitch
    instead) — but a shape whose average is fine can still narrow below
    the practical minimum in one section (a tapering stroke, a serif) and
    the classifier's single average never sees it, the exact mirror of
    the "too wide" gap `generatePartial` closed earlier this round. The
    old classifier-only cutoff is now `StitchGenerationParameters.
    minSatinWidthMM` (a per-object, overridable value, matching
    `maxSatinWidthMM`'s existing treatment — the classifier and generator
    now share the same value instead of the classifier hard-coding its
    own), and `SatinColumnGenerator.generatePartial` checks it per
    crossing (only in the crossing-index interior, excluding the natural
    end-cap taper zone every column has — see `interiorRange`), converting
    a genuinely too-narrow run into a triple-run (bean-stitch) line along
    the centerline instead of a satin zigzag. `generate` (the strict
    variant) throws a new `columnTooNarrow` error for the same condition,
    symmetric with its existing `columnTooWide`.
12. **2-opt local-search refinement of object sequencing** (this round):
    the greedy scheduler is inherently short-sighted — it can't see that
    the locally-nearest candidate now leaves a worse jump later, the
    classic failure mode being two spatially separate clusters visited in
    an interleaved zigzag instead of one cluster then the other.
    `ObjectSequencer` now follows the greedy construction with a bounded
    2-opt pass: repeatedly try reversing a contiguous stretch of the
    order (with each item's own entry/exit choice flipped too, so it's
    still approached from a self-consistent end) and keep it only if it
    lowers total cost (color changes weighted far above raw distance, so
    it never trades color grouping away for a shorter jump) *and* doesn't
    place a contained object before whatever must contain it — checked by
    rejecting any reversal whose range contains both ends of a
    containment edge, proven safe in `twoOptImprove`'s doc comment
    (nothing outside a reversed range ever changes its absolute
    position, so a containment edge with only one end inside the range
    can never be violated by that reversal). Reversing a stretch and
    flipping each item's own direction leaves every edge *inside* the
    stretch unchanged (same two points, distance is symmetric), so only
    the two boundary edges need re-scoring per candidate reversal — this
    is what makes an exhaustive O(n²)-per-pass search tractable instead
    of needing to recompute the whole tour's cost per candidate.
    Verified with a hand-worked nearest-neighbor trap (5 points at
    x = 0, 1, -2, 4, -8): greedy alone produces a 22mm tour, matching a
    by-hand trace; 2-opt finds the single reversal that reaches 16mm,
    matching the fixed-start optimum found by hand-enumerating all
    orderings.
13. **Hidden travel routing** (`HiddenTravelRouter`, this round): a
    same-color jump long enough to need a trim gets routed as buried
    running stitch instead, when the straight path from the previous
    object's exit to the next object's entry lies entirely inside the
    *next* object's own shape. Deliberately scoped to only this provably
    safe case rather than the general one (any later object, not just
    the immediate next, potentially covering it) — since the next object
    is sewn immediately afterward, its own stitching is guaranteed to
    cover that exact area, no assumption about anything else needed.
    Coverage is checked by sampling several points strictly *between*
    the two endpoints (excluding the endpoints themselves — B's entry in
    particular sits essentially on B's own boundary by construction,
    which is a numerically ambiguous case for even-odd point-in-polygon
    testing and irrelevant to the decision anyway, since a plain jump
    would travel between the same two fixed points regardless).
    `PolygonGeometry` gained `pointInPolygons` (even-odd across multiple
    closed loops at once, so a shape's hole sub-paths are respected — a
    point inside the outer boundary but also inside a hole is correctly
    "not covered"). Only fires above the actual trim threshold in use,
    since a same-color jump short enough to not need a trim already
    becomes an untrimmed thread carry that ends up buried the same way
    once the next object covers it — bridging that case would only add
    stitches for no benefit.

## Known remaining weaknesses

- Object sequencing is a greedy-plus-2-opt heuristic, not a real
  graph-based router the way Ink/Stitch's `auto_satin` builds for satin
  columns specifically (which restructures the column *itself* into a
  running-stitch graph and finds a path through it, not just orders
  whole pre-built objects) — 2-opt improves on pure greedy but still
  isn't a guaranteed jump-minimal order (it can converge to a local
  optimum a smarter move set would escape), and it can't reorder across
  a containment constraint (nor should it).
- No contour fill (needs a robust repeated polygon-offset primitive this
  project doesn't have yet).
- Width-aware satin splitting classifies each crossing independently
  against a single global `maxSatinWidthMM`; it doesn't yet consider
  stitch density transitions at a narrow/wide boundary (the crossing right
  at a satin-to-fill seam can be visually abrupt), and a lone over-width
  crossing is deliberately folded back into satin rather than becoming a
  one-crossing fill sliver (see the doc comment on `generatePartial`) —
  reasonable for noise, but it means a column that's *genuinely* right at
  the width boundary in one narrow spot stays satin there rather than
  fill, which is the intentional, documented trade-off, not a bug.
- Fill angle candidates are evaluated by a single geometric heuristic
  (principal axis), not by the fuller scoring spec §6 describes (visual
  appearance, travel efficiency, neighboring-object direction) — those
  additional signals aren't wired in yet.
- `ObjectSequencer`'s polygon containment test only checks the *outer*
  boundary of each shape (`subPaths.first`), ignoring holes — an object
  sitting inside another's hole (visually outside the shape, even though
  geometrically inside its outer boundary) would still be misclassified
  as contained. Rare for typical logo/badge artwork; a real fix needs an
  even-odd test against all of a shape's sub-paths together, not just the
  first.
- No physical stitch-out calibration exists for any of this — all
  compensation/density values remain rule-based estimates pending real
  sew-out data, consistent with `PullCompensationCalculator`'s existing
  documented caveat. Push compensation reuses pull's exact formula (just
  measured along the length axis instead of the width axis) for the same
  reason: no calibration data exists yet to justify a differently-shaped
  one.
- Push and pull compensation are estimated independently per object/
  sub-region without accounting for how they interact — e.g. a satin
  column's width-aware fill sub-region (`generatePartial`) has both
  zeroed out explicitly (since they're already baked into its boundary by
  the parent column), but two adjacent *unrelated* objects each getting
  their own independent push/pull estimate could still compound in ways
  neither estimate alone accounts for.
- Minimum satin width has the same abrupt-seam and lone-crossing caveats
  as maximum satin width (see the width-aware splitting item above) —
  a triple-run/satin seam can be visually abrupt, and a single
  below-minimum crossing is deliberately folded back into satin rather
  than becoming a one-crossing line, by the same reasoning.
- No lettering-specific handling beyond per-crossing minimum/maximum
  width: small counters (the enclosed holes in letters like "e", "a",
  "o") that are too small to fill at normal density aren't detected or
  simplified, and there's no small-text-specific underlay or sequencing
  (letters are still just individually-classified objects, ordered by
  the same general-purpose scheduler as anything else).
- ~~`HiddenTravelRouter` only bridges into the *immediate next* object,
  not any later one~~ — **done**: it now checks every object still to
  come in the sew order (bounded, mirroring `ObjectSequencer.
  maxObjectsForTwoOpt`'s own reasoning), regardless of color, for
  coverage. See `DIGITIZING_ENGINE.md`'s corresponding entry for the
  honest measured result: zero trim-count change on the two real
  tatami-dominated files this was tested against, since the gating
  requirement (`nextObjectCanHideATravelPath`, satin only) is unchanged
  and neither file has a satin object positioned to cover their long
  gaps. The remaining, genuinely higher-value and higher-risk work for
  designs like those is row-aware tatami-fill coverage (below), not
  more lookahead.
- Tatami fill can never hide a buried travel stitch in this engine,
  regardless of how much lookahead `HiddenTravelRouter` has — even
  though a path running roughly *parallel* to the fill's own rows
  would, in principle, actually stay hidden the same way a hand
  digitizer routes travel along a fill's grain; only a path cutting
  *across* the row gaps is genuinely unsafe. The current all-or-nothing
  satin-only gate is deliberately conservative because getting this
  wrong produces a visible defect on real fabric, not just a
  code-quality issue — real, unscoped design work, now the top
  remaining item for reducing trim count on any wide-fill-dominated
  design (confirmed the dominant cost on a detail-heavy real file, the
  PiperStitch bird mark: ~260 trims against only 5 color changes).

## Recommended next improvements, in priority order

1. Row-aware tatami-fill coverage for `HiddenTravelRouter`: let a travel
   path hide within a fill's own rows when it runs close enough to
   parallel with them, instead of excluding tatami fill as a coverer
   outright. Needs careful geometric scoping (checking alignment with
   the fill's own rotated scanline angle, not just polygon containment)
   and real verification before shipping, given the visible-defect risk
   of getting it wrong.
2. Contour fill, once a real polygon-offset primitive exists.
3. A real graph-based router for satin objects specifically, the way
   `auto_satin.py` does — restructuring a satin column into a
   running-stitch graph and finding a path through it, rather than
   `ObjectSequencer`'s current per-object greedy-plus-2-opt ordering
   (which now uses real endpoints, can reverse a path, and applies a
   bounded local-search refinement, but still treats each object as an
   atomic, pre-built unit rather than routing through its structure).
4. Smooth the stitch-density transition at a width-aware satin split's
   narrow/wide seam (see `generatePartial`'s known limitation above) —
   currently a clean but abrupt technique change at the boundary.
5. Extend `ObjectSequencer`'s polygon containment test to all of a
   shape's sub-paths (not just the outer boundary), so an object sitting
   inside another's hole isn't misclassified as contained.
6. Skeleton/medial-axis-following fill direction for curved or tapered
   shapes, the technique PEmbroider's `PEmbroiderHatchSpine` uses (see
   above) — `FillAngleSelector` currently picks one fixed angle for the
   whole shape, which is visibly wrong on part of an organic shape (a
   curved letter, a leaf) that a direction-following fill handles
   correctly. Real, unscoped design work: needs either a raster
   skeletonization pass or a polygon-based medial-axis approximation,
   neither of which exists in this codebase yet.
