# The Digitizing Engine

This document explains *how* StitchPilot turns artwork into stitches — the
actual professional-digitizing decisions, as opposed to `ARCHITECTURE.md`'s
description of how the code is organized. It's written to grow alongside
the engine: each phase's section below stays a stub ("not yet implemented")
until that phase lands, so this file is never aspirational fiction about
capabilities that don't exist yet.

## Phase 1 — Running stitch (implemented)

The only stitch generator implemented so far. Given a `SubPath` (a flattened
polyline, open or closed) and a target stitch length, it resamples the path
by *arc length* rather than by input vertex (`RunningStitchGenerator.swift`):
walking the polyline and dropping a stitch point every `stitchLengthMM` of
travel. This matters because flattened bezier curves have unevenly spaced
vertices — stitching every vertex verbatim would put tiny stitches on tight
curves and long stitches on straight runs, which is exactly the kind of
"image converter" behavior this project exists to avoid (spec §79/§71).

After resampling, any consecutive points closer than `minStitchLengthMM` are
merged — an early, minimal version of the "stitch filtering" pass described
in spec §30; the full filter (long-stitch splitting, penetration-density
correction) is Phase 3+.

A `.tripleRun` variant sews the same resampled path forward, backward, then
forward again, for a stronger/more visible outline than a single running
stitch — the standard "bean stitch" technique used for outlines and small
lettering detail.

## Phase 1 — Sequencing (minimal, implemented)

`DigitizePipeline.flatten` turns an ordered list of objects into a flat
`StitchPlan`: same-color adjacent objects get a plain jump between them;
different-color objects get a trim + color change. This is intentionally
naive — it does *not* yet do hidden-travel routing, jump/trim minimization,
or registration-aware reordering (spec §23–§26); those are Phase 3.

## Phase 2 — Tatami fill (implemented)

`TatamiFillGenerator.swift` generates scanline ("tatami") fill for a closed
region: rotate the shape so the configured fill angle becomes horizontal,
walk scanlines at `fillSpacingMM` intervals computing edge-crossing
intervals with the standard **even-odd scanline fill rule**, resample each
interval into stitches at `stitchLengthMM`, alternate direction every row
(boustrophedon — consecutive rows connect with a short stitch instead of a
jump), stagger the stitch phase between rows by `fillRowStaggerMM` so seams
don't line up into a visible grid, then rotate back.

Using the even-odd rule across *all* of a shape's sub-paths together means
holes need no special case: a second sub-path (e.g. the counter of a letter
"O") just contributes extra scanline crossings that toggle the inside/
outside state, automatically excluding that region from fill — verified in
`TatamiFillGeneratorTests.holeIsRespected`. This directly implements the
"prevent negative spaces from closing" concern in spec §21, at least for the
geometric case; density/pull-driven closing of negative space (§21's other
concern — holes closing up under sewing tension) is a Phase 3
concern once pull compensation exists.

**Known limitation:** no underlay yet (Phase 3), and there is no minimum
run-length filtering — a scanline that clips a shape's corner can produce a
very short run/stitch. General stitch filtering (spec §30) is a dedicated
cross-cutting pass planned for Phase 3, applied after generation regardless
of which generator produced the stitches, rather than being reimplemented
per generator.

## Phase 2 — Satin column (implemented)

`SatinColumnGenerator.swift` generates a zigzag satin stitch across a
narrow column from a single closed boundary outline (no author-specified
centerline needed):

1. Find the shape's elongation direction via PCA on its vertices (the
   covariance matrix's principal eigenvector).
2. Find the two boundary *edges* whose average position is most extreme
   along that axis — the column's two end caps. This must operate on
   edges, not vertices: picking whichever two *vertices* are farthest
   apart fails on the simplest possible case, an axis-aligned rectangle,
   where the diagonal between two corners is longer than the distance
   between the short sides, and picking whichever two vertices are most
   extreme along the principal axis fails too, because a rectangle's short
   side has *two* vertices tied for the extreme with no vertex at the true
   end-cap midpoint. Only cutting at the edge itself, using its midpoint,
   finds the real ends.
3. Split the polygon into two rails at those edges, sharing each end cap's
   midpoint as both rails' start/end point.
4. Resample both rails to the same point count (by fraction of arc length,
   not fixed stitch length, so they pair up 1:1 regardless of individual
   rail length) at `satinDensityMM` spacing, and zigzag between
   corresponding pairs.
5. If the widest pairing exceeds `maxSatinWidthMM`, throw rather than
   silently produce unstitchable satin (spec §12's "automatically divide or
   convert excessively wide satin regions" — the divide/convert part is a
   Phase 4 auto-repair action; for now the engine refuses and reports why).

Works well for the common "sausage" case (letter strokes, simple logo
strokes, star points). **Known limitations:**
- Both rails share a single point at each end cap, so width tapers to
  exactly 0 at the very tip — correct for a genuinely pointed end (a star
  point) but an approximation for a flat/square-capped column (e.g. a
  plain rectangle), where real digitizing software sews a full-width
  closing stitch straight across instead of tapering into it.
  `SatinColumnGeneratorTests.straightRectangleColumn` checks width
  consistency only in the column's middle for exactly this reason.
- Branching or very irregular shapes aren't handled — robust
  centerline/skeleton-based detection for arbitrary geometry is a
  follow-up.
- No automatic classification of *which* shapes should become satin vs.
  fill vs. running stitch yet (next item below).

## Phase 2 — Automatic stitch-type selection (implemented)

`StitchTypeClassifier.swift` decides which of the three generators an
imported object should use, so the app's import path no longer hard-codes
`.runningStitch` for everything. The heuristic estimates a shape's average
width as `area / length-along-principal-axis` (the same kind of estimate a
person eyeballing a shape makes — "that's a thin stroke" vs. "that's a
blob") and buckets it: narrower than `minSatinWidthMM` (1.0mm, too thin for
a stable zigzag) -> running stitch; up to `maxSatinWidthMM` -> satin;
wider -> tatami fill. Wired into `AppState.regenerateFromStoredGeometry` so
drag-and-drop import classifies each detected shape automatically.
`PolygonGeometry.swift` factors the shared area/PCA math out of
`SatinColumnGenerator` so classification and generation can't drift into
measuring "elongation" two different ways.

`StitchTypeClassifierTests.classifiedObjectsAllFlattenSuccessfully`
specifically checks that everything the classifier produces can actually
be flattened by `DigitizePipeline` without throwing — guarding against a
classifier/generator threshold mismatch (e.g. classifying something as
satin that the generator's own width check then rejects).

## Phase 2 — Color quantization and multi-color raster segmentation (implemented)

`ColorQuantizer.swift` reduces a raster image's foreground colors to at
most N colors (spec §8's four presets — Preserve Artwork/Normal Embroidery/
Production Efficient/Minimal Colors — map to default max-color counts of
16/8/5/3) using k-means in perceptual (CIE L*a*b*) space, for the same
reason thread matching uses LAB (see below): Euclidean RGB distance doesn't
track how different two colors actually *look*.

Two things make this specific implementation worth calling out:

- **Histogram-then-cluster, not per-pixel clustering.** Pixels are first
  bucketed into a coarse histogram (reduced RGB precision) purely so
  k-means runs against hundreds of distinct colors instead of potentially
  millions of raw pixels — a multi-megapixel image still quantizes in
  milliseconds. The histogram bucket's *count-weighted average color* is
  used everywhere downstream, never the bucket's quantization boundary
  itself — using the boundary would visibly shift colors (pure white
  shifting to a slightly-off white) even when the image already had few
  enough distinct colors that no reduction was actually needed. A test
  (`fewerColorsThanMaxReturnsThemAllUnchanged`) pins this.
- **Deterministic clustering.** Cluster seeding uses a farthest-point
  heuristic (first center = most frequent color, each next = the
  remaining color farthest, weighted, from all chosen centers) instead of
  k-means++'s random seeding, and the histogram entries are sorted into a
  fixed order before iterating — Swift's `Dictionary` iteration order is
  not guaranteed stable, and depending on it for tie-breaking produced
  genuinely different quantization results across two calls with
  identical input during development (caught by
  `ColorQuantizerTests.isDeterministicAcrossRuns`, which exists
  specifically to keep this from regressing silently). This matters
  because quantization results feed directly into object segmentation —
  spec §54's determinism requirement isn't just about the final stitch
  generator.

`ImageImporter` then segments *per quantized color*: every foreground pixel
is assigned to its nearest cluster (memoized by exact RGB, since flat-color
artwork repeats exact values constantly), and connected-component labeling
+ contour tracing runs once per color, so a multi-color logo produces one
object per color region with the region's actual color attached — not one
big region colored however the first pixel happened to be. Wired into the
app: a "Color Reduction" preset picker in the inspector re-imports the last
raster file at the new color count.

**A real bug surfaced while testing this**, worth recording because it's
easy to reintroduce: `CGColor(red:green:blue:alpha:)` constructs a color in
the *generic calibrated* RGB space, not whatever color space the target
`CGContext` was created with. Filling a `CGColorSpaceCreateDeviceRGB()`
context with such a color makes CoreGraphics color-match between the two
spaces, silently shifting saturated channels by dozens of units (pure red
rendered as `(255, 38, 0)` in one measured case) — invisible as long as
tests only checked shape *counts*, but breaks anything that checks pixel
colors. Test helpers now build colors with `CGColor(colorSpace:components:)`
directly in the context's own color space instead.

## Phase 2 — Thread library and matching (implemented)

`ThreadLibrary.swift` provides the matching engine spec §9 actually
requires — `nearestMatch`/`nearestMatches` against any `[ThreadColor]`
palette via `RGBColor.deltaE` — plus a ~40-entry generic palette
(originally named, not sourced from or matched to any manufacturer's
catalog: spec §9 explicitly says not to copy proprietary thread databases
without licensing, "provide generic RGB/LAB thread matching regardless").
Because the matching engine takes an arbitrary palette, a future "My
Thread Inventory" (spec §9) or a licensed manufacturer catalog both slot in
without changing `nearestMatch` itself — only the palette passed to it.

Wired into the app: `AppState` now snaps each detected artwork color to its
nearest thread match by default (a "Match to thread library" toggle turns
this off to keep exact artwork colors instead), and the object list shows
each object's matched thread name.

## Phase 2 (continued) — thread match confidence and poor-match fallback (implemented)

`nearestMatch` always confidently returned the closest available palette
entry, no matter how far off it actually was — no quality signal, and no
way for a sparse or narrowly-curated custom/manufacturer thread library
(a user's own "My Thread Inventory," or one manufacturer's catalog with
only a few colors actually added) to do anything but silently hand back
whatever's nearest *within itself*, even a strikingly wrong-looking color
for something the palette simply has nothing close to. This is the
engine's best explanation for a real customer report: a logo's navy came
back as teal in the digitized preview, while the exact same file matched
correctly against the engine's own built-in generic palette — consistent
with an account thread library that had nothing near navy in it.

`ThreadLibrary` gained `MatchQuality` (excellent/good/acceptable/poor, by
Delta-E band) and `bestMatch`, which returns a `ThreadMatch` carrying the
match's Delta-E and quality alongside the color. When the caller's own
palette scores `poor` (Delta-E > 20), `bestMatch` also checks the generic
palette and returns whichever is genuinely closer, flagging `isFallback`
when that happens — never inventing a match closer than what's actually
available in either palette, only widening the search once the caller's
own answer is bad enough that a different one is more useful.

`nearestMatch` itself deliberately keeps its original strict behavior —
searching *exactly* the palette it's given and nothing else, even for a
poor result. A deliberately-curated "My Thread Inventory" needs this: the
point of restricting to an inventory is matching against what the user
actually owns, and silently suggesting a thread they don't have, just
because it looks closer on paper, would defeat that. `bestMatch` is the
opt-in sibling for callers with no such "deliberately restricted" intent
to respect — wired into both platforms' automatic import color-matching
(`AppState.regenerateFromStoredGeometry`, `StitchPilotServer.Engine.build`),
where the goal is genuinely "find the best available color," not "respect
an intentional restriction."

## Phase 2 (continued) — satin is the default, not one option among several (implemented)

`StitchTypeClassifier.classify` and `classifyLetteringRun` used to reject a
shape to tatami fill outright once its average width crossed
`maxSatinWidthMM` (12mm default), or — in an 8-12mm band — once its width
varied "too much" along its length. Both were whole-shape approximations
of a decision `SatinColumnGenerator.generatePartial` already makes for
real, per crossing (see the Phase 3 entry on width-aware satin splitting):
it classifies every individual crossing along a column as satin,
too-narrow (a triple-run centerline), or too-wide (a local tatami-fill
sub-region built from that run's own rail points), so a column that's
narrow at one end and genuinely too wide at the other already sews satin
where it fits and fill only where it doesn't. Rejecting the whole shape at
classification time, before generation ever got a chance to make that
finer-grained call, could only make a shape look worse than trusting the
generator — an otherwise satin-eligible letter or logo stroke downgraded
to fill entirely because one section, or its overall average, happened to
cross a fixed width line.

Both functions now default to satin whenever a shape clears the real,
structural limits — no holes (multi-sub-path), and
`canRepresentAsSingleSatinColumn` confirms the outline actually rail-fits
as one column (rejects genuine branching or a path that would escape its
own boundary) — regardless of width or width uniformity. `classify`'s and
`classifyLetteringRun`'s only remaining reasons to route to tatami fill
are these hard structural ones, or (per the harmonization pass below)
a same-color sibling that has them.

This composes directly with `harmonizeSameColorFillConsistency` (a same-
color group with any structurally fill-only member sews as fill
together): a word containing a multi-hole letter like "B" still correctly
sews its whole group as fill, since satin genuinely isn't practical for
every member — satin winning by default doesn't override a case where the
whole group genuinely can't support it, which is exactly the stated
policy ("most fills should be satin by default; only fall back where
satin isn't practical") applied consistently at both the single-shape and
same-color-group levels.

Verified against real files (`DigitizeCLI`): the muted visible change on
the two real test files this round otherwise worked with (Amerus, LIBBi)
is itself confirmation the composition above works as intended -- both
have same-color letter groups containing at least one hole-bearing
letter, so harmonization correctly keeps them fill for word-level
consistency regardless of the new default; a same-color group with no
such member (a swoosh element in Amerus) does pick up satin under the new
default where it previously wouldn't have. Tests updated across the
board: `wideBlobBecomesTatamiFill` and
`wildlyTaperingShapeInTheMediumBandBecomesTatami` are now
`wideBlobStillClassifiesSatinButGeneratesAsEffectivelyFill` and
`wildlyTaperingShapeInTheMediumBandStillClassifiesSatin` (the classifier's
own decision, not a claim about what a genuinely wide blob's *rendered*
stitches end up looking like — see those tests' own doc comments). Full
suite (319 tests) passes.

## Phase 2 (continued) — a single hole is satin, not an automatic hard limit (implemented)

The entry directly above still described "no holes" as one of `classify`'s
hard structural limits alongside genuine branching — stale the moment it
was written: `SatinColumnGenerator.computeRails` already special-cases a
shape with exactly one hole (`shape.subPaths.count == 2`) and routes it to
`computeRingRails`, a real closed-loop ring column traced radially around
the hole, not the open-column/end-cap logic used for a holeless outline.
`classifyLetteringRun`/`classifyGlyphInRun` (Add-Lettering text) already
trusted this — a typed "A" or "R" sewed as a proper satin ring — but
`classify` (raster import) never did, forcing *every* hole, one or many,
straight to tatami fill regardless. A raster-imported logo's own "A"/"R"
therefore sewed visibly rougher than the exact same glyph typed through
Add Lettering, despite the engine having the ring support the whole time —
found by tracing through why Amerus's single-hole letters kept landing in
fill even once satin became the default above.

`classify` now only forces tatami fill for *more than one* hole
(`subPaths.count > 2` — two separate counters, as in B or 8), which really
is a hard limit: `computeRingRails` only ever traces one hole against the
outer boundary, same as `classifyLetteringRun`'s existing two-hole cutoff.
A single hole (`subPaths.count == 2`) returns `.satin` directly, without
calling `canRepresentAsSingleSatinColumn` — that guard only ever validates
a single, holeless boundary (`guard shape.subPaths.count == 1 else {
return false }`), so it can't confirm or deny a ring at all;
`classifyLetteringRun` already trusts single-hole glyphs the same way,
falling back to tatami only through `DigitizePipeline`'s existing `catch
SatinGenerationError.shapeNotSuitable` if a genuinely irregular hole (an
off-center or oddly-shaped counter `computeRingRails`'s radial sweep can't
trace consistently) can't actually rail as a ring at generation time —
this is the same fallback pattern already shipped for every other satin
structural failure, not a new safety net. `harmonizeSameColorFillConsistency`
needed no change: it already treated `subPaths.count > 2` (not `> 1`) as
the "structurally fill-only" cutoff, so it was already prepared to let a
single-hole sibling stay in a satin group once `classify` itself stopped
forcing it to fill first.

Verified against real files (`DigitizeCLI`, with a temporary debug print
of pre-harmonization classification, removed before committing): Amerus's
single-hole navy letters (subPaths=2) now classify `.satin` directly out
of `classify`, confirming the fix at the per-shape level. Their word-level
result stays `.tatamiFill` after harmonization — correctly, since other
navy siblings in the same word have `subPaths=3` (a genuine two-hole
letter or raster-tracing artifact) and are structurally fill-only, pulling
the whole group to fill for consistency exactly as the entry above and
the user's own stated policy ("complete all letters in a sequence using
the same fill") intend; that pull-down is unrelated to hole count being
one vs. many and was already correct before this fix. LIBBi's main word
similarly stays fill (it contains a genuine two-hole "B"). Two new
regression tests replace the old blanket-hole test:
`singleHoledShapeClassifiesAsSatinRingColumn` and
`columnWidthShapeWithTwoHolesBecomesTatamiFillNotSatin`; the outlier-
reconciliation fixture (`solidSquareWithHole` →
`solidSquareWithTwoHoles`) was updated to use a genuinely two-hole square
so it still exercises the tatami-consensus path it was written for. Full
suite (320 tests) passes; server package builds clean.

## Phase 2 (continued) — branching-letter satin (stages 1-3, behind `allowBranchingSatin`, default off)

A genuinely branching outline — a letter whose strokes meet at a real
junction rather than one continuous "sausage" (A's crossbar, B's stem
against its two bowls, H's crossbar between two stems) — has never been
representable as satin in this engine: `SatinColumnGenerator.
canRepresentAsSingleSatinColumn` correctly rejects it (a single global PCA
axis and one pair of end-cap edges can't rail-fit something that forks),
and `classify`/`classifyLetteringRun` both fall back the whole shape (or
whole lettering run) to tatami fill. Real per-stroke skeleton
segmentation was flagged as "a substantially larger, separate undertaking"
in both functions' own doc comments from early in this project — this is
that undertaking, built and merged in three explicitly staged, gated
increments rather than one large change, per the design review before any
of it was written.

**Stage 1 — `StrokeTopologyAnalyzer.swift` (topology graph only, nothing
wired in).** Rasterizes a shape onto a temporary pixel grid, extracts a
1px skeleton (Zhang-Suen thinning, plus a residual-2x2-block cleanup pass
— a well-documented Zhang-Suen limitation where a solid 2x2 block
satisfies neither sub-iteration's deletion conditions and survives
un-thinned), then walks that skeleton into a graph of nodes (junctions,
endpoints) and edges (individual stroke segments, each carrying a local
width profile sampled from a chamfer distance transform). Chosen over a
vector skeleton method (straight skeleton, Voronoi medial axis) precisely
because those are more brittle on the near-degenerate, noisy boundaries
real raster-traced artwork actually produces — a concern this project has
hit directly and repeatedly (the anti-aliasing fragmentation fixes earlier
in this document exist for the same underlying reason).

Testing this against synthetic fixtures (a plain column, a T-junction, the
existing branching-H fixture, a circular ring) surfaced three real,
non-obvious bugs before any of it shipped, all now covered by regression
tests: (1) a raw 8-neighbor count misread an ordinary diagonal "staircase"
pixel as a false junction — fixed by counting *runs* of skeleton pixels in
the cyclically-ordered neighborhood instead, the same idea Zhang-Suen's
own transition-count criterion already uses; (2) a chain pixel approaching
a real junction could find that junction pixel grouped into the same run
as an unrelated pixel one hop further into a *different* branch — picking
the wrong one silently merged two edges into one and left the junction
never actually visited, fixed by preferring a classified node pixel
whenever one is reachable, and otherwise the straightest continuation
rather than an arbitrary tie-break; (3) a node's own pixel was never added
to the walker's "already claimed" set, so the closed-loop walker could
mistake an endpoint for untouched skeleton and re-trace an already-
complete edge as a phantom duplicate — caught by the simplest possible
fixture, a plain straight column. Two dead-end fixes (a sub-pixel jitter
on the raster origin, interleaving the 2x2 cleanup into Zhang-Suen's main
loop) were tried against a stubborn circular-ring artifact, measured, and
reverted when they broke previously-passing cases instead of helping —
the actual fix was recognizing the artifact came from an adversarially
exact geometric symmetry in the *test fixture itself* (a regular polygon
with a facet landing exactly horizontal, real logos essentially never
produce this), plus a minimum-length floor to drop genuine thinning-
residue micro-loops.

**Stage 2 — `SatinColumnGenerator.canRepresentAsBranchingSatinColumn`/
`generateBranching` (still not wired in).** For each topology edge,
rail-fits a local column by casting perpendicular to the segment's own
tangent at each centerline sample — the same ray-casting primitive
`computeRingRails` already uses for its fixed radial sweep, just re-aimed
per sample instead of from one center — resamples and crosses each
segment independently (`computeSegmentCrossings`, a simplified sibling of
`computeCrossings` with no push-compensation trim and no
`crossingsEscapeTheShape` check, both meaningless for one piece of a
larger connected shape), then concatenates every segment in stroke-graph
walk order into one flat `[Point2D]` stitch list — the exact same
contract `generate`/`generatePartial` already return, so nothing
downstream (`DigitizePipeline`, sequencing, hidden-travel routing, every
export format) needs to know a shape's satin came from one column or
several. Junctions get no dedicated fan/patch yet — consecutive segments'
near-junction crossings simply follow each other in the flat list, an
explicit, documented simplification rather than a hidden gap.

Testing surfaced one more real bug: a segment sample near a junction sits
where the whole shape's boundary has "opened up" into the connecting
branch (the left stem of an H, right where it meets the crossbar) — a
perpendicular ray-cast there can sail past where the stem's own boundary
would be in isolation and hit the far boundary of the *other* branch
instead, since that point is genuinely interior to the combined shape.
Fixed using `StrokeTopologyAnalyzer`'s own local width estimate (computed
independently via the distance transform, not a whole-boundary ray-cast,
so it doesn't share this failure mode) as a sanity bound: a ray-cast hit
farther than twice that estimate is rejected as having escaped into an
unrelated branch rather than trusted as this segment's own edge.

**Stage 3 — wired into `classify`/`harmonizeSameColorFillConsistency`/
`reconcileRunningStitchOutliers`/`DigitizePipeline`, behind
`StitchGenerationParameters.allowBranchingSatin` (default `false`).** With
the flag off, all 333 existing tests passed unchanged, confirming the
wiring is purely additive. With it on: `classify` now tries
`canRepresentAsBranchingSatinColumn` as a second-tier check after the
single-column path fails; `DigitizePipeline`'s `.satin` case tries
`generateBranching` inside its existing `catch SatinGenerationError
.shapeNotSuitable` handler, before falling through to the tatami-fill
safety net that already existed for every other satin structural failure;
`harmonizeSameColorFillConsistency` and `reconcileRunningStitchOutliers`
both learned to treat a branching-eligible member the same way they
already treat a single-hole ring member — neither forcing its color group
to fill nor contributing to the group's own width decision, just
following whatever its "simple" siblings decide. 11 new tests cover the
flag both on and off, including an end-to-end `DigitizePipeline.flatten`
call proving the branching H shape produces real satin-density stitch
coverage (not just a tatami fallback) once opted in.

Verified against real files (`DigitizeCLI`, with a temporary `ALLOW
_BRANCHING_SATIN` env-var toggle and a per-object eligibility debug
print, both removed before committing): flag on vs. off produced
*byte-identical* output on all three files (Amerus, LIBBi, the bird
mark) — an honest null result, not a failure. Every object that reaches
the branching check either has more than one sub-path already (a real
hole or, far more often on these three files, raster-tracing
fragmentation noise the branching path doesn't attempt to handle) or is
too thin to reach the check at all (classified `.tripleRun` by the width
floor first); among the handful of single-boundary objects that do reach
it, essentially none pass `canRepresentAsBranchingSatinColumn` on these
files' actual (noisy, small-scale) geometry. This matches the risk
flagged before any of stages 1-3 were written: skeleton extraction is
tolerant of noise relative to vector methods, but not immune to it, and
none of the three existing real-file fixtures happens to contain a large,
clean, single-boundary branching letter to exercise the path against.
The flag stays off by default regardless — this result doesn't block
correctness, it just means these three files aren't the evidence that
would justify defaulting it on. A fourth test file purpose-built with a
bold branching wordmark (a large "H," "A," or "T") would be a more
informative next real-file check than re-running these same three again.

**Follow-up — two real files with genuine large-letter geometry, two
different diagnoses, two real fixes.** A LIBBi wordmark SVG (clean vector
paths, not raster-traced) and a bold "A" logo (a large filled letterform
with a star cutout and a ribbon cutting across it) both still produced
byte-identical flag-on/flag-off output, but for informative, different
reasons this time rather than "nothing reaches the check at all":

- On the LIBBi SVG, every letter with real bulk either already has a
  hole (routes through the existing ring path, no branching needed), is
  a genuinely curved single-boundary letter (U, C, S) that fails the
  *single-column* check for curvature reasons unrelated to branching —
  confirmed directly by checking its topology: 0 junctions, a plain open
  curve — or, for this specific font's "H," has small enclosed
  serif/terminal details (confirmed by isolating and rendering just that
  object) that put it at `subPaths.count == 3`, outside the branching
  path's current single-boundary-only scope entirely.
- On the "A" logo, one large single-boundary piece *did* reach the
  branching check with a real junction in its raw topology (2 junctions,
  5 edges before pruning) — but investigating exactly why it still
  failed surfaced two genuine, separate defects, both now fixed with
  their own regression tests:
  1. **A real pruning bug.** `prune()` correctly collapses a junction
     down to a straight-through edge once its degree drops to 2, but had
     no equivalent handling for degree dropping to 1 (both of a
     junction's real branches pruned as noise, leaving only one
     surviving edge) — the node stayed mislabeled `isJunction: true`
     with nothing left to actually branch into.
     `junctionPrunedDownToOneEdgeIsDemotedNotMislabeled` in
     `StrokeTopologyAnalyzerTests.swift` reproduces this with a short-
     armed T (both bar arms short enough to prune) and confirms the
     surviving node is correctly demoted to a plain endpoint. Fixing
     this did *not* change the "A" 's own final classification — once
     correctly demoted, this particular piece has no real junction left
     at all (both raw branches had highly suspicious 0.2mm endpoint
     widths, the classic signature of thinning noise, not real
     letterform structure) — but the mislabeling itself was a genuine,
     independently worth-fixing defect regardless of this one shape's
     outcome.
  2. **A real, previously-latent safety gap.** `computeSegmentCrossings`
     had no equivalent of `generatePartial`'s per-crossing width
     handling — nothing stopped it from happily rail-fitting a segment
     20mm+ wide (this "A" is a genuinely wide tapering blob in
     places, not a uniform-width letter stroke) into "satin" zigzag
     stitches impractically wide to actually sew. Added the same strict,
     all-or-nothing `maxSatinWidthMM` check `generate` itself already
     uses, covered by `branchingDeclinesASegmentWiderThanMaxSatinWidth`.
     This hadn't caused any visible bad output yet (nothing had reached
     this code path on a wide shape before), but was a real latent risk
     worth closing on principle before it ever does.

Both fixes are structural correctness fixes, not tuning — full suite (339
tests) still passes, and the "A" logo's own flag-on/flag-off output
remains byte-identical (confirmed via a direct rerun) since this
particular piece genuinely has no real branch left once pruning is
correct. The broader, softer question this investigation surfaces but
doesn't answer — whether `pruneBranchLengthFactor`'s 1.5× local-width
scaling, calibrated against letter-stroke widths (1–5mm), is still well-
calibrated for a bold, solid, non-letter logo shape whose local width can
legitimately reach 15-20mm — remains open; the two genuine branches this
"A" piece had were correctly noise (0.2mm endpoint widths) rather than a
casualty of that scaling this time, but a future file might present a
real, wide branch close enough to the threshold that this becomes the
deciding factor rather than a side detail. Worth revisiting with a file
that actually has one, rather than tuning speculatively now.

## Phase 2 (continued) — branching satin extended to shapes with holes (stage 4, still behind `allowBranchingSatin`)

Four real files in a row (a LIBBi SVG, a bold "A" logo, a Boston Red Sox
"B") all hit the same wall: every letter with genuine branching structure
(B, R, and this session's synthetic "P" test fixture) turned out to need
holes *and* branching at once, not pure holeless branching — `generate
Branching`'s `shape.subPaths.count == 1` guard, a deliberate stage-2
scoping decision rather than an implementation limit, was declining
every one of them outright. This stage removes that restriction.

**The topology layer needed zero changes.** `StrokeTopologyAnalyzer`'s
rasterization already fills even-odd across every sub-path (outer minus
every hole), so a hole was already "background" to the skeleton before
this stage touched anything — verified directly against a synthetic "B"
fixture (a stem with two bowls, each with its own hole), whose topology
came back with each hole's own loop as a clean self-loop edge
(`startNodeID == endNodeID`), connected into the wider graph through real
junction nodes, entirely with stage 1's unmodified code.

**The generation layer needed real work, and testing surfaced three more
genuine, non-obvious bugs before any of it shipped:**

1. **Rail-casting only looked at the outer boundary.** A segment near a
   hole (a stem sitting between a letter's bowls) needs its perpendicular
   ray to stop at the *nearest* boundary in either direction, which is
   just as often a hole's own edge as the outer one — a ray checked only
   against the outer polygon would sail straight through an intervening
   hole to the far side. Fixed with `rayPolygonsIntersection`/
   `rayPolygonsIntersections`, checking every one of a shape's boundaries
   at once and taking the nearest (or nearest two) crossings.
2. **A rail sample near a junction can lose one side entirely, not just
   land implausibly far.** Exactly where a hole's own loop passes closest
   to where it connects to the rest of the shape, one side of the
   perpendicular ray correctly finds the nearby hole edge while the other
   escapes into the connected branch's own distant boundary — the same
   "boundary opened up into a connected branch" issue stage 2 already
   found and bounded with a width-tolerance check, just encountered here
   from a loop's own polyline instead of an open segment. Rather than
   dropping these samples (which lost roughly a third of a loop's own
   centerline in the fixture that found this), the missing side is now
   reconstructed by reflecting the valid one across the sample point at
   the topology's own local half-width — sound because that point *is*
   the medial axis by construction, so it should sit equidistant from
   both true boundaries regardless of which single side the ray-cast
   actually found (`mirroredAcross`).
3. **A self-loop's own rails still twisted even with full, sound
   coverage** — the deepest and most informative bug of the three.
   `computeSegmentRails` walks a segment's own polyline and casts
   *locally*-perpendicular rays at each arc-length sample; `computeRing
   Rails`'s own doc comment already explains why that "arc-length-based
   pairing" is exactly the wrong technique for a closed loop, which needs
   angular correspondence from one fixed center instead — reusing the
   generic segment technique for a self-loop edge was reintroducing the
   precise failure mode `computeRingRails` was built to avoid in the
   first place. Fixed with `computeSegmentRingRails`, a self-loop-specific
   radial sweep from the loop's own centroid (generalizing `computeRing
   Rails`'s technique to however many boundaries a branching shape's full
   sub-path set has, via `rayPolygonsIntersections`'s nearest-two
   crossings rather than querying one fixed hole/outer pair directly).
   Even after that fix, a second, related bug remained: `computeSegment
   Crossings` called `isTwisted` unconditionally, where `computeCrossings`
   (the original single-column path) explicitly *exempts* a closed ring
   from that same check — a radial sweep can't produce a twisted zigzag
   by construction, and applying the check's own margin-exclusion logic
   (built for an open column's real, tapered ends) to a loop with no such
   ends was actively wrong, not merely redundant. Fixed by detecting a
   closed rail pair (`railA.first == railA.last`, the same convention
   `computeSegmentRingRails` and `computeRingRails` both already close
   their rails with) and skipping the check for it, matching
   `computeCrossings`'s own established behavior exactly.

All three fixes were found and verified against one evolving synthetic
"P" fixture (a stem feeding into one bowl with a hole) — chosen after an
early, cruder attempt (a two-bowl "B") produced enough simultaneous
topology noise and geometry issues to make isolating any *one* bug
impractical; the discipline that served every earlier stage well
(minimal fixture, one clear failure, one fix, re-verify) applied here
too. The final, cleaned-up "P" fixture succeeds end-to-end under
realistic default parameters (`maxSatinWidthMM` at its normal 12mm, not
loosened) — 316 stitches, zero points outside its own bounding box —
covered by `branchingAcceptsAPLetterformWithAStemAndOneHole` in
`BranchingSatinGeneratorTests.swift`. Full suite (340 tests) passes,
server package builds clean.

## Phase 2 (continued) — stage 4 completed: two-hole "B" proven, wiring extended, real files re-measured

The three items the entry above left open are now done.

**A genuine two-hole "B" succeeded on the first attempt** once the three
bugs above were fixed — `branchingAcceptsABLetterformWithAStemAndTwoHoles`
in `BranchingSatinGeneratorTests.swift`, same proportions/methodology as
the one-hole "P" fixture, no new fixes needed. This confirms those three
fixes were genuine and general rather than curve-fit to one shape.

**`classify`, `harmonizeSameColorFillConsistency`, and
`reconcileRunningStitchOutliers` now extend their existing
`allowBranchingSatin` allowance to `subPaths.count > 2`** the same way
they already did for the single-hole (`subPaths.count == 2`) case in
stage 3 — a multi-hole shape gets one more real attempt via
`canRepresentAsBranchingSatinColumn` before falling back to tatami fill,
still strictly behind the same opt-in flag. 8 new tests cover this (18
total in `BranchingSatinGeneratorTests.swift`), including end-to-end
`DigitizePipeline.flatten` proof for both the one-hole and two-hole
cases. Full suite (345 tests) passes; server package builds clean.

**Real-file re-verification: still byte-identical, but now for a
precise, different, and narrower reason.** Re-ran Amerus, the LIBBi SVG,
and the Boston Red Sox "B" (the file that originally prompted stage 4)
with the flag on. All three real "B"s — LIBBi's and the Red Sox's — now
reach genuine topology with real junction structure and attempt
`generateBranching` for the first time (confirmed directly: the Red Sox
"B" resolves to 6 nodes, 4 junctions, 7 edges from its actual raster-
traced geometry), which is real, verified progress — the multi-hole
wiring is doing exactly what it's supposed to. But every one still fails,
and this time isolating why pointed at something new: a thin, tapering
tip edge (0.2mm down to 2.6mm wide over ~5mm of length — a serif-like
detail or raster-tracing artifact at a stroke's own end) triggers
`isTwisted`. Branch segments have no equivalent of the single-column
path's tapered end-cap handling (`computeRails`' own squared-vs-pointed
end logic) — every edge is treated as a uniform mid-column strip, and a
genuinely near-zero-width tip pushes `isTwisted`'s adjacent-crossing
check into exactly the kind of near-degenerate geometry it's meant to
catch, whether or not the tip itself is structurally sound. This is a
different, narrower gap than any of the three bugs fixed earlier in this
stage — those were about *whether a segment's rails come back sound at
all*; this one is about *one specific, real segment shape* (a tapering
tip) that branch segments don't yet have dedicated handling for, the
same category of "known simplification, not a hidden gap" stage 2's own
doc comment already flagged for junction stitching.

## Phase 2 (continued) — stage 4 real-file hardening: the Red Sox "B" now succeeds

Continued investigation of the thin-tip failure above turned up something
different from what it first looked like: the tapering tip wasn't the
real (or only) problem. Two follow-up ideas were tried and both proved
insufficient on their own, but the diagnostic work they produced pointed
at the actual mechanism, which was then fixed directly. All tests
(346 total, including a new one added for this) pass throughout; the
real Red Sox "B" is now genuine, verified, **positive** satin output —
the first real raster-traced branching-plus-hole letterform this engine
has produced real satin coverage for.

**Ruled out:** `taperCollapseWidthMM = 0.5` (collapsing near-zero-width
samples to a single point, mirroring the single-column path's pointed
end-cap convention) was implemented and kept -- it's correct and
non-regressing -- but alone didn't fix the real failure. Widening
`isTwisted`'s exclusion margin to 33% was tried and also didn't fix it,
and was cleanly reverted (no unproven complexity kept).

**The real cause, found via per-edge/per-crossing debug instrumentation
against the actual Red Sox "B":** not raster noise near a thin tip, but
three compounding effects in how `computeSegmentRails`/
`computeSegmentCrossings` fit rails to a segment at all, all traced to
concrete coordinates from the real file:

1. **Fixed-direction ray-casting can't find a corner except from one
   exact angle.** `computeSegmentRails` cast a single ray perpendicular
   to each sample's local tangent. Near a real boundary corner (e.g.
   where the "B"'s stem sweeps up into the wide junction both bowls
   share), many different nearby centerline samples all have that same
   corner as their true nearest boundary point -- but a fixed-direction
   ray only ever hits it from the one sample where the angle lines up
   exactly, and at every neighboring sample either misses it entirely or
   snaps on/off it discontinuously. Debug output showed this directly: a
   rail stayed pinned to the exact same physical point for several
   consecutive samples while the opposite rail advanced smoothly, width
   growing from ~4mm to ~10mm over a handful of samples -- an asymmetric
   "fan" that made adjacent crossings cross each other, exactly what
   `isTwisted` exists to catch, but for a real geometric reason, not
   noise. **Fixed** by replacing the fixed-direction ray-cast with
   `nearestBoundaryPoint` -- a genuine nearest-point-on-boundary search,
   restricted to each rail's own side via the same perpendicular sign
   test, but not restricted to one fixed angle. This tracks the true
   medial-axis pairing continuously as the sample moves, including
   smoothly approaching and leaving a corner, rather than only finding it
   from one angle.
2. **Branch segments had no curvature-aware crossing density.** The
   single-column path (`computeCrossings`) already resamples more
   densely on tight curves via `weightedPathLength`/
   `resampleByCountCurvatureWeighted` (see its own doc comment) -- branch
   segments (`computeSegmentCrossings`) never adopted this, using plain
   uniform resampling instead. A segment curving through a real
   letterform's own tight junction area needs the same treatment: too
   few crossings there rotate enough from one to the next to physically
   cross, even with structurally sound rails. **Fixed** by applying the
   same curvature-weighted resampling `computeCrossings` already uses.
   (A stronger curvature weight was tried experimentally, via a
   temporary environment-variable override, to see if it fully closed
   the gap -- it didn't, and at higher weights caused a runaway crossing
   count near sharp rail corners, hanging a real-file test run for
   minutes. That override was reverted; the default weight, 3.0,
   matching the single-column path, was kept.)
3. **A rail can faithfully track a real sharp facet long enough to pinch
   against its neighbor.** Even with (1) and (2) fixed, one isolated
   crossing remained: a real raster-traced boundary is a faceted polygon,
   not a smooth curve, and a rail correctly following an actual corner
   for a real physical stretch (not a fixed-angle artifact this time) can
   still be sharp enough, relative to a steadily-moving opposite rail, to
   pinch two adjacent crossings together. **Fixed** by smoothing the
   RAILS themselves (not just the input centerline, which
   `smoothedPolyline` already did per-sample to stabilize the ray/
   nearest-point direction) with a wider arc-length window
   (`railSmoothingWindowMM = 3.0`, vs. the centerline's own 0.6mm) --
   found empirically: 1.5mm and 2.0mm left one isolated pinch, 2.5mm was
   the first value to resolve it, 3.0mm was kept for margin.
   Over-smoothing a real corner on the RAIL side is a mild, expected
   rounding (routine in satin digitizing, where thread width itself
   can't represent a razor-sharp sub-mm corner anyway) -- a materially
   different risk than smoothing the centerline itself, which the
   smaller, more conservative window stays deliberately conservative
   about.

**Result:** all three of the real Red Sox "B"'s branch segments now
rail-fit successfully; `classify` returns `.satin` for it with
`allowBranchingSatin` on, and `generateBranching` produces genuine dense
coverage (visually verified via `DigitizeCLI`'s rendered PNG -- clean
satin direction following the stroke, no visible twisting). Amerus and
the LIBBi SVG were re-verified unaffected (Amerus byte-identical stitch
count; LIBBi's own "B" object still falls back to tatami -- a different
real shape with its own unresolved specifics, not a regression). A
permanent regression test,
`classifierReturnsSatinForARealRasterTracedBLogoWhenBranchingIsAllowed`
in `BranchingSatinGeneratorTests.swift`, imports the actual
`TestArtwork/Boston Red Sox.png` file directly and asserts real satin
classification and coverage -- none of the synthetic P/B fixtures above
are sensitive to any of the three effects fixed here, so this is the
only test that actually exercises them.

## Phase 2 (continued) — briefly defaulted on, reverted, then a real junction fix

`allowBranchingSatin` was briefly flipped to default `true` (the entry
above's own reasoning: purely additive, a shape that can't branch just
falls back to tatami as always). Reverted the same day: a HIGH-resolution
render of the real Red Sox "B" (only ever eyeballed at a lower preview
resolution before) showed a real, visible defect at every point where
branch segments meet -- `generateBranching`'s own doc comment had
already flagged "no dedicated fan/patch" as a known simplification, but
its actual visual severity (a sharp diagonal crease where the stitch
direction jumps, not a subtle rough edge) hadn't been checked. Reverted
via `git revert` (cleanly restores both the source and the tests that
depended on the old default together); confirmed real files
byte-identical to before the flip.

**The junction fix took four attempts, each fixing what it targeted while
exposing the next real problem:**

1. **Pairwise blend between consecutive segments** (interpolate new
   crossings between one segment's last crossing and the next's first,
   picking whichever point correspondence stays spatially closest to
   recover the two segments' own otherwise-unrelated rail-side labeling)
   — had no visible effect. Diagnosed why via `topology.nodes` dump: the
   Red Sox "B"'s own waist is a genuine 3-WAY meeting (the stem, the
   upper bowl's arc, and the lower bowl's arc all share one node), not a
   2-way seam -- a flat stitch list necessarily visits the three segments
   in SOME linear order, so at most two of the three meetings ever end up
   adjacent in it. Confirmed directly by zooming a high-res render on the
   exact node position: three visibly different stitch directions
   pinwheeling into one point.
2. **Small local fill patch**, built by collecting each incident
   segment's own single nearest-to-the-node rail point pair and sorting
   ALL of them by raw angle around the node -- patch existed but was
   invisible (too small: only the exact node-adjacent crossing
   contributed, no real reach into any arm).
3. **Larger version of the same patch** (pull in the last several
   crossings from each arm, not just one) -- made the self-intersection
   problem `nearNodePoints.sorted(by: angle)` has whenever a segment's
   own A/B rails sit far apart in angle (the ordinary case for a real
   stroke width) much worse: confirmed directly by rendering it, a
   sparse, gap-riddled zigzag instead of a solid fill, since the "polygon"
   crossed itself.
4. **Radial-sweep patch** — abandoned synthesizing a polygon from rail
   samples entirely; instead traced the shape's own REAL boundary around
   the node via the same proven radial-ray-cast-from-one-center technique
   `computeRingRails`/`computeSegmentRingRails` already use (star-shaped
   from a center by construction, so it can never self-intersect). First
   attempt sized the radius from the node's own `widthMM` directly (1.3x)
   -- catastrophically wrong, because a junction NODE's own width is the
   local stroke width where MULTIPLE arms' material overlaps (7.7-10.6mm
   at the Red Sox "B"'s own waist), not any one arm's ordinary width away
   from the junction; trimmed away most of a short connecting arm's own
   length, leaving huge visible gaps. Capping the radius (`0.4x` node
   width, hard ceiling 3mm) fixed the gaps, but handing the resulting
   small polygon to `TatamiFillGenerator` (a ROW-based fill) produced a
   dense, spiky, disconnected scribble -- confirmed directly by rendering
   it: a small region with real concave notches between arms routinely
   gets crossed more than twice by a single fixed-direction scanline row,
   splitting it into several disconnected pieces.

**What actually worked:** stitching the same radially-traced small
region as a radial FAN instead -- alternating between the node's own
center point and each boundary point in turn, all the way around
(`junctionPatchFill`'s final form). Every single stitch is a straight
line from a known-good center to a point already confirmed to be on the
real boundary, so it can never partially miss the shape the way a fixed
scanline can; this is also the standard real-world embroidery technique
for a small round/star patch (a "wheel"/rosette stitch), not a
workaround invented for this engine. Each arm's own crossings within the
same patch radius are trimmed off (the crease-causing crossings
themselves), so the fan fully replaces them rather than sitting
alongside them. Visually confirmed via high-resolution renders zoomed on
all three of the real Red Sox "B"'s junctions (the top hook/bowl meeting,
and both waist nodes): clean round rosettes bridging the different
stitch directions, not sharp creases -- a genuine, visible fix, not just
"no longer throws."

Verified: 346 tests pass; Amerus and LIBBi re-measured unaffected
(byte-identical stitch counts to before this fix); `allowBranchingSatin`
remains default `false` (this fix hasn't yet been through the same
"flip the default" gate the earlier entry's flip-and-revert was about --
a second, deliberate default flip is a separate future decision, not
automatic just because this specific defect is fixed).

## Phase 2 (continued) — a second real "B" (the cap logo): seven fixes from one file

Two new Red Sox test files (`TestArtwork/Boston Red Sox Cap.png`, a
960px cut on a solid navy ground, and the 4096px `boston-red-sox-logo.png`)
were reported as "left off the background, added colored lines, and
digitized in fill instead of satin." Every one of those symptoms traced
to a real, separate defect — most of them in code the earlier 96px "B"
had never exercised. In the order they were found:

1. **Stray "colored lines" were 1px anti-aliasing columns traced as
   their own objects.** `smoothAmbiguousBoundaryLabels` resolves a ramp
   pixel only when one confident side has a strict plurality of its
   neighbors; along a perfectly straight vertical or horizontal edge a 1px
   ramp column has exactly 3 confident neighbors per side and a dead 3-3
   tie at every pixel, so the whole column survived as a zero-width
   running-stitch object. Now a two-way tie is broken toward whichever
   side's color the pixel is actually nearer (`tieBreak`). The same 96px
   file had shown identical lines all along, mistaken for baseball-seam
   detail. Separately, `backgroundRampClusterIndices` now also flags a
   cluster lying between two larger *foreground* clusters (not just
   foreground/background) — `mergeAntiAliasingClusters` only folds a
   blend when both endpoints are ≥8% of pixels, so the navy/white blend
   column at each counter edge of the 96px file (white under 8%) had
   survived as its own tight, "confident" cluster. Both files now import
   as exactly their real objects (2 and 3), no slivers.
2. **"Background left off" is correct behavior, not a bug** — the cap
   file's navy fills the entire canvas, so it IS the page background by
   this importer's own corner-sampling rule, exactly as a white page
   would be. Documented here so it isn't re-investigated.
3. **A 3.1mm thinning-residue loop rejected the whole letter at 70mm.**
   `minimumClosedLoopLengthMM` raised 3.0 → 6.0; a real hole's skeleton
   loop is π × (hole + stroke) around, so nothing embroiderable falls
   under 6mm.
4. **The strict `maxSatinWidthMM` cap in `computeSegmentCrossings`
   rejected the letter at 100mm** (its bowls reach ~16mm). Removed;
   branch segments now go through the same per-crossing width split as
   a single column (`stitchesSplittingByWidth`, factored out of
   `generatePartial`). An over-wide stretch in a branch segment is sewn
   as **split satin** — the fewest parallel columns that each fit under
   the cap, alternating direction so the stretch stays one continuous
   pass — not a local tatami sub-region: a fill's rows run at their own
   angle and read as a jarring block of foreign texture dropped into
   the middle of a smooth satin arm (confirmed by rendering it).
5. **Hops between pieces were sewn straight across the counters.**
   `orderedEdges`' fallback (when nothing left touches the current node)
   took an arbitrary next edge as-is; it now starts the next leg from the
   nearest remaining edge end. And `generateBranchingRuns` (new; what
   `DigitizePipeline` now calls) breaks the output into separate runs
   wherever a hop's straight line would leave the shape, which
   `flattenWithColors` turns into a real trim+jump — same contract as
   `TatamiFillGenerator.generateRuns`. A hop that stays on the material
   is sewn and covered by what follows.
6. **The twist check ran on crossings the junction patch replaces.**
   `isTwisted` now runs inside `branchingPlan` on each segment's *kept*
   crossings only (using the full segment's own interior margin
   intersected with the kept range, so a trimmed segment is never
   checked more strictly than an untrimmed one). It also now treats two
   adjacent crossings that intersect within `fanPivotToleranceMM` of one
   of their own endpoints as a fan about a stalled inner rail (an inside
   corner doing what satin should) rather than a twist. And ring exemption
   is keyed off the edge being a self-loop, not `first == last` on the
   resampled rail (which differs in the last floating-point digit and had
   silently stopped exempting every ring — caught by the synthetic "P").
   `canRepresentAsBranchingSatinColumn` is now literally "does
   `branchingPlan` succeed," so it can never disagree with generation.
7. **Junction trim radius** is now half the node's own width (the
   inscribed-circle radius at the merge point), uncapped —
   `0.4x`/3mm-cap failed to reach the fan at all on the cap logo's 17mm
   waist. And **`pruneBranchLengthFactor` 1.5 → 1.0**: the 96px "B"'s
   own hook (9.5mm against a 7.1mm junction) was being pruned as a spur.
8. **`computeRails` now throws for more than one hole** instead of
   silently walking the outer boundary alone — after the sliver cleanup
   nudged the 96px outline by a pixel, that walk passed the twist check
   and sewed a solid red slab over both counters, pre-empting the
   branching path (`DigitizePipeline` only falls through to it once the
   single-column path throws).

Result, with the flag on: the 96px "B" at 100mm and the cap "B" at both
70mm and 100mm all sew as branching satin with rosettes at every
junction and nothing across a counter (rendered and inspected at
40px/mm). Flag-off output is byte-identical on the 96px "B" and LIBBi,
and identical in object count/classification on the Amerus mark. Two
new real-file tests lock this in (`realCapLogoBBranchesAtCapSizeWithNo
RunSewnAcrossItsCounters` checks every stitch's midpoint stays on the
shape). 347 tests pass. `allowBranchingSatin` remains default `false`;
`DigitizeCLI` gained an `ALLOW_BRANCHING_SATIN=1` diagnostic toggle
alongside its existing `ONLY_OBJECT`/`DEBUG_SATIN` ones.

## Professional samples -- five hand-digitized references (September 2026)

Five designs digitized by professionals (Wilcom, "Karen's Digitizing" and
two production shops) arrived as original artwork plus the finished
DST/PES and production worksheets: a golfing alligator (76 x 74 mm, 13 861
st, 6 colours), a rooster weathervane (59 x 76 mm, 6 450 st), a tribal sea
turtle (71 x 63 mm, 9 384 st, one colour, all satin), a pink elephant with
a cocktail (98 x 64 mm, 5 992 st, 7 colours) and "SIESTA KEY" block
lettering (121 x 26 mm, 4 479 st). `DigitizeCLI --analyze <dst|pes>
<out.png>` reads a finished file, prints a structural profile (stitch
lengths, per-colour-run stitch count and *reversal share* -- a satin column
reverses direction on every stitch, a fill only at row ends -- and
stitches per mm2) and renders it with our renderer; `PROFILE=1` prints the
same profile for our own output, so the two sit side by side. What the
comparison found, in the order it mattered:

**Every DST, EXP, JEF and VP3 we had ever written was upside-down.** The
alligator's DST and PES decoded to mirror images of each other through our
readers; pyembroidery read both identically. DST/EXP/JEF store Y pointing
up and we wrote our Y-down coordinates unflipped; VP3 stores deltas Y-down
and we flipped them. Every format note had reasoned from "pyembroidery is
Y-up internally", which is false (its PEC code applies no flip and PEC is
Y-down), and the test oracles negated Y on the same premise, so the
cross-validation agreed with the mirrored writers. Fixed in all four
writers and readers, the oracles corrected, FORMATS.md rewritten, and
`ThirdPartySampleTests.dstAndPESDecodeTheSameDesignInTheSameOrientation`
added: the vendored `scene.dst`/`scene.pes` pair must decode to the same
occupancy grid, not its vertical mirror.

**Keyline networks are strokes, not silhouettes.** The alligator's dark
green is both its jacket and the 1 mm keyline round every other colour. The
importer's "strip a hole that another shape covers, sew the field solid
underneath" rule (right for text on a banner) turned that keyline into a
solid 76 mm silhouette sewn under the whole design: twice the stitches,
the outline's character gone, and the base fill's rows showing through
every seam between the colours on top -- the "stray lines" first blamed on
travel routing. The rule now applies only to shapes that are mostly solid
(`minimumSolidFractionForHoleRemoval`, 35 % of the outer area); a line
drawing keeps its holes. The 96-px Red Sox "B" changed the same way: its
navy keyline is now a satin ring with open counters instead of a solid
disc under the letter.

**Strokes and areas in one colour are separated.** The pro fills the
jacket and runs a satin outline over everything -- the outline is 46 % of
their stitches. `ShapeMerger.splitThickAndThin` does a morphological
opening on the shape at `StitchTypeClassifier.strokeSplitWidthMM` (3 mm):
what survives erosion and regrowth is area, what it removed is stroke,
with the stroke grown 0.4 mm back over the area so the satin lands on fill.
A thin piece counts as a stroke only by topology -- it encloses something,
or touches two or more areas, or none, or is very thin (under 40 % of the
threshold) and at least 6 mm long; a tapering tail tip or a serif touches
exactly one area and rejoins it. A shape nowhere much wider than the
threshold (a 2.5-4 mm halo) is one stroke, never split (it came out as
eleven fill patches alternating with ten satin pieces before that rule).
`StitchTypeClassifier.separateStrokesFromAreas` runs in all three
front-ends before the sibling-consensus passes, emits areas (fill, first)
then strokes, marks both `stitchTypeIsManualOverride` so those passes
leave them alone, and gives strokes `allowBranchingSatin` and a 1 mm
minimum satin width (the pro's keyline is ~1.2 mm). A stroke that can't be
satin is a bean stitch along its edges, never fill. A shape that is all
stroke (a letter, a keyline with nothing solid attached) is not split but
gets the branching allowance -- measured thinness is the gate for that
path now, not hole count. Enabling branching satin on an unsplit
area-plus-keyline object was tried first and is the cautionary picture:
satin fans across the 25 mm jacket.

**Branching satin hardened on real stroke networks.** A loop segment whose
radial ring rails fail (an irregular enclosed region, a tribal spiral)
falls back to the perpendicular skeleton rails every open segment uses;
adjacent crossings that scissor are repaired (swap sides, else drop, up to
15 % of a segment) instead of failing the shape; a skeleton stub under
2 mm that can't be railed is skipped; a shape with no junction is
accepted (one edge, perpendicular rails) so a long curved ribbon the
single-column rails can't fit still gets satin; and
`StrokeTopologyAnalyzer` keeps a skeleton walk that dead-ends without
reaching a node (a two-pixel staircase, a pixel another walk claimed) as
an edge with a synthetic endpoint -- dropping it silently lost the 40 mm
arm of the Oholi ribbon. The ring rule in `classify` now requires the
radial sweep to reach the whole outline (`ringRailsReachOutline`); a
ribbon with a loop at one end is not a ring, whatever its hole count. The
branching path's underlay follows its skeleton, travelling between edges
along the skeleton (BFS over the topology) rather than in a straight line
-- the single-column centre-run underlay drew a hook past each end of an
"H". `DigitizePipeline` sews a branching-classified satin with the
branching generator first: the single-column `generatePartial` does not
throw on such a shape, it succeeds on whatever its rails reach and drops
the rest.

**Blurry sources.** The turtle arrived as a 110-px phone screenshot; every
2-4 px negative space inside the shell was blend pixels with no clean
white, the grey outnumbered the dark colour (so the size guard on the ramp
test let it through), and a JPEG-pink corner pixel had been taken as *the*
background colour (so the colour-line test failed). Every hole was
stitched solid in white thread. The background is now the per-channel
median of all border pixels; a cluster on the background/foreground colour
line is a ramp whatever its size when nearly all its pixels sit within 2 px
of another label AND at least half within 2 px of the design colour it
blends from (the second test is what keeps a genuine thin pale line -- the
Oholi ribbon beside navy letters -- from being dissolved); and a ramp pixel
decisively nearer the background than any design colour (Delta-E ratio
under 0.6) resolves to background outright rather than by neighbour vote,
which alone fills an all-blend hole with the surrounding colour.

**Also:** a shape whose average width is past 1.5x `maxSatinWidthMM`
classifies fill outright (a 100 mm disc came back "satin" and only sewed
as fill because the generator converted every over-wide crossing).

**Where we stand against the five.** Alligator: same structure as the pro
(fill bodies, satin keyline on top), 12 300 st vs 13 861, keyline ~1.2 mm
vs their deliberately bold ~2 mm. Turtle: all satin like the pro, but the
source is too small for the shapes to be right; the pro had the vector.
Rooster: the photo's dark corners import as objects -- photo backgrounds
are a separate problem. Elephant: the screenshot of an *embroidered*
sample is a poor source (31 sub-2 mm fragments); not pursued. Siesta Key
has no original to run. The CLI renderer's white highlight line makes
0.32 mm fill rows look sparse at 12 px/mm; the stitch data is right, the
renderer exaggerates -- left as is, noted.

## Second sew-out -- the Oholi wordmark (September 2026)

The Oholi mark ("OHOLI" with the bird and its thread, `TestArtwork/Oholi
simple.png`) sewn at ~105 mm on a ten-needle Brother, PES, cotton over
tear-away. The letters read well; the customer's note was that the "H"'s
junctions carried too much thread, and the render at the same size showed
why -- plus four things the sample could not show. Each fix, with what it
was measured against:

- **Junction patch grain.** The patch's axis was the arm with the widest
  *sample*; every arm's width peaks at the junction itself (the distance
  transform sees the merged blob), so the 2 mm crossbar out-measured the
  3.8 mm upright and the patch was twelve 7 mm stitches laid *along* the
  upright. Now the axis is the through stroke -- the pair of arms leaving
  the node nearest to opposite directions (`junctionPatchAxis`), judged by
  each arm's median width when no such pair exists. Chords cross the
  upright like its own satin does.
- **Patch reach and sequence.** The patch reached the trimmed crossings'
  rail ends (a fan needed that); a chord patch is clamped sideways by the
  boundary, so the extra reach only stacked two or three chords on each
  arm's finished satin -- the heavy junctions on the sample. It now reaches
  one stitch past the farthest trimmed midpoint. It is sewn on the walk's
  *last* pass through the node (every arm already down, so it covers their
  ends and the hops between them), oriented to start where the needle is
  and end nearest the next piece, with no unconditional centre entry/exit
  (that was a 3-4 mm diagonal across every patch).
- **Dead-end arms are travel-and-cover.** An arm into a leaf with more to
  sew is run out along its centreline and satined back to the junction
  (`WalkLeg.outAndBack`); satin out and a bare 8-10 mm hop back down the
  finished arm had put a straight thread over every such arm.
- **The walk itself is searched.** Every edge as a start, both directions,
  each fork tried within a budget (`orderedLegs`); the order with the least
  hopping wins. The analyzer's first-listed edge had decided the order: the
  cut "O" sewed stub, 20 mm jump, arc, 20 mm jump back; the ribbon sewed
  past its loop to the far end and jumped 26 mm back for the loop.
- **Specks and hairlines are not sewn.** Two slivers at the bird's head
  (0.2 x 0.3 mm; 3.8 mm long by 0.2-0.8 mm wide) each became a triple-run
  knot, a lock and a trim. `StitchTypeClassifier.isSewableSize`: under
  1 mm across, under 0.6 mm2, or a closed outline under 0.45 mm mean width
  (2A/P) is skipped by the pipeline; the objects stay in the document and
  `QualityAnalyzer` reports how many were left out. At 100 mm the Sarasota
  and Oholi banners lose their sub-millimetre tagline text this way -- the
  old output was 89 and 170 unreadable triple-run letters.
- **Seams.** A single column's underlay is oriented (and, if closed,
  rotated) to meet its first crossing -- the letter "O" had a 13 mm seam
  across its counter from underlay closing at the top and radial crossings
  starting at the right; the cut "O" a 28 mm one. Between branching pieces
  a hop under 3 mm is sewn as a connector (`visibleConnectorMM`) whether or
  not it stays on the shape.
- **Determinism.** `StrokeTopologyAnalyzer` iterated a dictionary for a
  node cluster's pixels and for its node list; Swift seeds a dictionary's
  hasher per instance, so two analyses of one shape could find different
  edges. Sorted now; the flaky `realCapLogoBUnderlayNeverRunsAcrossItsCounters`
  was this.

Oholi simple at 105 mm: 23 trims to 14; corpus at 100 mm: cap-logo B 27
to 14, Sigma Chi 164 to 30, Sarasota 56 to 30, no readiness score lower.

## Third sew-out -- the LIBBi wordmark (September 2026)

"LIBBi" at ~95 mm on the Brother, PES, cotton over tear-away; the
customer saw holes in the fill and ragged letter edges. The engine had
sewn every letter as tatami: the "B"s (6 mm strokes, two counters) were
fill because the branching-satin path rejected them ("rails twist"),
and the same-colour consistency pass then pulled the L, I and i -- which
had classified as satin -- down to fill with them. The professionally
digitized "SIESTA KEY" reference (26 mm block letters, ~6 mm strokes) is
satin on every letter; so, now, is LIBBi.

- **Lettering is a stroke network.** `StitchTypeClassifier.
  separateStrokesFromAreas` offers the branching-satin path to any
  fill-classified shape nowhere wider than `letterStrokeMaxWidthMM`
  (7.5 mm; `ShapeMerger.isNowhereWiderThan`, an erosion test) -- whole,
  counters and all. The 3 mm keyline split stays for shapes that are
  part area, part line.
- **Paired rails stay paired.** A branch segment's rails come one A and
  one B per skeleton sample; `fineRails` was re-matching them
  proportionally by each rail's own arc length, so where the inner rail
  stalled on a counter's corner while the outer swept round the outside,
  the stall soaked up samples and the pairing slid: crossings ran 15 mm
  from the stem's outer edge across the counter. Paired rails are now
  resampled at the same index fraction (`pairedResample`), and their
  corners come from `SatinCorners.findPairedCorners` -- the outside
  vertex is a sharp turn on either rail, the inside vertex is the other
  rail's point at the same index -- with the pieces between corners cut
  at the same index on both rails (`pairedWithCorners`). `findCorners`'
  search had paired the "B"'s top-left corner with a stall 15 mm away and
  run the mitre legs the length of the top bar.
- **Junction grain from the nearest outer edge.** The patch's chords now
  point at the shape's nearest outer boundary point (grain perpendicular
  to that line) when it is within a node width; arm tangents decide only
  deeper inside a blob. The "B"'s two bowls leave their shared waist node
  ~120 degrees apart, curving, and every tangent rule chose a diagonal --
  a dozen 9 mm diagonals across the letter's right side. Pointing the
  chords into the notch between the bowls reads as the waist bar meeting
  the right side, which is what the letter is.
- **Merge-zone trim.** Arm crossings wider than 1.35x the arm's median
  width within three trim radii of a node are trimmed into the patch too
  (`junctionMergeWidthFactor`); the through-stroke opposition test relaxed
  to 60 degrees off straight.
- The cap-logo "B" test now tolerates connectors under
  `visibleConnectorMM` clipping a concave notch, matching the engine's
  own rule.

LIBBi at 95 mm: six letters, all satin, 2 106 stitches, 8 trims (was
1 871 stitches of fill with the ragged edges the sample shows). Corpus
at 100 mm unchanged in readiness; Amerus's navy leg (nowhere wider than
7.5 mm) is one satin network instead of two fill patches and an
outline.

## Twenty studio samples -- Ignition Drawing (September 2026)

`TestArtwork/Professional Files/` gained twenty samples from Ignition
Drawing's public sew-out gallery: each is a 428 x 312 crop of the
customer artwork and a crop of the studio's sewn result, cut from the
studio's own side-by-side image (`SOURCE.txt` in each folder). No stitch
files, so the comparison is visual. Two things about the crops matter
for reading the results: **every artwork is partial** -- a diagonal
corner is covered by the other panel, and several are cut off at an
edge ("ANSCEND THE GA", "INDBERGH XC", "eft Coast Thoroughbre") -- and
the artwork is small and JPEG-blurred, which is exactly what customers
send. The diagonal cut shows up in our output as a white triangle; it is
the sample, not the engine. Renders at 80 mm wide, `scratchpad/pro/run.py`
builds the artwork / studio / PiperStitch sheets.

What the batch found, by how many samples it touched:

- **Background from four corners -> Otsu (7 of 20).** The importer took
  the page colour only when all four corners agreed; with one corner
  cut to white it fell back to an Otsu light/dark split and kept the
  minority class. On the grey-card eagle that kept white and yellow and
  lost both blues; on the red-card lion it lost the black and the blue;
  Quileute, Racecar, Steel Dog, Tiger, Eagle Sewout likewise. Now the
  border's MAJORITY colour (60%) is the background, and when there is no
  majority (a banner with a dark bar top and bottom) the image's
  DOMINANT colour is, when it covers 30% of the picture and 20% of the
  border. Otsu remains only for pictures with no dominant colour.
  `ImageImportTests.backgroundIsTheBorderMajorityNotAllFourCorners`,
  `...DominantColourWhenTheBorderHasNoMajority`.
- **White thread invisible in the preview (6 of 20).** A design meant for
  a navy or red garment previews on paper-coloured canvas: the Lindbergh
  eagle was a white blank. The importer now reports the artwork's ground
  (`ImageImportResult.backgroundColor`), the server passes it through
  (`ImportResponse.backgroundColor`, only when `StitchRenderer.
  isPreviewGround` -- anything but near-white), the editor draws the
  fabric that colour and the CLI renders on it.
- **A blob with a hole is not a ring (Eagle Graphic).** The ring-satin
  test measured width as area over perimeter; a feathered outline
  inflates the perimeter, so a 66 x 40 mm head with the eye cut out was
  "9.7 mm wide" and sewn as a satin outline round nothing. Ring satin
  now also requires the shape to be nowhere wider than a column
  (`ShapeMerger.isNowhereWiderThan`), as does multi-hole branching satin.
- **Hairlines sewn as running stitch (Tree, Horse, Sigma).** A closed
  outline too narrow to sew (`isSewableSize`) but 4 mm or longer is now
  sewn as a running stitch along its skeleton
  (`StitchTypeClassifier.hairlineCenterlines`), lines that nearly touch
  joined into one run; it was dropped, and before that sewn as a double
  row round each line. The studio sews fine-line drawings exactly so.
- **Small text (15 of 20).** Every sample with a tagline under ~3 mm --
  "YEARS OF EXCELLENCE", "ALUMINUM", "The Toughest Pit in The Yard",
  "Left Coast Thoroughbred" -- either drops it (correctly: 0.4 mm strokes)
  or, worse, sews readable fragments of it. The studio re-types every one
  as satin lettering at a size that works. The app has text detection
  and font lettering for the user to do the same; doing it automatically
  is the next big item, not this batch's.
- **The background card (Tiger, Steel Dog, Excavation, Arch).** The
  studio treats a coloured background as a card and sews the design's
  own colours -- including white -- on the garment; the engine treats it
  as the fabric, so a white tiger on red sews nothing where the artwork
  is white. Both are defensible; ours follows the file. Worth a setting
  ("this background is the garment / is part of the design") rather than
  a rule.
- Out of scope, noted: Moose is a painting and Quileute is a photograph
  of a finished embroidery -- neither is artwork a digitizer starts from;
  Racecar is airbrushed illustration. They now at least produce
  something (they produced almost nothing before the background fix),
  but nothing in them is a target.

Regression corpus: unchanged except two or three trims where hairlines
are now sewn (Sigma Chi 30 -> 32, Sarasota unchanged). 407 tests.

## Small text: found by geometry, left out whole, re-typed with the user (September 2026)

The studio samples' one pervasive gap was text under about 3 mm: traced,
it either vanished or sewed as readable fragments of half-letters, and
the studio re-sets every such line as lettering at a size that works.
Three layers now do the same.

**Finding it without OCR.** `TextLineFinder` (Engine/) works on the
imported shapes alone: letter-sized shapes of one colour, alike in height
(spread <= 0.35), close together (gap <= 2.2 letter heights, so a
letter-spaced title still chains), three or more in a row much longer
than tall. Each line carries its box, cap height (the 75th-percentile
letter height), baseline angle (principal axis of the letter centres),
ink fraction (bold from 0.42), whether the centres sit on an arc
(residual > 0.18 x cap height) and a Kåsa circle fit's radius when they
do. No Vision, so the Linux server has it; the Mac app's Vision-based
`TextDetector` is untouched. False positives happen on tall lines (a
shield's stripes chain up too) and cost nothing: a line that sews as
traced is kept unless the user says otherwise.

**Leaving it out whole.** `DocumentBuilder.build` (server) and the CLI
drop every line whose cap height at the chosen size is under
`TextLineFinder.minimumCapHeightMM` (4 mm for 40-weight, 3 mm for 60 and
80, 5 mm for 30) and record the count on `StitchDocument.
omittedTextLines`; `QualityAnalyzer` says so and points at the Text step.
Fragments were the worst outcome in the batch; a clean omission with a
reason is strictly better. Sarasota at 100 mm: 117 objects and 38 trims
became 49 and 12, readiness 74 to 84.

**Re-typing it.** The web setup gains a Text step (after size, only when
lines were found): each line as a crop of the artwork, its height at the
current size against the minimum, and three choices -- re-type as
lettering, leave it out, keep as traced (disabled when too small) -- plus
"make the design N mm wide and every line sews as traced". Re-typed
lines are set from the browser's own font outlines (`lettering.ts`) at
the greater of the original cap height and the minimum, in the artwork's
colour (snapped to the thread library when the rest was), centred where
the original sat, turned to its baseline angle (`/edit/lettering` gained
`rotationDegrees`) and, for a curved line, on its fitted arc. When the
typed word matches the letters found, the run is fitted to the
original's width by letter spacing, then by condensing up to 25%; when
more was typed than was found (a fragment of a blurry tagline), natural
width, centred -- the move tool finishes it. Decisions travel in
`SetupAnswers.textDecisions`; the build request's `dropShapeIndices` and
`omittedTextLines` carry them to the server, and a client that passes
them (even empty) has decided every line, so the server's own rule
stands down.

**Reading it.** Tesseract.js, in the browser (`ocr.ts`), pre-fills the
field for any line that cannot sew as traced or that the user chose to
re-type -- a padded crop, grey on white (inverted when the text is
lighter than its ground), upscaled to ~60 px letters, straightened by
the line's angle, single-line page mode, accepted at confidence 55 or
more. The library and its English data come from a CDN on first use and
nothing leaves the browser. It read "GOLDEN" from a 6 mm line of a
428-pixel JPEG and nothing useful from the 3 mm "NUM" fragment below it,
which is the expected shape of things and why it only ever pre-fills.

**Choosing the face.** The finder cannot name the original font (the
artwork is a raster; the letters are blobs), so it records what it can
measure and the picker shows the rest. Each line now carries
`mixedCase` (at least 30 % of its letters shorter than 85 % of the cap
height, but not all of them: descender-free lower case and small caps
both count as mixed) and `letterAspect` (median width/height of the
letters). `lettering.ts` tags every face with its width class
(condensed / normal / wide), whether it is capitals only, and whether its
thin strokes need a minimum cap height (5 mm) to hold; `suggestFont`
maps a line onto them -- capitals and narrow -> Anton (bold) or Bebas
Neue; narrow and mixed -> Oswald; capitals, bold and wide -> Montserrat;
otherwise Roboto or Open Sans by ink fraction. The Text step's picker is
a tiled sheet under three headings (sans-serif, serif, script), each
tile the user's own words in that face with the suggestion first and
thin-stroke faces dimmed and labelled at sizes where they will not hold;
above it, the crop of the original beside the chosen face set at the
same on-screen letter height and condensed by the same ratio the run
will be. "Show where this is in the artwork" drops the whole image in
with the line outlined, so a script tagline and a block wordmark on the
same jacket are decided in context; "Use this font for every line"
carries one choice across a multi-line design. The fonts load through
`ensureFontFaces` (the same files the outlines are cut from), so what
the tile shows is what sews.

**First two logos after release (LIBBi, Sigma Chi) -- neither found its
text.** LIBBi was uploaded as an SVG: the `/import/svg` route never ran
the finder, and the build's own drop rule was gated on a pixel height an
SVG does not have. The finder is unitless apart from its size limits, so
for vector input (`imageHeightPixels: 0`) the drawing's own height stands
in and lines come back in SVG units; the web app rasterises an SVG on
import (`rasterizeSVG`, at a known units-to-pixels factor) so the Text
step has a picture to crop and OCR, and the editor gains "show original"
for vectors as a side effect. Sigma Chi failed differently: "Sigma Chi"
sits right over "FOUNDATION", the stacked-neighbour allowance (meant for
ring text down the side of a badge) chained them, the 'i' stems at 127 px
cleared the 0.45 height ratio against 59 px capitals, and the fused group
failed the height-spread check -- both lines lost. Stacked neighbours now
have to be alike in height (>= 0.7), and a group that still fails is
split at the widest height ratio (>= 1.35) or at a clear gap in the
residuals with a flat row on each side, then each part tried on its own;
"curved" needs the circle to fit the centres at less than half the line's
residual, not just the line to fit badly (a g's descender and a taller C
made "Sigma Chi" an arc). A straight line also needs most of its letters
on one baseline (`minimumBaselineAlignment` 0.45; real lines score 0.67-
1.0, a wing's feathers 0.2) -- the radial version of that test could not
tell feathers from ring text, so it is not applied to curves; instead a
short curved run (under 8 letters) is never dropped by the engine on its
own (`dropsWhenTooSmall`) and the Text step defaults it to "keep", where
the user, who can see the crop, decides. "Keep anyway" is now offered on
a too-small line for exactly that case. OCR's habitual l-for-I slip is
corrected on capital lines, and the read is retried if React re-runs the
effect before it lands (the development double-mount had been discarding
the result). Still not found: the crest's "IN HOC SIGNO VINCES", whose
letters fuse into the ribbon outline at import -- the knocked-out /
merged text case noted before.

**Sigma Chi at a polo chest (89 mm): the re-typed line came out hollow,
and three traced defects around it.** "FOUNDATION", re-typed at the Text
step's 4 mm minimum, sewed as a running-stitch outline: the lettering
classifier's own satin floor was 5 mm (`minimumSatinCapHeightMM`), a
millimetre above the Text step's rule, so every line set "at the
minimum" was outlined -- LIBBi's tagline too, unnoticed at that zoom.
One rule now, `TextLineFinder.minimumCapHeightMM` by the document's
thread weight. Then the run came back as tatami fill: `classifyLetteringRun`
dropped a whole run to fill when any glyph (F, T, N, A) was not a single
column, never offering the branching path traced letters get; the
lettering route now allows branching satin and the run is satin along
its strokes. Around it: the 12 x 15 mm shield averaged 9.6 mm, passed the
single-column fit, and sewed 15 mm crossings with the generator's local
fill patch as a lattice down its middle -- a hole-free shape averaging
wider than a letter stroke and less than three times longer than wide
is an area (`isWideShortBlob`), filled, left out of the same-colour
sibling vote (its satin banner is not the letters of its word) and out
of the analyzer's mixed-texture warning; the 8-12 mm band stays satin
for a real column. The i's dots (1.9 mm, under the 1.5 mm satin floor by
mean width) were running-stitch diamonds; a compact dot is a short satin
bar. Longest stitch 11.5 to 6.4 mm, readiness 91 to 96 at 100 mm. Still
open: the serif "Sigma Chi" itself sews as branching satin with rough
bowls and terminals (the a, the g, the S's ends) -- the generator on a
contrast face, which wants its own session.

## Branching satin on a contrast serif face (September 2026)

The generator was built and tuned on block letters -- uniform strokes at
clean junctions (LIBBi, Siesta Key, the Oholi H) -- and a serif face
broke three of its assumptions. Judged on renders of the Sigma Chi
letters at 89 mm (the a, g and m, at 40 px/mm) and on typed Georgia
Bold and Times Bold at 12 and 8 mm, with the sew-out-tuned designs held
to their previous output:

- **Hairlines.** Any sample under 0.5 mm wide was treated as a tapering
  tip and both rails collapsed to the centreline, so a serif m's arches
  and a bowl's thin top sewed as a bare travel line. That collapse now
  applies only within 1 mm of a segment's end (`tipZoneLengthMM`); in
  the middle a hairline is sewn at the minimum satin width, centred on
  the stroke, which is what every digitizer does with a line the thread
  cannot follow. The Oholi thread line, 0.5-1 mm in the artwork, is now
  a narrow satin along its whole length rather than satin in patches.
- **Bowls.** A one-hole letter was a plain ring -- one radial sweep from
  the counter's centre -- so an a's stem and hook took crossings aimed
  at the hole (a fan of diagonals). `ringHasArms`: when the skeleton has
  a loop AND an arm at least 1.5x its width, the letter takes the
  branching path (bowl as a ring segment, arms along their own
  centrelines; the P's proven path). An O, a D, a bar with a slot stay
  rings. A ring segment's rays are now bounded by the loop's local width
  (as open segments' already were), so a ray leaving the bowl through
  the stem stops at the bowl's own edge; only on a real counter (loop
  >= 6 mm) -- the Oholi bird's body is covered by the sweep from a
  pinhole in its raster, and bounding that lost half its stitches.
- **Serifs and junctions.** A serif's wing (a spur under 1.4x the
  junction's width, tapering to under 0.3 of it, and under 0.4 of the
  junction's other arms) is pruned into the stem's end, whose rails then
  flare into it -- how a serif is sewn -- instead of earning a junction
  and a radial patch (the bow-ties at every foot of the m). A node is
  patched only when two of its arms are substantial (lower-quartile
  width over the first few node-widths, >= 0.6 of the node's): an arch
  running into a stem is not a crease. Two junctions closer than 1.5x
  their width are one junction (an a's bowl met its stem twice, 2 mm
  apart on a 1.6 mm stem). A short spur is pruned only when it tapers
  (under 0.5 of the junction's width at its end) or ends on a demoted
  junction -- a 5 mm A's apex, 2 mm long and 1.6 mm wide at the top, was
  being pruned as thinning noise; under 0.65 of the threshold it goes
  regardless (a T's bumps).
- **Small letters with a counter too small to sew.** `classify` judges a
  one-hole shape whose hole `droppingUnsewable` will drop as the
  hole-less shape the generator gets (the 5 mm A took the branching
  path on a skeleton that no longer had its loop, and covered a third of
  itself). Only that case: judging every shape by its sewable sub-paths
  re-routed the anti-alias halos of a transparent PNG and cost LIBBi
  three points.
- **Typed lettering** gets the same branching path (`classifyLetteringRun`
  with `allowBranchingSatin`; the server route and the CLI preview set
  it), so a re-typed serif face is satin along its strokes rather than
  fill.

Results: the Sigma Chi m, a, S, C, h, i clean; g's link and the Times a's
hook/stem/bowl blob still knot at the junction (a patch on a blob where a
thick hook end merges into a bowl -- the one junction type still
imperfect). Corpus: no readiness regression; longest stitches equal or
shorter; stitch counts up 2-8 % where hairlines became satin. Diagnostics:
`DEBUG_TOPOLOGY=1` traces every pruning step, `DEBUG_CLASSIFY=1` the ring
decision and per-object stroke-width percentiles, `PIXELS_PER_MM` sets the
lettering preview's render scale.

**Follow-up the same day -- the re-typed 4 mm "FOUNDATION" was a smear.**
The hairline rule widened every stroke under `minSatinWidthMM` (1.0 mm on
the lettering route) to 1.0 mm; Roboto Bold at 4 mm has 0.65 mm strokes,
so every letter grew by half and the counters closed. The widening
target is now the thread's own minimum, `ThreadWeight.hairlineSatinWidthMM`
(0.6 mm for 40-weight, about a thread and a half; 0.8 already visibly
closes an O at 4 mm), and `minSatinWidthMM` stays what it was: whether a
stroke may be satin at all. And no junction patch on a node narrower
than 1.5 mm (`minimumPatchNodeWidthMM`): at 0.65 mm strokes the corner a
patch covers is smaller than a stitch, and the patch's trim and merge
reach had eaten the whole F, N and A. "FOUNDATION" and "YOUR AI
ORCHESTRATOR" read at 4 mm now; the F, N, A and S are still rough at
that size. Every face in the web lettering list is a bold cut (chosen
for sewing at larger sizes); at the 4 mm minimum a regular cut would keep
the counters open -- a font-asset follow-up, not an engine one.

## Keyboard fonts: glyphs digitized once, sewn from stored columns (September 2026)

Re-typed text used to go through the same path as a traced raster
letter -- rasterise the glyph, thin it, rebuild strokes from the skeleton,
guess the junctions, cast rails -- throwing away that it was a known
letter from a known font. Commercial software does not digitize text on
the fly: a keyboard font is a library of glyphs whose satin columns were
defined once and reviewed, and sew time only scales them. Same here now.

**The library.** `web/scripts/export-glyph-outlines.mjs` writes each of
the twelve lettering faces' glyphs (168 characters: ASCII plus the common
accented and typographic ones) as flattened polygons in cap-height
units, from the very @fontsource files the browser draws, through
opentype.js as the browser does. `DigitizeCLI --build-glyph-library`
runs each glyph through the generator at 22 mm cap height (where it is
reliable) with `SatinColumnGenerator.columnPlan`: the columns the
generator would sew, in sew order, as *paired chords* -- the pairing is
kept rather than re-derived from two rails, since on a diagonal or round
a corner the generator's own pairing is the whole point -- with pull
compensation taken back off. A glyph with a junction in its skeleton (A,
K, R, 4) takes the branching path even when the single-column fit would
succeed on it (that fit lays one zigzag across the whole letter); one
without (S, C, N's Z-shaped path) is a single column; a ring stays a
ring. A glyph's contours are split into pieces first (an i is a stem and
a dot, a % three pieces, a B one piece with two holes), stray contours
under half a square millimetre and stub columns with no width are
dropped, and the pairs are thinned to a 0.03 mm tolerance.
`--emit-glyph-data` embeds the twelve libraries as Swift source
(`GlyphColumnData.generated.swift`, ~2 MB; no resource bundle to ship),
`--glyph-sheet` renders a font at any size for review (with
`GLYPH_OUTLINES` for the real shapes -- with a bounding box standing in,
hops across a counter read as covered). Two glyphs in 2 016 could not be
columned (Pacifico's %, Dancing Script's 7); the generic path covers
them.

**Sewing.** `SatinColumn` (two rails, `travelOut` for a dead-end arm
sewn out and back) lives on `EmbroideryObject.satinColumns`; when
present and the object is satin, `DigitizePipeline` sews exactly those --
`SatinColumnGenerator.sewColumns`: the chords re-spaced along the
column's midline at the document's density, pull compensation for that
width, a hairline held at the thread's minimum, a centre-run underlay
along each midline, pieces joined into runs where the hop is short or
stays on the shape -- and never derives rails from the shape. The
browser (`generateLetteringRun`) sends the font id and each glyph's
baseline origin with the outlines; `/edit/lettering` places the library
columns in the same frame (scale to cap height, the run's arc, the Text
step's condensing, then the rotation and centring the outlines get) and
the outlines serve for bounds, selection and sequencing. A font or glyph
the library lacks falls back to the generic path, glyph by glyph.

Judged on the review sheets at 4, 10 and 12 mm across serif, sans and
script faces: every letter reads, the same way at every size. "FOUNDATION"
at 4 mm on the Sigma Chi banner is ten satin letters. Still to do, per
font, on the sheet: the few glyphs whose generated columns a digitizer
would redraw (Roboto's r and y, the joins in the script faces) -- the
sheet is what that review is for, and a hand-fixed glyph is a JSON edit.

**Review pass and the lighter cuts (the same evening).** Every face's
full set rendered at 10 mm and read glyph by glyph. Three engine rules
came out of it, all in the topology's pruning: a spur that ends at least
2.5 mm wide is a stroke, never thinning noise (Alfa Slab's E, F, L and T
had lost every serif and arm to a stem-width junction and sewed as
bars); two junctions merge only when they are joined more than once
(the stub-and-bowl of an "a"), since a lone short edge between two
junctions is a real stroke (a slab H's crossbar is shorter than its
stems are wide, and merging made the H an I); and a demoted junction's
stub is no longer pruned for being demoted (that cascaded through the
H). Ring eligibility ignores parallel edges between the same two
junctions -- the two halves of the ring round a counter. Twists in one
arm no longer refuse a whole glyph when building a library (the twisted
crossings are dropped; live digitizing keeps the strict refusal). All
2 352 glyphs across 14 faces are columned; the demotion test's fixture
is now a stem with two tapering points rather than a slab-serif T.

Roboto Medium and Open Sans Semibold join the list for small text: at
the Text step's 4 mm minimum a bold cut's 0.65 mm strokes and 0.8 mm
counters close under the thread. `suggestFont` takes the sewn cap
height and, at or under 5.5 mm (`SMALL_TEXT_CAP_MM`), suggests a lighter
sans whatever the original looked like -- Roboto Medium for a bold
line, Open Sans Semibold for a regular one -- since at that size
legibility beats matching the artwork's style; the tiles say "keeps
small text open". Two sew-time rules for fine columns: pull compensation on a
column under 3 mm is capped at 30 % of its width (0.30 mm on a 0.5 mm
stroke was a 60 % gain, and every small letter sewed fat), and a stored
column ignores `minSatinWidthMM` -- it is satin by definition, only a
chord under the thread's own minimum is a run (the light cut's 0.9 mm
chords were sewing as a line down the middle).

## Sequencing — containment tolerance (the cap "B" vanished at 101.6 mm)

The same cap-logo "B" that drove the seven fixes above came out fine from
DigitizeCLI at 100 mm and looked *empty* in the web app at Left Chest
(101.6 mm): the white halo sewed **after** the red letter and buried it.
`ObjectSequencer.isBackground` decides "A contains B, so A sews first" by
testing every outline point of B with `pointInPolygon` against A's outer
boundary. At 101.6 mm two of the letter's ~1 000 points landed ~0.01 mm
outside the halo (the halo's outline is a traced raster edge; the letter's
outline is the same edge, offset by an importer smoothing pass -- they
touch, and float rounding decides which side of the line each vertex sits
on). Two points outside -> "not contained" -> no ordering edge -> the
sequencer's nearest-neighbour path was free to sew the halo last.

Fix: containment now tolerates a boundary band, `max(0.2 mm, min(1.5 mm,
1 % of the candidate's larger dimension))`. A point counts as inside if it
is inside *or* within that distance of the container's boundary
(`distance(from:toBoundaryOf:)`, nearest point on each edge); the bounding
box precheck is relaxed by the same amount. Genuinely separate objects are
unaffected -- a point has to be within a fraction of a millimetre of the
edge to be forgiven, and only after the bbox test already put the two
objects on top of each other. Test:
`aContainedObjectTouchingTheContainerEdgeStillSewsAfterIt`.

Noted, not fixed: the halo has no B-shaped hole (one sub-path) in both the
old and the new importer, so the letter sews *on top of* solid white rather
than into a cut-out. Sewing order is the visible problem; stitching a
letter over a halo is normal practice.

## Hoop catalog — Mighty Hoop and Durkee EZ Frame

`HoopProfile.commonHoops` now carries the Mighty Hoop line (magnet-clamped;
sizes use HoopMaster's published *sewing field*, roughly an inch under the
nominal size, since a 5.5" Mighty Hoop does not sew 5.5") and Durkee's EZ
Frame line (rigid frames named by their sewing field, so the listed size is
the field, converted straight to mm). Index 2 (6" × 10") is still the Mac
app's fixed default. `recommended(forDesignWidthMM:heightMM:)` prefers the
smallest fitting *generic* hoop over any branded one (`isBrandSpecific`) --
a user who hasn't said they own a Mighty Hoop shouldn't be handed one. The
web app groups the picker (Standard / Mighty Hoop / Durkee), shows only the
standard group in the setup flow behind a "More hoops & frames" toggle,
and lets the hoop be changed from the editor toolbar and inspector after
digitizing -- the fit check and hoop outline follow the change.

## Phase 2 — planned next

- Multi-region object segmentation refinements (holes within a raster
  color region, anti-aliased edge handling)
- Manufacturer thread catalogs, pending license research (spec §9)

## Phase 3 — Underlay (implemented)

`UnderlayGenerator.swift` generates a lighter stabilizing layer sewn
*before* an object's main stitches (spec §16). Automatic by default —
"users should generally not need to configure underlay manually" — but
`parameters.underlayType` overrides the automatic choice per object for
professional use:

- **Satin -> center run**: a running stitch along the column's centerline,
  derived from the *same two rails* `SatinColumnGenerator` sews between
  (`SatinColumnGenerator.computeRails` is exposed module-internally so this
  can't drift into computing "centerline" a second, different way), inset
  from the true ends so it doesn't poke out past the satin's own tapered
  tips.
- **Tatami fill -> edge run**: a running stitch around the shape boundary,
  inset inward so it falls entirely beneath the fill that follows. The
  inset uses a naive per-vertex polygon erosion (move each vertex inward
  along the average of its two adjacent edges' inward normals) — an
  approximation that doesn't handle self-intersection on sharp concave
  corners the way a true straight-skeleton offset would, adequate for the
  modest ~1mm insets underlay uses on typical logo/lettering shapes.
- **Running/triple-run -> none**: already a single light pass with nothing
  to stabilize underneath.

Wired into `DigitizePipeline`: underlay stitches are generated first and
prepended to the object's main stitches, so they physically sew before the
satin/fill that follows, matching how underlay actually functions on a
machine.

## Phase 3 — Pull compensation (implemented)

`PullCompensationCalculator.swift` estimates how much to expand satin/fill
geometry outward before generating stitches, to counteract fabric pulling
inward as it's sewn (spec §17). This is explicitly a first-pass *heuristic*,
not a calibrated physical model — real pull depends on fabric weight,
hooping tension, and thread type, none of which StitchPilot has data for
yet (fabric profiles are Phase 5; spec §68's manual sew-out calibration
system is the intended eventual replacement for this heuristic with numbers
measured from real sew-outs). The formula only captures the two effects
true regardless of fabric: denser stitching pulls more, and the same
absolute pull distorts a narrow object proportionally more than a wide one.

Applied differently per generator, both automatically unless
`parameters.pullCompensationMM` overrides it:

- **Satin**: after resampling both rails to matched points, each pair is
  pushed apart symmetrically about its own midpoint by half the
  compensation — this widens the column without moving its centerline, so
  underlay (generated from the same, unmodified rails) stays exactly where
  it was digitized.
- **Tatami fill**: the outer boundary is offset outward (via
  `PolygonGeometry.offsetPolygon` with a negative distance — the same
  function underlay's edge-run inset uses with a positive one) before
  scanning. Holes are left as digitized for now; shrinking them to
  compensate too (so a compensated outer boundary doesn't make a hole
  effectively larger) is a follow-up.
- Skipped entirely when a shape's own extent is too small relative to the
  compensation amount — expanding a near-degenerate sliver would fabricate
  a region that wasn't really there rather than adjusting one that was
  (caught by `TatamiFillGeneratorTests.emptyShapeProducesNoStitches` during
  development, once pull compensation started applying to a shape that was
  never large enough to produce fill stitches in the first place).

Not yet exposed as an editable value in the app UI (spec §17's "expose the
calculated compensation to users" — Phase 5's professional object editor is
the natural home for this alongside the other per-object overrides).

## Phase 3 — General stitch filtering (implemented)

`StitchFilter.swift` is a post-processing pass applied to *every* object's
generated points regardless of which generator produced them (spec §30):
merges consecutive points closer than `minStitchLengthMM` (snapping onto,
rather than duplicating near, the true final point), and splits any gap
longer than `maxStitchLengthMM` into evenly-spaced intermediate stitches.

Applying this centrally rather than per-generator caught something the
per-generator version (previously duplicated inside `RunningStitchGenerator`
only) couldn't: a triple-run's forward/backward/forward reversal leaves an
exact-duplicate point at each turnaround (distance 0, an actual zero-length
stitch), which the shared min-length merge now removes for free. It also
covers a gap the individual generators structurally can't see — the
transition between an underlay's last point and the main stitching's first
point isn't guaranteed to be short, and only a pass that runs *after*
concatenating underlay + main stitches can catch it.

The max-length split is a quality concern distinct from a machine format's
hard per-record coordinate-range limit (e.g. DST's ±12.1mm, handled
separately at export time in `DSTFormat`) — it exists so an overly long
stitch never reaches export looking like a plausible design choice instead
of a defect.

**Fixed later — the exactly-two-point gap.** `mergeTinyStitches`'s own
guard required *more* than 2 points before doing anything, which silently
skipped the minimum-length check entirely for the smallest possible run:
exactly two points, however close together. A genuinely tiny or
near-degenerate object (a near-zero-width satin crossing at a small
fragment's tapered tip, say — common on any curved or detail-heavy import)
can produce a run exactly this small, and it sailed straight past the
filter into the exported file. Found via `QualityAnalyzer`'s own
under-0.15mm-stitch check against the real PiperStitch bird mark, whose
readiness score went from 66 to 81/100 once this closed — that check's own
doc comment already correctly described this as "a real defect, not a
style choice," and now the filter it depends on actually can't miss it.
Two points closer than `minStitchLengthMM` collapse to the single true
endpoint, same as a longer run's own trailing too-close points already do.

## Phase 3 — Tie-in/tie-off (implemented)

`TieStitchGenerator.swift` anchors a thread end without a visible knot
(spec §27) with a short "there and back": step `0.5mm` in the direction the
real stitching is about to go (tie-in) or just came from (tie-off), then
return to the anchor point. Under tension this locks the thread the way a
hand-sewer's back-stitch does.

Applied in `DigitizePipeline.flatten` at thread-*engagement* boundaries, not
per object: a tie-in goes on the first object of a new color run (the very
first object in the design, or the first one after a color change), and a
tie-off on the last object of a run (right before the trim that follows,
or the design's final trim). Same-color objects sewn back to back share one
continuous thread and don't need re-anchoring between them — run detection
looks ahead/behind by thread color across the *filtered* (non-empty-output)
object list, so an object that happened to produce zero stitches can't
shift a lock stitch onto the wrong neighbor.

## Phase 3 — Long-jump trim insertion (implemented)

A same-color jump longer than `maxJumpWithoutTrimMM` (default 15mm, an
overridable parameter on `DigitizePipeline.flatten`) gets a trim inserted
before it, even though the color hasn't changed (spec §26). Without this,
two same-color objects far apart on a design would carry a visible strand
of thread across the gap between them (spec §25: "Never place obvious
travel stitches across exposed design areas"). This doesn't shorten the
physical travel — the machine still moves there either way —
`QualityAnalyzer`'s long-jump check fires independently of whether a trim
was inserted, since a long jump costs production time regardless.

## Phase 3 — Reference-informed algorithm improvements (implemented)

A round of improvements informed by studying Ink/Stitch and pyembroidery's
source directly (see `EMBROIDERY_ALGORITHM_REFERENCE.md` for the full study
notes, license handling, and per-technique attribution — summarized here):

- **Satin auto-fallback to fill** (`DigitizePipeline`): a column that would
  exceed `maxSatinWidthMM` no longer aborts the whole object with an
  error — it's regenerated as tatami fill instead (with fill-appropriate
  underlay), matching spec §12's "automatically divide or convert
  excessively wide satin regions." Originally this was a *whole-object*
  fallback; see "width-aware satin splitting" below for the per-section
  version that superseded it.
- **Zigzag underlay for satin** (`UnderlayGenerator`): columns averaging
  wider than `zigzagUnderlayWidthThresholdMM` (default 4mm) get a
  wider-spaced, inset zigzag underlay instead of plain center-run — the
  "German underlay" technique (contour-walk + zigzag together), sourced
  from Ink/Stitch's three-underlay-type satin model (`center_walk`,
  `contour`, `zigzag`), which StitchPilot previously only had the
  center-walk equivalent of.
- **Automatic fill-angle selection** (`FillAngleSelector`): tatami fill
  defaults to running rows perpendicular to a shape's principal
  (elongation) axis instead of always 0°, when `fillAngleDegrees` isn't
  set explicitly. Documented clearly in both the selector's own doc
  comment and the reference document as *original* work — Ink/Stitch's
  fill angle is a plain user-set parameter with no automatic selection
  logic to have borrowed from.
- **Containment-based object sequencing** (`ObjectSequencer`): if one
  object's bounding box fully contains another's but the smaller one
  currently sews first, they're swapped so the larger (background) object
  goes first (spec §23 "background before foreground... inside before
  outside"). Deliberately conservative — objects with no containment
  relationship are never reordered relative to each other, so it can't
  scatter same-color runs `DigitizePipeline`'s color-change consolidation
  depends on being adjacent. A full graph-based jump-minimizing sequencer
  (the technique Ink/Stitch's `auto_satin.py` actually uses) is the
  natural next step and is recorded as the top item in the reference
  document's "recommended next improvements."

Also: testing these changes against two real-world files from
EmbroidePy/samples (`ThirdPartySampleTests`) — not just StitchPilot's own
writer's output — found and fixed a real, unrelated bug in `PESFormat`'s
reader (see `FORMATS.md`'s PES section): it assumed a fixed byte offset for
the embedded PEC block, which happened to match only this project's own
minimal writer output, and silently mis-parsed any real PES file carrying
different metadata before the PEC block.

## Phase 3 (continued) — sequencing generalization (implemented)

`ObjectSequencer` was rewritten from a pairwise containment-swap loop into
a proper constraint-respecting scheduler, directly targeting stitch
*conversion* performance (fewer color changes, shorter same-color jumps),
not just correctness:

- Containment still defines a strict "must sew before" partial order
  between objects (the same bounding-box test as before — it can't cycle,
  since it requires a >5% area margin to fire), computed once as a
  dependency graph rather than discovered by repeated pairwise swapping.
- Objects with no containment relationship to each other are free to be
  reordered relative to one another. Among everything currently sewable
  (no unresolved "must precede me" dependency), the scheduler greedily
  prefers: (1) the same thread color as whatever was just placed — a
  color switch costs a trim plus a manual machine stop, the most
  expensive single thing in the sequencing budget — then (2) whichever
  candidate's bounding-box center is nearest to what was just placed, to
  shorten the same-color jumps a machine actually executes unattended.
- This directly answers the "planned next" item that used to sit here
  (registration-aware color-run reordering, spec §24): scattered same-color
  objects with no containment relationship now consolidate into a single
  run automatically, instead of sequencing following document order
  exactly. It's still a greedy heuristic over a cheap geometric proxy
  (bounding-box centers, not real generated stitch-path endpoints) and not
  a full graph-based router — see `EMBROIDERY_ALGORITHM_REFERENCE.md`'s
  "recommended next improvements" for what a fuller version would need.

## Phase 3 (continued) — width-aware satin splitting (implemented)

`SatinColumnGenerator` gained `generatePartial`, called by
`DigitizePipeline` for every `.satin` object in place of the strict
`generate`. Each rail crossing is classified narrow/wide against
`maxSatinWidthMM` independently (not by the column's single average
width, which is what the stitch-type classifier upstream already uses and
can miss a column whose width varies enough that only part of it is
actually too wide); contiguous runs of two or more wide crossings become
a tatami fill sub-region built from that run's own rail points (with pull
compensation already baked into the boundary, so the sub-fill call
doesn't double-apply it), while narrow runs stay genuine satin. A lone
over-width crossing surrounded by narrow ones is folded back into satin
rather than becoming a one-crossing fill sliver — there's no meaningful
polygon to fill from a single crossing, and it's within the range of
noise a column that's otherwise a clean satin candidate can have.

This is closer to Ink/Stitch's `SatinColumn.split()` idea than the
whole-object fallback it replaces: a column that's narrow at one end and
too wide at the other now sews as satin where it fits and fill only where
it doesn't, instead of the entire object becoming fill the moment any one
section exceeds the limit. `generate` (strict, throws on any violation,
whole-object) is kept for direct/test use and any future preflight check
that wants a hard "would this fit as clean satin?" answer.

## Phase 3 (continued) — push compensation (implemented)

`PullCompensationCalculator` gained `estimatePush`, and both
`SatinColumnGenerator` and `TatamiFillGenerator` now apply it alongside
the existing pull compensation. Pull narrows a design perpendicular to
the stitching direction (already handled); push is the complementary
effect — fabric pushes apart *along* the stitching direction — so a
column or fill region sews slightly longer than digitized unless
shortened first.

For satin, this can't be implemented by trimming the rail *polylines* by
arc length: each rail's first/last few millimeters are a perpendicular
"jog" from the shared end-cap midpoint out to the boundary corner (see
`SatinColumnGenerator`'s own doc comment on tapered end caps), not travel
along the column's real length — arc-length trimming would eat into that
sideways jog almost without shortening the column at all (this was caught
by a failing test during development, not spotted by inspection).
Instead, crossings are dropped based on their midpoint's projection onto
the column's principal axis — the real length axis, immune to the
end-cap jog artifact. For fill, each scanline row's *overall* span (its
outermost start and end only, not every enter/exit pair, which would
incorrectly nibble at a hole's boundary too) is inset before resampling.

`estimatePush` reuses `estimate`'s exact formula rather than inventing a
differently-shaped one — there's no calibration data yet to justify pull
and push having different curves, consistent with this calculator's
existing "heuristic, not calibrated" caveat.

## Phase 3 (continued) — endpoint-based object sequencing (implemented)

The previous sequencing pass named its own limitation directly: a
bounding-box center is a cheap proxy, not the point a machine actually
jumps from/to. `DigitizePipeline` now restructures around that gap
instead of just noting it:

- Every object's stitch points are generated *first*, independently of
  sew order (generation never depended on neighboring objects to begin
  with, so this reorders work rather than changing what gets computed).
- `ObjectSequencer` gained `sequenceGenerated`, which runs the same
  containment-respecting, color-preferring scheduler as before but
  measures distance using each generated path's real first/last points
  instead of a bounding-box center — and can *reverse* a path (return its
  points end-first) when that's the closer approach from wherever the
  previous object left off. The machine sews an identical shape either
  direction, so there's no reason not to pick whichever one shortens the
  jump into it.
- The original `sequence` (bounding-box-center proxy, no reversal) is
  kept for any caller that needs an order before stitch points exist.

Still a greedy heuristic, not a jump-minimal solve, and still can't
reorder across a containment constraint (nor should it) — see
`EMBROIDERY_ALGORITHM_REFERENCE.md`'s "recommended next improvements" for
what a real graph-based router (restructuring a satin column itself into
a routable graph, the way Ink/Stitch's `auto_satin.py` does, rather than
ordering whole pre-built objects) would need beyond this.

## Phase 3 (continued) — true polygon containment (implemented)

`ObjectSequencer`'s containment check (`isBackground`) previously
compared bounding boxes only. `PolygonGeometry` gained `pointInPolygon`
(a standard even-odd ray-casting test), and `isBackground` now requires
every point of the candidate's outer boundary to actually fall inside the
containing shape's outer polygon — the bounding-box comparison is kept
only as a cheap pre-check before this real one. This matters for concave
shapes specifically: an L-shaped object's bounding box can enclose
something sitting entirely in its notch, outside the L's real area, which
the bounding-box-only version would wrongly treat as nested and reorder.
Area (for the "meaningfully larger" margin) is now computed from the
polygon itself (`PolygonGeometry.signedArea`) rather than the bounding
box too, for the same reason.

## Phase 3 (continued) — minimum satin width, for lettering (implemented)

`StitchTypeClassifier` already refused to classify a shape as satin if
its *average* width was too thin (sewing running stitch instead) — but a
shape whose average is fine can still narrow below the practical minimum
in one section (a tapering stroke, a serif on a letter) without the
classifier's single average ever seeing it. This is the exact mirror of
the "too wide" gap the width-aware satin splitting work closed earlier —
so it gets the same treatment:

- The classifier's previously hard-coded cutoff is now
  `StitchGenerationParameters.minSatinWidthMM` (default 1.0mm, same value
  as before), a per-object, overridable field matching how
  `maxSatinWidthMM` already worked. `StitchTypeClassifier` and
  `SatinColumnGenerator` now consult the same value instead of the
  classifier keeping its own separate copy.
- `SatinColumnGenerator.generatePartial` classifies each crossing into
  one of three kinds — too wide (fill sub-region), too narrow (new: a
  triple-run/bean-stitch line along the centerline), or fits (satin) —
  generalizing what was previously a two-way (satin/fill) classification.
  The narrow check only applies in the crossing-index *interior*
  (`interiorRange`, excluding a margin at each end): every column tapers
  toward zero width at its very tips by construction (shared end-cap
  points — see this generator's own doc comment), which would otherwise
  make every column look "too narrow" exactly where it's supposed to
  taper. A lone below-minimum crossing surrounded by in-range ones folds
  back to satin, the same hysteresis already used for lone over-width
  crossings.
- `generate` (the strict, whole-column variant) gained a matching
  `columnTooNarrow` error, symmetric with its existing `columnTooWide`.
- The narrow-run line resamples at `stitchLengthMM` (not the much finer
  `satinDensityMM` the crossings are spaced at) before tripling — a plain
  single running stitch would look visually thin next to actual satin
  elsewhere on the same object; three passes approximate satin's boldness
  on a stroke too narrow to actually zigzag.

Still open for lettering specifically: small counters (the enclosed holes
in letters like "e", "a", "o") that are too small to fill at normal
density aren't detected or simplified, and there's no small-text-specific
underlay or sequencing yet.

## Phase 3 (continued) — 2-opt sequencing refinement (implemented)

The greedy scheduler in `ObjectSequencer` is inherently short-sighted:
picking the locally-nearest candidate at each step can't see that it
leaves a worse jump later, the classic failure mode being two spatially
separate clusters visited in an interleaved zigzag instead of one cluster
then the other. A bounded 2-opt local-search pass now runs after the
greedy construction:

- Repeatedly look for a contiguous stretch of the order whose *reversal*
  lowers total cost (color changes weighted far above raw distance, so
  it never sacrifices color grouping for a shorter jump), and keep the
  best one found each pass until a full pass finds no more improvement.
- Reversing a stretch also flips each item's own `reversed` flag (which
  end it's approached from), so it's still entered from a
  self-consistent side. This has a useful consequence: every edge
  *inside* the reversed stretch is unchanged by the move (it's the same
  two points either way, and distance is symmetric), so only the two
  *boundary* edges need re-scoring per candidate — turning what would be
  an O(n) cost recomputation per candidate into O(1), which is what
  makes an exhaustive O(n²)-per-pass search practical at all.
- A reversal is only considered if no containment edge (see
  `ObjectSequencer`'s "must sew before" partial order) has both ends
  inside the stretch being reversed — provably sufficient, since
  anything *outside* a reversed stretch keeps its exact absolute
  position, so a containment edge with only one end inside the stretch
  can never end up on the wrong side of the other end.
- Skipped above `maxObjectsForTwoOpt` (300) objects as a runtime safety
  valve, and capped at a fixed number of passes.

Verified with a hand-worked nearest-neighbor trap: 5 same-color points at
x = 0, 1, -2, 4, -8 (in that authoring order). Greedy alone visits them
in that same order for 22mm of total travel (matching a by-hand trace of
the algorithm); 2-opt finds the single reversal that cuts it to 16mm,
matching the true optimum for a tour required to start at x=0 (found by
hand-enumerating the remaining orderings) — see `EMBROIDERY_ALGORITHM_
REFERENCE.md` for the full worked cost calculation.

## Phase 3 (continued) — hidden travel routing (implemented)

A same-color jump long enough to need a trim now gets routed as buried
running stitch instead, when it's provably safe to do so:
`HiddenTravelRouter` checks whether the straight path from the previous
object's exit to the next object's entry lies entirely inside the *next*
object's own shape. Since that object is sewn immediately afterward, its
own stitching is guaranteed to cover that exact area moments later — no
assumption about any other, later object is needed, which is what makes
this case safe to implement without first building general
future-coverage reasoning. (A later round restricted "its own stitching"
to satin specifically — see the entry below — this section's original
wording said "fill scanlines, satin crossings," which stopped being
accurate once that restriction landed.)

- Coverage is checked at several points sampled strictly *between* the
  two endpoints, not at the endpoints themselves: the endpoints are fixed
  regardless of this decision (a plain jump travels between the same two
  points either way), and the entry point in particular sits essentially
  on the next object's own boundary by construction (every stitch
  generator starts exactly at the shape's edge) — a numerically ambiguous
  case for even-odd point-in-polygon testing that has no bearing on the
  actual decision.
- `PolygonGeometry` gained `pointInPolygons`, extending the existing
  single-polygon point-in-polygon test to multiple closed loops at once
  (the same technique `TatamiFillGenerator.scanlineCrossings` uses for a
  full scanline), so a shape's hole sub-paths are respected — a point
  inside the outer boundary but also inside a hole correctly isn't
  "covered."
- Only fires above the *actual* trim threshold a given `flatten` call is
  using: a same-color gap short enough to not need a trim already
  becomes an untrimmed thread carry that ends up buried the same way once
  the next object covers it, so bridging it would only add stitches for
  no benefit.
- A real gap surfaced while testing this: `ObjectSequencer`'s containment
  check can classify a degenerate, zero-area shape (an open running-stitch
  line, say) as "contained" by a much larger object whenever the line's
  endpoints happen to fall inside that object's polygon — which turned
  out to be *correct*, not a bug, once examined: if a thin foreground
  detail's stitch path genuinely sits inside a big background region,
  sewing the background first really is the right call, exactly matching
  the containment feature's existing intent. Recorded here because it's
  worth knowing this behavior exists, not because it needed fixing.

Originally scoped to the immediate-next-object case only; generalized in a
later round (below) to any later object.

## Phase 3 (continued) — hidden travel routing generalized beyond the immediate-next object (implemented)

`HiddenTravelRouter.bridgeSameColorGaps` checked only the object
immediately following a same-color gap for coverage. Generalized to check
every object still to come in the sew order (bounded by
`maxLookaheadObjects`, mirroring `ObjectSequencer.maxObjectsForTwoOpt`'s
own reasoning) — the immediate-next object is still checked first, so it
keeps winning whenever it applies, but a later object now also qualifies
if its own eventual stitching covers the identical straight path,
regardless of its color. The physical reasoning was never actually
specific to "the very next thing sewn": once anything dense enough
stitches on top of a spot, whatever was buried underneath is hidden,
independent of which object that turns out to be or what color it sews
in. `nextObjectCanHideATravelPath`'s satin-only requirement (tatami
fill's own row gaps can't reliably hide a buried stitch — see that
function's doc comment) still gates every candidate exactly as before;
this only widens *which objects get checked*, not what still counts as
"opaque enough." New regression test
(`HiddenTravelRouterTests.bridgesGapWhenImmediateNextCantHideButALaterObjectCan`)
confirms a later, differently-colored satin object can justify bridging a
gap the immediate next (tatami) object alone couldn't.

**Honest measured impact:** zero change in trim count on either of the two
real files this was tested against (the PiperStitch bird mark, the Amerus
logo) — both are dominated by wide tatami-fill regions, and neither
happens to have a satin object positioned to cover their long same-color
gaps. The fix is real and correctly generalizes the mechanism (confirmed
by the new test), but the dominant remaining trim cost on tatami-heavy
designs needs a genuinely different, harder capability: reasoning about
whether a travel path can hide *within* a tatami fill's own row structure
(safe if it runs roughly parallel to a row, unsafe cutting across the row
gaps) rather than requiring satin. That's real, unscoped, higher-risk
design work — a mistake there produces a visible defect on real fabric,
not just a code-quality issue — recorded as the next item to scope
carefully rather than attempted opportunistically here.

## Phase 3 (continued) — triple-run instead of a single pass for too-thin raster shapes (implemented)

`StitchTypeClassifier.classify`'s too-thin-for-satin bucket (narrower than
`minSatinWidthMM`) now returns `.tripleRun` instead of plain
`.runningStitch` — matching what `classifyLetteringRun` already decided for
the identical case in text typed through Add Lettering (see that function's
own doc comment: "stays legible at any size since it traces the
letterform's outline"). Raster import never goes through the lettering
path at all, so a logo's own small tagline text or any other thin detail,
imported as ordinary artwork rather than typed, kept getting a single
running-stitch pass around its own outline — a hollow, faint trace that's
fine for a genuinely open hairline but reads as sparse, near-illegible
scribble on a small closed glyph shape. Found directly against a real
customer logo whose tagline text came back reported as "very sparse... the
last line of letters is not even readable" — `DigitizeCLI` against the same
file reproduced it exactly, and `StitchTypeClassifierTests.
thinRasterTracedGlyphFlattensAsTripleDensityNotASingleSparsePass` pins the
fix end-to-end (roughly triple the flattened stitch count of a single
pass), not just the classifier's own return value.

## Phase 3 (continued) — harmonized satin/fill choice across a same-color raster-imported run (implemented)

`StitchTypeClassifier` gained `harmonizeSameColorFillConsistency`, called
right before `reconcileRunningStitchOutliers` in every place that builds a
raster-imported document (`AppState.regenerateFromStoredGeometry`,
`StitchPilotServer.Engine.build`, `DigitizeCLI`). Raster import classifies
every detected shape independently — unlike Add Lettering, which already
shares one stitch type across a whole run via `classifyLetteringRun`/
`classifyGlyphInRun` — so two letters of the same word could land on
different, individually-defensible stitch types: a multi-hole letter like
"B" is forced to tatami fill (this engine's satin rings only cover a single
hole), while a neighboring hole-free "L" or "I" classifies satin on its own
narrow, uniform-width merits. Each choice is correct in isolation, but the
two textures sewn side by side in one word reads as a mistake. Found
directly against a real customer wordmark ("LIBBi") whose "B"s sewed as
visibly different fill texture next to their satin neighbors, and whose
tagline line below it mixed the same way.

The new pass applies `classifyLetteringRun`'s real rule — not a majority
vote — to same-color-grouped raster shapes already classified `.satin`/
`.tatamiFill`: if any sibling genuinely can't be a single satin column
(more than one hole, or a branching outline
`SatinColumnGenerator.canRepresentAsSingleSatinColumn` rejects), the whole
group sews as tatami fill together; otherwise the group's widest simple
(no-hole) member decides satin-vs-fill for everyone. It deliberately
leaves `.runningStitch`/`.tripleRun` siblings alone — that's
`reconcileRunningStitchOutliers`'s own, more careful territory (real
hairline accents included) — and runs first, so outlier reconciliation
then corrects toward an already-consistent baseline instead of a
still-mixed one.

## Phase 3 (continued) — anti-aliased boundaries no longer fragment into stray objects (implemented)

`ImageImporter` previously handled anti-aliasing well at the foreground/
background edge (`unpremultiply`, `excludeDominantOpaqueBackground`) and
between two *quantized clusters* (`ColorQuantizer.mergeAntiAliasingClusters`)
-- but nothing handled the identical problem at two other layers: a ramp
between two **foreground** colors meeting directly (no background pixel
between them), and a ramp cluster that k-means centers a *dedicated*
cluster on when there are enough ramp pixels to seed one (routine for a
curved letter edge against a flat, fully opaque background -- most
real-world logo exports and screenshots). Confirmed independently against
three real customer files: the PiperStitch bird mark (scratch noise across
the wing/chest), the Amerus logo (a "Light Gray"/"Dark Red" swarm ringing
the tagline, 228 objects for a 3-color logo), and the LIBBi wordmark (a
"Silver" fringe outlining every big letter).

Fixed in two complementary layers, both in `ImageImporter`:

1. **Per-pixel ambiguity.** Each foreground pixel's nearest and
   second-nearest cluster distance (Delta-E) are both tracked; a pixel
   whose two closest options are nearly equidistant is "ambiguous" --
   plausibly a blend pixel rather than confidently one real color.
   `backgroundColor` (now returned by `computeForegroundMask` for the flat,
   uniform-corner case) is included as a candidate "second nearest" too, so
   the foreground/background ramp gets the same treatment as a
   foreground/foreground one.
2. **Cluster-level suspects.** `backgroundRampClusterIndices` runs the same
   "sits almost exactly on the line between two reference colors" geometric
   test `mergeAntiAliasingClusters` already uses for two foreground
   clusters, but with the background color as one endpoint -- something
   `ColorQuantizer` itself can never do, since background pixels are
   excluded before it ever sees the pixel list. Every member pixel of a
   flagged cluster is treated as ambiguous regardless of how tightly it
   fits that cluster's own (ramp-centered) centroid, which is what makes
   layer 1 effective even when k-means gave the ramp its own dedicated,
   individually-confident-looking cluster.

Ambiguous pixels are then resolved by `smoothAmbiguousBoundaryLabels`, a
despeckle-style neighbor vote -- gated on ambiguity, not applied blindly,
which is the fix a first attempt at this got wrong: a blanket "reassign
toward the neighborhood majority" pass can't distinguish a genuine thin
ring or outline (solid, confidently one color, just narrow) from an
anti-aliasing ramp (also thin, but colorimetrically uncertain), and erased
real ring/counter-hole topology along with the noise
(`ImageImportTests.colorIslandInsideARingsCounterMergesAndStaysSolid`
caught this in review). Two more refinements followed from testing against
the real files above:

- **Multi-round propagation.** A single pass only resolves an ambiguous
  pixel touching an already-confident neighbor within one hop -- adequate
  for a 1px ramp, but a real ramp is routinely 2-3px wide. Resolved pixels
  count as confident for the next round (tracked separately from the
  original ambiguity, which never changes), so a wide ramp resolves from
  both edges inward over a bounded number of rounds (4) -- still fully
  deterministic, since each round reads one fixed snapshot and the round
  count is a fixed bound, not "until convergence."
- **Plurality, not majority.** An ordinary straight edge splits a ramp
  pixel's 8 neighbors close to evenly between the two confident sides,
  so requiring an outright majority (5 of 8) almost never fired for the
  single most common case -- confirmed directly: an early version cleared
  only small corner/speck clusters and left an entire straight-edge ring
  untouched. A strict plurality (the winning label beats the runner-up,
  with a small evidence floor) resolves the ordinary case while a genuine
  three-way color junction -- no single dominant neighbor, a real tie --
  is still correctly left alone.

Verified against all three real files (Amerus: 228 -> 162 objects, 10 -> 6
colors; LIBBi: 45 -> 27 objects, three "Silver" fringe objects reduced to
six residual small ones; bird mark: essentially unchanged, correctly --
its busy texture turned out to be genuine fine illustration detail, not
anti-aliasing, so the ambiguity gate correctly leaves it alone) plus a new
synthetic regression test
(`ImageImportTests.antiAliasedCurveAgainstFlatBackgroundDoesNotFragmentIntoStraySlivers`,
a filled circle against a flat background) that needs no real file. Full
suite (306 tests) passes.

## Phase 3 (continued) — color-island merging generalized to multiple same-color regions (implemented)

`mergeColorIslandsIntoLargestSameColorShape` only ever considered the
single globally-largest same-color shape as a merge target for a smaller
same-color fragment (an overlay's own punched-through counter, showing the
background color back through it — see the Phase 2 entry on this function
above). That misses a color that legitimately forms *two or more* separate
background regions rather than one main region plus stray fragments:
neither region's bounding box contains the other, so a fragment sitting
inside the region that *isn't* the single global largest never qualified
for merging. Found directly against the real PiperStitch bird mark: the
cream body and the cream neck are each a genuine, separate background
region, split apart by the rust head-stripe and navy beak running between
them. The old version merged whichever region's own fragments happened to
land inside the single largest region and left the other region's
fragments stray — object count dropped from 74 to 54 (a 27% reduction)
once fixed, and the fragmentation-warning count from `QualityAnalyzer`
dropped from 28 to 16, moving the design's readiness score from 81 to
87/100.

Reworked as a small transitive-redirect resolver rather than a single
largest-shape pick: each same-color shape (smallest first) looks for its
own *nearest* qualifying parent — the smallest same-color shape that both
contains its bounding box and is at least twice its area — among every
other shape of that color, not just whichever is globally biggest. A
shape whose own qualifying parent is itself later found to be someone
else's fragment (an overlay sitting on an overlay) has that redirect
resolved transitively, so a fragment always ends up merged into its
color's true top-level shape regardless of how many layers deep that
goes. Processes fragments in a fixed sorted order (not raw dictionary
iteration, which Swift doesn't guarantee) so which fragment's subpaths
get appended first to a shared target stays deterministic (spec §54).

New regression test
(`ImageImportTests.eachOfTwoSeparateSameColorBackgroundRegionsMergesItsOwnLocalIsland`)
constructs exactly this two-separate-regions scenario synthetically. Full
suite (318 tests) passes.

## Phase 3 — planned next

Object overlap/inset-outset, corner handling, and contour fill.

## Phase 4 — Quality analysis / Embroidery Readiness Score (implemented)

`QualityAnalyzer.swift` runs automatically right after Auto Digitize (not
as a separate manual step) and produces an `EmbroideryReadinessReport`:
a 0–100 score plus a list of `QualityIssue`s, each an actionable, specific
statement (spec §50: never "Design has a density problem" — always the
actual numbers) with a severity (`info`/`warning`/`critical`) and a score
penalty. `report.isReadyToSew` is `true` only when no issue is critical,
surfaced in the app as spec §76's "Ready to Sew" / "Review Recommended."

Checks implemented now, all computable from stitch geometry alone: stitches
under 0.15mm or over 12.5mm slipping past `StitchFilter` (finding one here
means a generator produced something the shared filter should have caught
— a real defect, not a style choice), jumps longer than 15mm, an unusually
high trim or stitch count, whether the design fits a given hoop size
(critical if not — pass `hoopWidthMM`/`hoopHeightMM` when a hoop is
selected; skipped entirely otherwise rather than guessing), and an empty
design.

**Deliberately not implemented yet**, rather than faked: fabric suitability
(no fabric profiles exist — Phase 5), a real needle-penetration density
heatmap (spec §31 — needs per-region stitch-count accumulation, not just
global counts), small-text/small-detail detection (needs font/text-region
awareness), and the automatic-repair loop (spec §34 — re-analyze after
fixing until the score stabilizes). Those are Phase 4/5 follow-ups; this is
the honest "what the engine can actually check today" slice.

## Phase 5 — Hoop profiles (basic form implemented)

`HoopProfile.swift` provides a small set of common, generic hoop sizes
(spec §36 — sizes are public physical facts about hoop hardware, not tied
to a manufacturer) and a picker in the app; `QualityAnalyzer`'s hoop-fit
check (which existed since the readiness score landed but had no way to be
invoked with a real hoop) now actually runs against the selected one, and
the canvas draws the hoop boundary — red when the design exceeds it. Full
machine-specific hoop catalogs, and hoop-aware placement suggestions, are a
later refinement.

## Foundation — `.stitchpilot` project file (implemented)

`ProjectFile.swift` is spec §6's "editable master format." Every model
type (`StitchDocument`, `EmbroideryObject`, `VectorShape`, `ThreadColor`,
`StitchGenerationParameters`, ...) was already `Codable` from Phase 1
onward specifically so this would be nearly free once needed — this is a
thin JSON wrapper (with a schema version, matching `StitchDocument`'s own)
plus file I/O, not a new data model. Retains everything spec §6 asks for
that the engine has actually built: object hierarchy, physical dimensions,
thread assignments, stitch types, and per-object generation parameters
(density, underlay, pull compensation, stitch-type overrides). Fields spec
§6 lists that don't exist yet (fabric/machine/hoop profile *references*,
revision history, a digitizer-adjustments log distinct from the generation
parameters themselves) will extend this wrapper when those features exist.

## Phase 4 — planned

Density heatmap, the automatic repair loop (re-analyze after fixing until
the score stabilizes).

## Phases 5–7 — planned

Fabric/machine profiles (hoop profiles exist in a basic form — see above —
but fabric-aware density/underlay/compensation and machine-specific
capability limits don't yet), production worksheet, thread consumption
estimation, advanced lettering, cap mode, appliqué, photo-embroidery mode,
batch digitizing, correction-learning architecture.

## Design decisions worth recording as they're made

- **Curve flattening resolution is fixed (28–48 segments/curve), not
  adaptive-flatness, in Phase 1.** Adequate for typical logo-scale artwork;
  revisit with true adaptive subdivision if very large or very fine designs
  show visible faceting.
- **Stitch generation is deterministic.** Given the same `StitchDocument`
  and parameters, `DigitizePipeline.flatten` always produces byte-identical
  output — no randomness, no hidden global state. This is required for the
  regression-testing approach in `TESTING.md` and matches spec §54's
  requirement that core stitch generation remain deterministic even as
  ML-assisted segmentation/classification is added later upstream of it.
