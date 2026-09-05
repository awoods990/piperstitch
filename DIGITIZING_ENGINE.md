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

## Phase 2 — planned next

- Background/foreground detection and removal for raster input (partially
  done: `ImageImporter` already detects transparent/uniform backgrounds)
- Color quantization with the four presets in spec §8
- Multi-region object segmentation for raster input (currently one object
  per detected silhouette; no per-color splitting within a region yet)
- Thread color matching (RGB/LAB + Delta-E) against a local thread library

## Phase 3 — planned

Underlay generation, pull/push compensation, object overlap/inset-outset,
travel routing, jump/trim optimization, tie-in/tie-off, corner handling,
smarter sequencing.

## Phase 4 — planned

Density heatmap, the Embroidery Readiness Score, automatic repair loop.

## Phases 5–7 — planned

Fabric/machine/hoop profiles, production worksheet, thread consumption
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
