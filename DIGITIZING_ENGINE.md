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
of the defect it is.

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
  excessively wide satin regions." This is deliberately the *whole-object*
  version of the idea; Ink/Stitch's `SatinColumn.split()` can convert just
  the offending section while keeping the rest as satin, which remains
  future work.
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

## Phase 3 — planned next

Object overlap/inset-outset, hidden travel routing (sewing under later
stitching instead of jumping), corner handling, and registration-aware
color-run reordering (spec §24 — currently sequencing follows document
order exactly, with no attempt to consolidate scattered same-color runs).

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
