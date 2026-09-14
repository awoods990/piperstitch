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
own stitching (fill scanlines, satin crossings) is guaranteed to cover
that exact area moments later — no assumption about any other, later
object is needed, which is what makes this case safe to implement without
first building general future-coverage reasoning.

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

Deliberately scoped to the immediate-next-object case only; the general
version (any later object, potentially a different color if opaque
enough) is real, unscoped design work — now the top item in
`EMBROIDERY_ALGORITHM_REFERENCE.md`'s "recommended next improvements."

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
