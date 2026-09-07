# Changelog

All notable progress is recorded here, grouped by the phase plan in
`ARCHITECTURE.md`. This file is the source of truth for "what actually
works" — `README.md`'s feature list is aspirational/target state.

## Added: initial Finished Size is now recommended from the artwork's own detail, not a fixed default

Every import previously started at a fixed 100mm width regardless of what
was actually in the file. That's fine for a plain bold logo, but real
embroidery thread (~0.3-0.4mm) puts a hard physical floor on how small a
detail can be and still sew as a recognizable shape — a badge with a ring
of curved text, small stars, and thin serifs digitized at 100mm total
width forces those details well under that floor, and no amount of
digitizing sophistication can rescue a detail that's physically too small
to stitch. Found against a real team-crest PNG: sewn at the size the fixed
default produced, its ring text and tagline were completely illegible; the
exact same file at 3-4x that size came out clearly legible.

New `SizeRecommender` estimates each raw imported shape's average width
(the same `area / length-along-principal-axis` measurement
`StitchTypeClassifier` already uses to judge a shape's own stitch width),
takes a robust low percentile across all shapes (not the single thinnest
one, which a lone noise speck could otherwise dominate), and scales the
recommended width up only as far as needed to keep that percentile's
width at a sewable minimum — capped at a sane ceiling so genuinely
unsuitable artwork doesn't get recommended an absurd size instead of
being simplified. A plain bold design with no fine detail stays at the
familiar 100mm default. The Finished Size panel still lets the user
change it immediately after — this only changes where the size starts.

## Fixed: resizing an already-digitized design didn't reconsider stitch type, so scaling up didn't actually fix small text

A shape's stitch *width in mm* changes with the document's physical size
even though nothing about the shape's own geometry changed — a stroke
too thin for satin at a small size can clear that bar once scaled up.
`regenerateFromStoredGeometry` (used on a fresh import) already re-ran
`StitchTypeClassifier` after fitting to the new size, but the Finished
Size panel's "Apply Size" button called a separate code path,
`applyPhysicalSizeChange`, that only rescaled each object's existing
geometry and left its *stitch type* exactly as originally classified.
Found directly from testing the size-recommendation fix above: scaling a
design up from a too-small original size kept its text stuck as the
illegible running-stitch scribble that size had originally produced,
instead of the same shapes reclassifying to clean satin the way a fresh
import at that same larger size would have. `applyPhysicalSizeChange` now
re-classifies each object's stitch type after resizing, exactly like a
fresh import already does.

## Fixed: one geometrically degenerate shape being classified as satin could abort an entire document's digitize

`StitchTypeClassifier` picks satin from a shape's average width alone,
which doesn't guarantee the outline is well-formed enough for satin's
own rail-fitting algorithm (an outline with fewer than 4 distinct points,
or no two identifiable ends). `SatinColumnGenerator.generatePartial`
throwing `shapeNotSuitable` for such a shape previously propagated,
uncaught, all the way up through `DigitizePipeline.flatten` — a single
bad object aborted the *whole design's* digitize with an error, rather
than just that one object degrading gracefully. Found directly while
verifying the fixes above: a design resized larger pushed a degenerate
noise sliver's *average* width across the satin threshold even though its
actual geometry could never support a real satin column. `DigitizePipeline`
now catches exactly `shapeNotSuitable` (the only error `generatePartial`
itself can throw — the two width-limit errors belong to `generate`'s
stricter, non-partial path) and falls back to running stitch for that one
object, the same fallback `StitchTypeClassifier` already uses when a
shape's *width* alone is too thin for satin.

## Fixed: a wide fill hole (a ring, a large cutout) got a long thread bridged straight across it

`TatamiFillGenerator` already avoided *systematically* stitching across a
hole (one bug, fixed earlier, that filled narrow letterform counters back
in via one dense connector per row) by grouping same-side runs into
independent "chains" and splicing a chain back in as a single short
connector where it splits off. For a narrow letterform counter that
connector is short enough to be invisible in practice. But the generator
had no way to mark an actual jump within a single object's own point
stream, only a plain stitch — so for a genuinely *wide* hole (a ring, a
large intentional cutout), that same connector became a long, structurally
weak thread bridged straight across open fabric, clearly visible once
sewn. This was only found now because raster-import hole preservation
(above) started producing real holes for raster-imported shapes for the
first time — a synthetic donut PNG run through `DigitizeCLI` rendered with
a visible diagonal line straight through its hollow center.

Fixed by giving `TatamiFillGenerator` a new `generateRuns`, which keeps a
chain-to-chain connector as a *separate* output run instead of always
merging it in, whenever that connector is longer than a threshold (the
same `maxJumpWithoutTrimMM` the rest of the pipeline already uses).
`DigitizePipeline` threads runs through the whole flatten pipeline
(`ObjectSequencer.sequenceGenerated`, `HiddenTravelRouter.
bridgeSameColorGaps`) and turns a run boundary into a real trim+jump,
exactly like it already does for a same-color gap between two separate
objects — the thread is cut and re-anchored rather than dragged across the
gap. A short connector (the common narrow-counter case) stays merged into
one run, completely unchanged from before. See
`TatamiFillGeneratorTests.swift`'s
`wideHoleConnectorBecomesASeparateRunAboveTheBreakThreshold` and
`pipelineInsertsTrimAndJumpAcrossAWideHoleInsteadOfBridgingIt`.

## Fixed: raster-imported shapes with holes rendered completely solid

A donut, or any letterform with a counter (O, P, R, A, D, B, Q), imported
from a PNG/JPEG lost its hole entirely — `ImageImporter` traced only each
cluster's outer boundary, so the enclosed background never became a second,
even-odd subpath the way SVG import (and the engine's own multi-subpath
model) already expects. This is the raster-import counterpart to an
earlier, already-fixed SVG bug ("small lettering with counters... came out
illegible") and was found by proactively testing a synthetic donut PNG
through `DigitizeCLI`, not from a user report. Fixed by a new
`findHoleBoundaries`: flood-fill every background pixel reachable from the
image border, then any background pixel the flood-fill never reaches is
part of an enclosed hole; those hole regions are traced the same way outer
boundaries are and matched to their enclosing shape by point-in-polygon,
then appended as an additional `SubPath`. See
`ImageImportTests.ringShapeImportsWithItsHoleAsASecondSubpath`.

## Added: Janome JEF export/import

A fourth machine format, alongside DST/PES/EXP, in the Export and Share
menus, plus its own 78-entry thread-color table
(`JanomeThreadPalette.swift`). Same verification bar as the other three:
byte layout read from pyembroidery's `JefWriter.py`/`JefReader.py`/
`EmbThreadJef.py` (MIT license), cross-validated against pyembroidery's own
independent reader, not just against this project's own round trip. See
`FORMATS.md` for the full layout writeup.

**Bug found and fixed during development:** JEF encodes a trim as three
consecutive zero-delta jump records, which is byte-identical to one-third
of that pattern — a genuine zero-distance jump, such as the very first
`.jump` in a plan starting at the origin. This caused a real design's
opening jump to be misread as a spurious trim. Fixed by having the writer
skip encoding any record at all for a zero-distance jump (it's a physical
no-op anyway), caught by `JEFFormatTests.trimRoundTripsAsOneCommand`.

## Added: Melco EXP export

A new machine format, alongside DST and PES, in the Export and Share
menus. Unlike the fixes below, this writes a file a physical machine
reads directly, so the byte layout was verified against pyembroidery's
actual `ExpWriter.py`/`ExpReader.py` source (MIT license) rather than
from memory, and cross-validated by round-tripping a real `.exp` file
through pyembroidery's own independent reader — not just checking this
project's own writer and reader agree with each other. See `FORMATS.md`
for the full layout writeup.

## Fixed: a circular badge (Red Sox logo) lost its background disc, then looked jagged once that was fixed

Two compounding issues found against a real circular team-logo import, in
the order they surfaced:

**1. The background disc was excluded as if it were a background fill.**
The prior fix for a text logo's background *card* (see below) excluded
the single dominant opaque color whenever it touched the canvas border at
all — but a circular badge's own background disc touches the border too,
at its tangent points, and is the main content, not a fill to discard.
Measured directly against both cases: the Red Sox navy disc covers ~15%
of any single edge; the earlier text logo's actual background card covers
40%+ of the edge it's on. `excludeDominantOpaqueBackground` now requires
that broader coverage, not just any contact, before excluding a color —
narrow tangent-point contact no longer qualifies.

**2. Once kept, the disc's outline looked jagged when stitched.** Any
circle traced pixel-by-pixel from a raster image at typical resolution
comes out as a staircase; Douglas-Peucker simplification thins the point
count but doesn't smooth the shape, so the result still visibly wobbles.
`ImageImporter.regularizeIfCircular` now checks, for every traced shape,
whether its boundary points are all nearly the same distance from the
shape's own center — the geometric signature of a real circle, not just
a square-ish bounding box (a diamond has the same bounding box as an
inscribed circle but very different corner-to-center distances, and is
correctly left alone). A shape that passes gets its jagged boundary
replaced with a smooth 72-sided regular polygon at the same center and
radius.

Both verified against the actual Red Sox logo (rendered output confirmed
visually) plus new unit tests for each (a circular badge whose background
touches the border only at a tangent point is kept; a synthetic circle
gets smoothed; a synthetic diamond with the same bounding box doesn't).

## Changed: stitch-type thresholds aligned to standard digitizing guidance

`StitchTypeClassifier` already bucketed shapes by width (spec §11), but two
gaps against common commercial digitizing practice:

- The "too thin for satin" floor (`minSatinWidthMM`) defaulted to 1.0mm;
  standard guidance treats sub-1.5mm strokes as unreliable for satin
  (thread coverage/pull compensation issues at that scale). Raised to 1.5mm.
- The whole 1-12mm range routed to satin uniformly. Standard guidance
  treats ~8-12mm as "satin or tatami depending on the shape," not
  automatically satin -- a real column still sews fine as satin near the
  wider end of that range, but a blob-shaped region whose *average* width
  happens to land there doesn't. Added a width-uniformity check for this
  band: samples the shape's actual local width at several points along its
  length (a perpendicular ray cast through the boundary, independent of
  `SatinColumnGenerator`'s own compensated per-crossing measurement) and
  only keeps satin if that varies by no more than ~35% of the widest
  point; otherwise routes to tatami.

Below 8mm and above 12mm are unchanged (already satin and already tatami
respectively, matching the guidance exactly). Holes still always route to
tatami regardless of width, as before.

## Added: select multiple objects on the canvas, merge them into one, and paint in missing coverage

Two tools aimed at the last stretch of cleanup a digitized file often
needs, built so neither requires knowing *why* something needs fixing --
just seeing it and acting on it directly:

- **Rubber-band / shift-click multi-select.** Drag a box around several
  objects on the canvas, or shift-click them (canvas or object list), to
  select more than one at a time. Plain click still selects one and clears
  the rest; the object list's own selection and the canvas's now share the
  same underlying set (`AppState.selectedObjectIDs`) instead of the
  single-id state from before, so either one drives the other.
- **Merge Shapes.** Joins every selected object's geometry into one --
  the fix for a letter or logo detail that digitized as several
  disconnected fragments (most often anti-aliasing noise breaking up what
  should be one solid shape, as seen firsthand in the background-detection
  investigation above). Implemented as `ShapeMerger`: rasterizes the
  selected shapes' union at a fine resolution and re-traces the connected
  outline(s), reusing the same boundary-tracing code raster import uses
  (pulled out into a shared `RasterTracing` utility) rather than
  implementing true polygon boolean union, which this engine doesn't
  otherwise have. Good enough for joining a handful of nearby fragments,
  not a general vector-boolean tool.
- **Paint.** A brush tool for manually adding coverage: with one object
  selected, painting over or near it extends its shape (same
  rasterize-and-retrace merge, with the stroke rendered as a chain of
  overlapping discs); with nothing selected, painting creates a new
  object in the chosen color. This is the answer to "let the user shade in
  the rest of an area if the app only captures part of the shape," raised
  earlier and deferred until a real gap actually showed up.
- Bulk delete: removing the selection now removes everything selected, not
  just one object at a time.

## Fixed: a real customer logo imported as ~300 spurious slivers instead of 2 colors

The user hit "Redo from Original" (right next to "Click to Create" — an
accidental click was a real, if separate, usability lesson learned from
this) on a design they'd already cleaned up, expecting to just discard
their edits and get back the reasonably clean original import. Instead the
"original" it rebuilt was a mess: hundreds of tiny gray objects and a
giant white rectangle behind an otherwise-correct navy/orange logo.

### Root cause

Two compounding issues in raster import, both invisible on simple test
images but real on an actual customer PNG (`LIBBi Logo.png`):

1. **`computeForegroundMask`** treats *any* opaque pixel as foreground the
   moment the canvas has *any* transparency at all. This file's canvas was
   mostly transparent at the very corners but had a large **opaque white**
   background fill behind the actual artwork — so that whole fill, plus
   every anti-aliased pixel between it and the letters, got included as
   "foreground."
2. **`ColorQuantizer`** doesn't merge k-means clusters after fitting them,
   so the anti-aliasing ramp between navy and that white fill — a
   continuous gradient through several gray tones, wide because this PNG
   had been scaled down (softening every edge across multiple pixels) —
   got its own distinct clusters instead of being folded into navy or
   background. Each of those clusters then produced its own swarm of tiny
   traced objects around every letter, and the ramp pixels sitting
   *between* adjacent letters fragmented what should have been single
   connected letter shapes into many disconnected pieces.

Together: 420 raw shapes and 7 "colors" (only 2 of which were real) from
a logo with two actual colors.

### Fix

- `ImageImporter.excludeDominantOpaqueBackground`: when the canvas has
  transparency, additionally excludes the single most common opaque color
  if it's a large enough share of the image *and* actually touches the
  canvas edge (a real background fill always does; a large solid interior
  shape generally doesn't touch every side).
- `ColorQuantizer.mergeAntiAliasingClusters`: after quantizing, folds any
  small cluster sitting almost exactly on the line between two much larger
  clusters (a geometric anti-aliasing signature) into whichever it's
  closer to — while leaving a genuinely distinct small color (an accent
  shade, say) alone, since that doesn't sit on the line.

Result on the real file: 420 objects / 7 colors down to 124 objects / 3
colors (navy, orange, and one residual "silver" cluster from the widest
part of the ramp that this pass doesn't fully absorb — a more aggressive
connectivity-based flood fill was tried to close that gap but leaked
through the thin gaps between adjacent letters and made fragmentation
*worse* on the same file, so it was reverted in favor of this smaller,
measurably-safe improvement).

## Added: project-wide density, click-to-select on the canvas, standard garment sizes, and a toolbar refresh

- **Project-wide density.** A new "Density (Entire Project)" section sets
  satin density and fill row spacing across every matching object in one
  move -- a fast pass for the whole design -- while the existing per-object
  sliders in the Object Inspector still fine-tune one shape at a time.
  It's a "set all to this" control, not a live readout of the document's
  actual (possibly varied) per-object values, so it won't fight an
  individual override made afterward.
- **Click-to-select on the canvas.** Clicking directly on a shape in the
  preview selects it (even-odd hit-testing across each object's subpaths,
  so clicking inside a letter's counter correctly misses it), the same
  selection the object list's own rows already produced. Clicking empty
  canvas deselects, matching how other design tools handle it.
- **Standard garment sizes.** A "Standard Size" picker in Finished Size
  offers common placement sizes (cap front, left chest, polo left chest,
  youth left chest, sleeve, full back) as a starting point alongside fully
  custom width/height -- picking one fills in both fields exactly as
  specified (bypassing "lock aspect ratio," since a preset already
  encodes a deliberate pair, not one dimension to derive the other from),
  and the fields stay editable afterward for the specific garment at hand.
- **Toolbar refresh.** "Create Embroidery File" is renamed "Click to
  Create," and "Redo from Original" now sits directly beside it (it's the
  natural undo-adjacent counterpart to the primary action, not a filing
  action like New/Open/Save/Undo below it).

## Added: centimeters throughout, a size grid and zoom on the preview, undo, and redo from original artwork

- **Centimeters everywhere in the UI.** Finished Size, hoop dimensions, max
  stitch length, and every per-object parameter (stitch length, satin
  width, pull/push compensation, density/row-spacing sliders) now display
  and accept centimeters instead of millimeters. The underlying model
  (`StitchPilotCore`, DST/PES export, every generator and test) is
  untouched and still works in millimeters -- that's the unit the engine
  and the file formats actually need, and converting only at the UI
  boundary means the tested core stays exactly as it was.
- **Size grid on the preview.** A new grid toggle (bottom-right of the
  canvas) overlays the design's own bounds with centimeter-labeled
  reference lines. The line spacing adapts to the current zoom level so
  it stays legible whether you're looking at the whole design or one
  zoomed-in corner of it.
- **Zoom and pan on the preview.** Pinch-to-zoom (trackpad) or the new
  +/-/reset buttons zoom into any part of the design; once zoomed in,
  click-and-drag pans around. Zoom resets automatically when a different
  design is loaded.
- **Undo.** Steps back through document edits (per-object parameter
  changes, deletions, color merges, resizes, imports, opening a project,
  starting a new project, redoing from original artwork). A slider drag
  or a burst of typing coalesces into a single undo step rather than one
  step per intermediate value, the same way live-regenerate already
  debounces so a drag doesn't re-digitize on every pixel of movement.
- **Redo from Original.** A new toolbar action that discards every edit
  made since the file was imported (per-object overrides, color merges,
  deletions, thread-library rematches) and rebuilds fresh from the
  *originally imported* artwork at the current size -- deliberately
  tracing back to the real source file rather than re-digitizing whatever
  the document currently looks like, so it's a genuine "start over," not
  a no-op that just reproduces the same edits. Undoable like everything
  else, so an accidental Redo isn't a dead end.

## Added: live density sliders, color merging, custom thread library, new project, and native sharing

The toolbar had two buttons that did the same thing ("Create Embroidery
File" and an "Auto Digitize" wand), no way to start over without quitting
and relaunching, no way to fold several detected colors into one thread
change, no way to teach the app which specific thread colors are actually
on hand, and the Export button used the send/share arrow glyph (▲) rather
than the download glyph (▼) despite writing a file to disk, not sending
one anywhere.

### What changed

- **Live density sliders.** The satin/tatami density fields in the object
  inspector are now `Slider`s instead of number fields, and every object
  edit (density, deletion, thread match toggle, physical size change) now
  triggers a debounced (150ms) regeneration of the stitch plan, so the
  preview updates continuously while dragging instead of waiting for a
  manual re-digitize.
- **Removed "Auto Digitize."** Since every edit now regenerates the plan
  automatically, its only remaining purpose (refreshing the preview after
  a parameter tweak) no longer exists — it was doing the same job as
  "Create Embroidery File" from the user's perspective, so it's gone.
- **Merge Colors.** Groups the current document's objects by exact RGB
  value, lets the user check off which groups to fold together, and
  reassigns them all to one chosen thread color in a single pass.
- **My Thread Library.** A user-defined subset of thread colors (persisted
  in `UserDefaults`) that color detection matches against instead of the
  full generic palette, once it's non-empty — the "My Thread Inventory"
  concept `ThreadLibrary.nearestMatch(to:in:)` already supported but
  nothing in the UI exposed yet.
- **New Project.** Resets all document state; asks for confirmation first
  only when there's an open document to lose.
- **Icon correction.** Export now uses the download glyph (`square.and.
  arrow.down`); a new Share menu uses the send glyph (`square.and.arrow.
  up`) and hands the current DST/PES file to `NSSharingServicePicker`
  (AirDrop, Mail, Messages, etc.) instead of only ever writing to disk.

## Fixed: part of a "B" (or any two-hole letterform) went completely unstitched

The user selected a "B" object in the app and noticed the technical preview
only filled part of the letter, even though the selection outline correctly
traced the whole shape.

### Root cause

`sequenceChains`'s "root" (the chain that continues through every hole's
split and merge, everything else spliced in relative to it) was chosen as
"whichever chain has the most total rows." That's usually the chain that
spans the shape's entire height — but not always: a hole's two sides don't
have to be won by the *same* side at both its opening row and its closing
row (a rectangular hole's edges never move, so the same side reliably wins
both, but a real rounded letter counter's edges do move, and which side
keeps more overlap with the surrounding solid rows can flip). When it
flips, the chain that ends up biggest can start *partway through* the
shape instead of at row 0 — and the main splice loop only ever checks rows
that root's own chain actually visits, so a chain starting before root even
begins (or extending past where it ends) was never found at all. Confirmed
against the real logo: roughly a third of one "B" was silently dropped
from the fill entirely.

### Fix

Added a safety net: any chain the main splice loop doesn't reach is still
included, inserted at the front if it starts before root's own first row
(much closer to where it naturally belongs than appending at the very end
would be) or deferred to the very end if splicing it mid-stream would make
root jump backward to its own remaining rows afterward. Coverage is now
guaranteed regardless of which side wins any given hole's split or merge;
the exact connector routing for these specific multi-hole cases isn't
always the shortest possible (a short, visible connector line can still
cross a hole once, same documented limitation as before), but no region is
ever silently missing. New regression test uses a shape with a *slanted*
hole specifically (the winning side must flip between opening and closing
for the bug to trigger at all — a plain rectangular hole never exercises
it), checking fill reaches both sides of the hole at its very top and very
bottom, not just somewhere in the middle.

Also added `DigitizeCLI`'s `ONLY_OBJECT` env var as a permanent diagnostic
(isolates and renders a single object by index) — this bug, like the ones
above it, was found by rendering one specific real object at high zoom and
seeing an actual gap, not by reasoning about the code in the abstract.

## Fixed: small lettering with counters (O, R, P, A...) came out illegible

Following the hole-fill fix below, the user reported the *same* logo's
small tagline text ("YOUR AI ORCHESTRATOR") still looked wrong — not just
rough at small size, but structurally garbled, reading as something like
"YOUR AI OPC IESI PAIOP" at any zoom level.

### Root cause

`StitchTypeClassifier` picked stitch type from a shape's estimated average
width alone (`area / length` along its principal axis), never checking
whether the shape actually *has* a hole. Letters with counters (O, P, R, A,
D, B, Q...) at typical stroke widths classified as `.satin` — but
`SatinColumnGenerator` only ever looks at `shape.subPaths.first` and has no
mechanism to represent a hole at all, unlike `TatamiFillGenerator`'s
even-odd handling across every sub-path. So every counter-bearing glyph
got its hole silently filled in solid, and — worse — satin's rail-fitting
(built for a simple, roughly-elongated column shape) produced genuine
nonsense for a boundary shaped like a ring instead: not a rough
approximation of the right letter, a structurally different, wrong shape.
That's why it read as different letters entirely rather than just "blurry"
ones.

### Fix

A shape with more than one sub-path (i.e. any hole) now always routes to
`.tatamiFill`, regardless of its estimated width — tatami fill's even-odd
scanline logic (and the chain-splicing fix above) already handles holes of
arbitrary shape correctly, so this is a strict improvement, not a
trade-off. Confirmed by re-rendering the real logo's tagline: "YOUR AI
ORCHESTRATOR" is now actually legible as that text, up from a garbled
"YOUR AI OPC IESI PAIOP." Also added `DigitizeCLI`'s `pixelsPerMM` as a
permanent optional argument (previously a debug-only env var, removed and
re-added properly) — this and the earlier bugs in this file were both
found by rendering real artwork at high zoom and reading the actual
result, not by reasoning about the code in the abstract.

## Fixed: a hole/counter in a fill shape rendered as solid, not hollow

A user reported a real logo (a wordmark with letters, including two "B"s)
where a letter's counter (the enclosed hole inside a "B") showed as
correctly outlined when the object was selected, but rendered solid in
both preview modes — reproduced directly against the actual SVG via
`DigitizeCLI`.

### Root cause

`TatamiFillGenerator`'s even-odd scanline logic already correctly excluded
hole pixels from the fill (`holeIsRespected` passed) — the bug was one
level down. When a hole split a scanline row into two separate crossing
intervals ("runs"), both runs were flattened into that row's *single*
stitch sequence regardless, so the needle stitched a plain, dense segment
*straight through* the hole's middle on every row that crossed it.
Individually unremarkable, but repeated across the hole's full height at
normal fill spacing (as fine as 0.4mm), those bridging stitches alone were
dense enough to visually fill the hole back in — even though no fill
*point* was ever technically inside it, which is exactly why the existing
`holeIsRespected` test didn't catch it: it checked point positions, not the
segments between them.

### Fix

`TatamiFillGenerator` now groups each row's runs into independently-
connected "chains" across rows by X-overlap (`chainRuns`) before resampling
into stitches, so a hole produces two separately-stitched regions that
never cross it, instead of one flattened sequence that does. Each chain
keeps its own boustrophedon alternation (now keyed by each run's absolute
row index, not its position in whatever chain/segment it ends up in, so
splicing chains together can't desync it from true row adjacency).

Concatenating the chains back into one sequence needed its own fix along
the way: an initial nearest-endpoint-greedy ordering (mirroring
`ObjectSequencer`'s own approach) could pick a "nearest" chain whose
straight connector cut through a *different*, unrelated hole entirely for
shapes with two separated holes — caught by a second synthetic test
(`multipleNonOverlappingHolesAreEachBoundedNotOnePerRow`) modeling a "B"'s
two counters. The real fix: splice each side-chain in immediately adjacent
to the exact row where it split off from the main fill (keyed by row
index), not reordered by geometric distance — since a fully-enclosed hole
never actually removes a row from the main chain's own sequence (every row
still gets *a* run, just a narrower one on one side), "the main chain's row
numbers have a gap" turned out not to be a reliable splice signal either;
an intermediate version of this fix assumed it was, and silently fell back
to appending the side-chain at the very end for exactly this common case.

**Remaining, smaller residual**: this generator has no way to mark an
actual jump within a single object's own point stream (only real
architectural jump support — a larger, separate change — would remove this
completely), so a small, *bounded* number of connector stitches — one where
a chain splits off, one where it rejoins — can still legitimately cross a
hole once each, worst case, rather than not at all. For a perfectly
rectangular hole (no narrower "pinch point" to route the transition
through at any row) this is as visible as it'll get; a real rounded letter
counter tapers at top and bottom exactly where the splice happens, so in
practice the residual is far smaller — confirmed by re-rendering the actual
reported logo: both "B" counters are now correctly hollow, with only a
short connector tail at the bottom of each, down from being entirely
filled in.

## Broader real-world test cycles: format-reader validation + a studied fill technique

Continuing the "run test cycles against public embroidery data" request:
cloned two more reference projects the user pointed to and used each for
what it's actually good for, rather than treating both the same way.

- **[EmbroidePy/samples](https://github.com/EmbroidePy/samples)** (MIT):
  cloned the full repository (654 files — 5 designs × every machine format
  supported by EmbroidePy, Brother, Wilcom, "me," and "premier" software)
  and ran every DST/PES file (98 total) through `DSTFormat.read`/
  `PESFormat.read` via a temporary `DigitizeCLI --validate-formats
  <directory>` mode. **All 98 parsed successfully** with sane stitch
  counts and bounding boxes — no bugs found here, a genuine (negative)
  result worth recording. Expanded the permanently-vendored fixture set
  from 2 files (one design, one exporter) to 6, adding a different
  exporter's DST (`random1-wilcom.dst`), a different exporter's PES
  (`random1-brother-v6.pes`), and an entirely different design
  (`scene.dst`/`scene.pes`) — broadening `ThirdPartySampleTests` coverage
  without vendoring all 654 files, most of which are redundant re-encodings
  of the same handful of designs. See `Tests/StitchPilotCoreTests/Fixtures/
  ThirdPartySamples/README.md` for exactly what's vendored and why.
- **[CreativeInquiry/PEmbroider](https://github.com/CreativeInquiry/PEmbroider)**
  (GPLv3/Anti-Capitalist License): a Processing embroidery library, not a
  sample-file corpus, so read for algorithmic understanding only (same
  ground rule as Ink/Stitch — see `EMBROIDERY_ALGORITHM_REFERENCE.md`).
  Confirms `ObjectSequencer`'s greedy+2-opt sequencing already matches this
  project's own approach (its `PEmbroiderTSP.java` is, by its own header
  comment, "Basic TSP implementation: Greedy + 2-Opt"). Also surfaced a
  real, unimplemented gap: `PEmbroiderHatchSpine.java` follows a shape's
  medial axis/skeleton for fill direction, so it bends with a curved or
  tapered shape instead of `FillAngleSelector`'s one fixed angle for the
  whole shape — recorded as a "Recommended next improvement" in
  `EMBROIDERY_ALGORITHM_REFERENCE.md` rather than attempted here, since it
  needs a raster or polygon-based skeletonization primitive this codebase
  doesn't have yet, real unscoped design work rather than a tunable.

## Two real raster-import bugs found against a real logo, plus UI fixes

A user report ("a small image produced over a million stitches, and lines
were jagged") led to testing against a real-world file (`SMA Logo.webp`, a
detailed school seal-and-text logo) via `DigitizeCLI`, rather than only the
existing synthetic `TestArtwork/` fixtures — and found two real, serious
bugs in `ImageImporter`, not a tuning problem.

### Fixed
- **Raster boundary tracing never actually closed, for any shape, ever**
  (`ImageImporter.traceBoundary`): the Moore-neighbor contour tracer's
  closing check compared the walk's current position against `first` using
  an *assumed* backtrack direction (west, chosen only to bootstrap the very
  first neighbor search) — but the walk's real closing re-entry direction
  depends on the shape and is generally different (empirically, always the
  opposite side for a simple square). That assumed check never matched, so
  every trace ran to its `maxSteps` backstop and returned whatever partial
  walk it had accumulated, labeled as if it were a complete boundary. For a
  well-formed shape this was merely wasteful — the same correct loop
  retraced dozens of times over (confirmed by the existing `ImageImportTests`
  suite running **56x faster** after the fix, 4.3s → 0.08s, with identical
  results) — but for a thin or pinch-pointed fragment (common in anti-
  aliased detail: text serifs, seal ridges) the walk can oscillate without
  ever recurring at all, producing a wildly disproportionate "boundary."
  One 39-pixel fragment of `SMA Logo.webp` produced a 126,017-point
  boundary this way. Fixed using the actual textbook Jacob's stopping
  criterion: compare against the state right after the walk's first real
  step (the second boundary point, entered from `first`), which is the
  state that genuinely recurs — and reject a trace that hits `maxSteps`
  without ever recurring, instead of returning it as if valid.
- **Anti-aliased edges read as spurious dark "colors"**
  (`ImageImporter.renderRGBA`/`unpremultiply`, new): pixels were rendered
  into a *premultiplied*-alpha `CGContext` (the only kind Core Graphics
  supports as a drawing destination) and then read directly as if straight
  (non-premultiplied) RGB — so any partially-transparent pixel's stored
  color was `trueColor × alpha`, e.g. a 50%-alpha gold edge pixel stored as
  dark olive-brown, not gold. Every anti-aliased edge in real artwork (one
  ring around every letter and detail in a text-heavy logo) therefore read
  as its own spurious color distinct from both the true foreground and the
  background, each becoming its own tiny traced object. Fixed by un-
  premultiplying the whole pixel buffer once, right after rendering, before
  any color is read from it.
  - **Combined effect**: `SMA Logo.webp` (512×123px, a shield seal + three
    lines of text) went from "over a million stitches" and a multi-minute
    hang to 187 objects, 2,728 stitches, in ~6 seconds — and the rendered
    result is now actually legible as the source logo, not garbled shapes.
    187 objects is still more than a hand-digitizer would use (each text
    glyph becomes its own object, as does residual anti-aliasing noise the
    8-pixel minimum-area filter didn't catch) — a reasonable next target,
    not addressed in this pass.
- **Douglas-Peucker polyline simplification, exact worst case is O(n²)**
  (`PolylineSimplify.douglasPeucker`): raster-traced pixel boundaries are
  exactly the kind of near-collinear "staircase" input that triggers DP's
  worst case, and the 126,017-point degenerate boundary above sent this
  single call into a multi-minute hang on its own, independent of the
  tracer bug — kept as a fix in its own right (defense in depth against any
  other pathologically large boundary, not just that specific one).
  Rewrote iteratively (an explicit stack, not recursion — the same
  degenerate input can also recurse as deep as the input size, risking a
  stack overflow) and added a pre-decimation cap: above 3,000 points,
  uniformly downsample before running the exact algorithm, bounding worst-
  case work regardless of input size. Embroidery stitch width is coarser
  than pixel-level detail, so the lost sub-pixel fidelity above that
  threshold costs nothing visible.
- **`flatten`/`colorSequence` called separately re-ran the entire
  generation pipeline twice** (`DigitizePipeline`): both independently
  called the same expensive per-object generation-and-sequencing pass. Not
  wrong, but for a design with many objects (187, for the logo above) this
  is a real, user-visible slowdown, compounded further since `AppState`
  called `flatten` once and `colorSequence` again at export time, and
  `StitchCanvasView`'s realistic preview called `colorSequence` a third
  time. Added `flattenWithColors(_:)`, computing both from one shared pass;
  `AppState.autoDigitize` now calls it once and caches the result
  (`lastColorSequence`) for export and the canvas preview to reuse, instead
  of each recomputing it. Cut the logo's end-to-end CLI time from ~10s to
  ~6.4s on top of the bugs above.

### Added
- **Selected-object highlighting**: the object currently selected in the
  object list is now outlined (white halo + dashed accent stroke, so it
  stays visible against any thread or background color) directly in the
  canvas, in both preview modes — previously there was no visual link
  between the object list and the canvas at all.
- **Click-to-browse import**: the empty-state drop prompt is now tappable,
  opening the same file picker as File > Open > Open Artwork, instead of
  drag-and-drop being the only way in.
- Realistic preview texture: each stitch segment is now drawn individually
  (alternating between two slightly different shades) instead of one
  merged path per color run, and the sheen highlight is offset
  perpendicular to *each segment's own direction* rather than centered on
  it — a thread is a cylinder, so its specular highlight runs along
  whichever side faces the light, which rotates with the thread's own
  direction; a centered highlight reads as a flat painted stripe, an offset
  one reads as round.

## Realistic preview, manual editing, and a real quality-measurement bug found by testing

### Added
- **Realistic sewn-out preview** (`Sources/StitchPilotCore/Rendering/StitchRenderer.swift`,
  new): renders a `StitchPlan` to a raster image approximating actual thread
  — each color run stroked at real thread width with rounded joins, plus a
  second, thinner, low-opacity white pass down the same centerline to
  suggest a round thread's sheen — rather than a technical wireframe. Wired
  into `StitchCanvasView` as a "Realistic" preview mode (segmented picker,
  defaults on once a stitch plan exists) alongside the original "Technical"
  wireframe mode, which stays available for verifying individual stitch
  placement. The realistic render is cached and only regenerated when the
  plan actually changes (a `commands.hashValue`-based signature), not on
  every window resize.
- **`DigitizeCLI`** (new SPM executable target, `Sources/DigitizeCLI/`): a
  no-GUI harness around the exact digitizing pipeline the app uses —
  import → build objects → `DigitizePipeline.flatten` → `QualityAnalyzer` →
  `StitchRenderer` — for running test cycles against real artwork and
  inspecting output without driving the SwiftUI app (this environment has
  no accessibility/AppleScript automation available for that). This is how
  the bug below was actually found: by rendering and reading real output,
  not by reasoning about the code in the abstract.
- **Manual editing**: delete an object (trash icon in the Object Inspector,
  or right-click a row in the object list) and override an object's thread
  color from `ThreadLibrary.genericPalette` (Object Inspector), both
  building on the Object Inspector's existing per-object parameter editing.

### Fixed
- **A real, confirmed measurement bug, found via `DigitizeCLI` test cycles
  against `TestArtwork/multi_color_badge.svg`**: `StitchPlan.
  maxStitchLength()`/`totalStitchLength`, `QualityAnalyzer.
  checkStitchLengths`/`checkJumps`, and both preview renderers
  (`StitchRenderer`, `StitchCanvasView`'s wireframe) all walked
  `plan.commands` tracking "the last point" but never reset it across
  `.colorChange`/`.trim`/`.stop`. Since the thread is physically cut at a
  trim, the first stitch of the run that follows has nothing to do with
  wherever the previous color's thread ended — but all six places measured
  (or, in the two renderers, actually *drew*) a phantom segment spanning
  that gap. On the badge test file this reported a 38mm "stitch" (the real
  longest stitch was 4.4mm) and a false "3 stitches exceed 12.5mm" quality
  warning, dropping the readiness score from a deserved 95 to 89; in the
  new realistic/wireframe previews it would have drawn a visible, wrongly
  colored line bridging every color change in any multi-color design. Fixed
  by resetting the tracked point to `nil` at `.colorChange`/`.trim`/`.stop`
  in all six places. The actual DST/PES *exporters* were never affected —
  they encode real physical needle deltas from machine state, not a
  measured "last point," so real sewn output was always correct; this was
  purely a quality-report and preview-rendering defect. Regression tests:
  `QualityAnalyzerTests.distantStitchesAcrossATrimDoNotFalselyFlagAsOneLongStitch`,
  `GeometryTests.totalStitchLengthExcludesTheGapAcrossAColorChange`,
  `StitchRendererTests.colorChangeDoesNotDrawABridgingLineAcrossTheGap`.
- **Underlay/fill seam misalignment** (`DigitizePipeline.rawStitchPoints`):
  a `.tatamiFill` object's edge-run underlay traces a closed loop whose
  start/end point is physically arbitrary, but was left wherever the trace
  happened to start — which could land far from the fill's own first
  point, and since underlay+fill is one continuous same-color run, that gap
  became a single very long "stitch" that `StitchFilter` then chopped into
  several segments spanning much of the design. Fixed by rotating the
  underlay loop's seam to end as close as possible to the fill's first
  point before concatenating (only valid for a genuinely closed loop —
  edge-run, fill's default; center-run/zigzag underlays are open paths
  whose endpoints are physically meaningful and are left alone). Confirmed
  via `DigitizeCLI`: max stitch length on `simple_square_logo.svg` dropped
  from 11.31mm to 3.25mm.
- `TatamiFillGenerator.resampleRun` now evenly redistributes the remaining
  distance across a row after its staggered first stitch, instead of
  stepping by a fixed length and leaving an arbitrary-length "catch-up"
  segment wherever that happens to land — a smaller, secondary cleanliness
  improvement found during the same test cycles (it did not change the
  visual appearance of anything actually wrong; see the investigation notes
  below).

### Investigated and ruled out
- A visually dramatic "sawtooth"/criss-cross pattern near fill boundaries,
  first noticed while building the diagnostic tooling above, turned out
  **not** to be a generation defect after extensive direct data inspection
  (raw fill points, underlay points, and final filtered plan points were
  all clean and monotonic at every boundary checked). It's the intentional
  tie-in/tie-off anchor "there and back" lock stitches (`TieStitchGenerator`)
  — real, standard embroidery practice — which simply look dramatic when
  rendered at real thread width against closely-spaced (~0.4mm) fill rows.
  No change needed; recorded here so a future investigation doesn't repeat
  the same multi-hour trace.

## Rebrand to OneClickStitch, and a real one-click action

### Added
- Renamed the product from its working name "StitchPilot" to
  "OneClickStitch" using the real brand assets provided (a wordmark logo
  and a matching favicon — an embroidered-thread "S" with a cursor-click
  motif, copied into `Resources/Branding/` for reproducibility). Per
  `ARCHITECTURE.md`'s "Branding" section (written specifically to make
  this kind of rename possible without touching core logic): changed
  `Info.plist` (`CFBundleName`/`CFBundleDisplayName`/`CFBundleIdentifier`/
  `CFBundleIconFile`), the window title, `Scripts/build_app_bundle.sh`'s
  output bundle name (now `OneClickStitch.app`), and the app icon
  (`Resources/OneClickStitch.icns`, generated from the real favicon via
  `sips`/`iconutil`, replacing the old programmatically-drawn placeholder
  mark and its now-obsolete generator script). Deliberately left
  unchanged: `Package.swift`'s package/target/product names and the
  compiled binary's own filename inside the bundle — internal identifiers
  with no user-visible surface; `CFBundleDisplayName` is what Finder, the
  Dock, and the menu bar actually show, independent of the binary's own
  name, a normal pattern.
- **One-click embroidery creation**: `AppState.createEmbroideryFile()`
  runs Auto Digitize and immediately prompts to save, combining what were
  two separate manual steps (click Auto Digitize, then use the Export
  menu) into the single action most users actually want — matching the
  product's own name and promise. The save panel offers both DST and PES
  via its own format picker rather than committing to one up front, so
  the single action still covers both Tajima and Brother/Baby Lock
  machines. The existing manual Auto Digitize/Export menu items stay
  available for anyone using the Object Inspector to tune parameters
  between digitizing and exporting.
- A new toolbar button, "Create Embroidery File," styled with
  `.borderedProminent` and the brand's blue tint plus the actual favicon
  image (bundled as an SPM resource for `StitchPilotApp`, loaded via
  `Bundle.module`) so it's unmistakably *the* button in the toolbar next
  to the existing plain-icon actions. The same brand mark, larger,
  appears in the canvas's empty state alongside the product name and
  tagline ("Turn any image into embroidery").
- Status messages throughout point at the new one-click action instead of
  the old two-step manual flow.

### Known limitations at this stage
- Verified via successful compilation, the full test suite (unaffected —
  this is a UI/branding-only change), and a direct screenshot of the
  running app confirming the rebrand and the button's correct
  disabled-state rendering with no artwork loaded. The button's *enabled*
  (blue, active) rendering wasn't independently screenshotted — no
  accessibility permission is available in this environment to script a
  file import and trigger it — though `.borderedProminent` + `.tint()` on
  an enabled button is standard, well-understood SwiftUI behavior. Worth
  a quick manual check.

## Hidden travel routing (stitch-conversion performance)

### Added
- `HiddenTravelRouter`: a same-color jump long enough to need a trim now
  gets routed as buried running stitch instead, when the straight path
  from the previous object's exit to the next object's entry lies
  entirely inside the *next* object's own shape. Since that object is
  sewn immediately afterward, its own stitching is guaranteed to cover
  the path — provably safe without reasoning about any other, later
  object, which is real, unscoped design work left for a future round
  (see "Known limitations" below).
- Coverage is checked at points sampled strictly between the two
  endpoints (not at the endpoints themselves, which are fixed regardless
  of the decision and, for the entry point, sit on the target shape's own
  boundary by construction — a numerically ambiguous case for even-odd
  testing that doesn't affect the actual decision).
- `PolygonGeometry` gained `pointInPolygons`, generalizing the existing
  single-polygon test to multiple closed loops at once (an even-odd union
  across all of them), so a shape's holes are respected; the existing
  `pointInPolygon` is now implemented in terms of it. `DigitizePipeline`
  threads its actual `maxJumpWithoutTrimMM` through so bridging only
  fires where a real trim would otherwise happen (a same-color gap short
  enough not to need one already ends up buried under the next object's
  stitching just the same as an untrimmed jump).
- 8 new tests: 3 in `PolygonGeometryTests` (hole handling for
  `pointInPolygons`) and a new `HiddenTravelRouterTests` suite covering
  bridging when covered, not bridging when the path leaves the shape,
  not bridging short gaps even when covered, not bridging across a color
  change, and two `DigitizePipeline.flatten` integration tests confirming
  trim count actually drops when coverage holds and doesn't when it
  doesn't. Building the pipeline-level tests surfaced and required
  correcting three real test-construction mistakes along the way (a
  `.tatamiFill` object's automatic angle defaulting to 90° for a
  perfectly symmetric square, `UnderlayGenerator` prepending points
  before a `.tatamiFill` object's own entry unless underlay is
  explicitly disabled, and Swift's `.none` on an `Optional<UnderlayType>`
  resolving to `nil` rather than the `UnderlayType.none` case) — each
  caught by the test actually failing rather than a silent false pass.

### Known limitations at this stage
- Only bridges into the immediate next object, not any later one; a
  larger background object that would cover the same path but is
  scheduled further out isn't caught, nor is a different-color object
  opaque enough to hide it.
- Surfaced (but didn't need to fix) a real property of `ObjectSequencer`:
  a degenerate zero-area shape (an open running-stitch line) can be
  classified as "contained" by a much larger object whenever its
  endpoints fall inside that object's polygon — correct behavior on
  inspection (a thin foreground detail genuinely inside a background
  region should sew after it), not a bug, but worth knowing it exists.

## 2-opt local-search refinement of object sequencing (stitch-conversion performance)

### Added
- `ObjectSequencer` follows its greedy construction with a bounded 2-opt
  local-search pass: repeatedly tries reversing a contiguous stretch of
  the order and keeps the best improving reversal found each pass, until
  a full pass finds none. Fixes the classic nearest-neighbor failure
  mode a pure greedy scheduler can't see coming — two spatially separate
  clusters visited in an interleaved zigzag instead of one cluster then
  the other.
- Reversing a stretch also flips each item's own entry/exit choice, which
  leaves every edge *inside* the stretch unchanged (same two points,
  distance is symmetric) — so only the two boundary edges need
  re-scoring per candidate reversal, turning an O(n) cost recomputation
  into O(1) and making an exhaustive O(n²)-per-pass search practical.
- A reversal is rejected if any containment edge has both ends inside
  the stretch being reversed — sufficient because anything outside a
  reversed stretch keeps its exact absolute position, so a containment
  edge with only one end inside can never end up on the wrong side of
  the other. Skipped above 300 objects (runtime safety valve) and capped
  at a fixed number of passes.
- 2 new tests: a hand-worked nearest-neighbor trap (5 same-color points
  at x = 0, 1, -2, 4, -8) where greedy alone produces a 22mm tour and
  2-opt finds the single reversal reaching the true 16mm optimum for a
  fixed starting point, verified by hand-enumerating the alternatives;
  and a containment-safety regression test confirming the constraint
  survives even with real 2-opt work to do. Full suite (129 tests) green,
  and no pre-existing test's exact-order expectations changed (they all
  have 3 or fewer objects, below the size where 2-opt does anything).

### Known limitations at this stage
- Local search, not a guaranteed jump-minimal order — can converge to a
  local optimum a smarter move set (e.g. Or-opt, 3-opt) would escape.
- Still treats each object as an atomic, pre-built unit; a real
  graph-based router (Ink/Stitch's `auto_satin.py` approach) routes
  through a satin column's own structure instead.

## Object Inspector: manual per-object overrides before export

### Added
- The object list is now selectable (`List(..., selection:)` bound to a
  new `AppState.selectedObjectID`), and the Inspector panel gained an
  "Selected Object" section shown whenever an object is selected: stitch
  type (running/triple-run/satin/fill), the parameters relevant to that
  stitch type (stitch length; satin density/max width/min width; fill row
  spacing and angle), underlay type, and pull/push compensation for
  satin/fill objects — every "automatic" (`nil`) field gets an Automatic
  toggle that reveals a manual value when turned off. `AppState.
  updateSelectedObject` writes the edit straight into the master
  document. This is the first UI surface for the per-object override
  capability `StitchGenerationParameters` has had since Phase 3 — every
  field this round's engine work added (push/pull compensation, minimum
  satin width) was already overridable in the model, just not reachable
  from the app.
- Deliberately exposes the fields a digitizer reaches for regularly, not
  every one of the ~15 fields `StitchGenerationParameters` has (underlay
  inset, fill row stagger, and filter thresholds stay engine defaults for
  now).
- Edits update the document immediately but don't re-flatten the stitch
  plan on every keystroke, the same "edit, then explicitly regenerate"
  pattern resizing already uses — click Auto Digitize to see the result.
  A caption in the panel says so, so it doesn't read as broken.

### Known limitations at this stage
- Automated UI verification isn't available in this environment (no
  Screen Recording permission for the tooling here, so screenshots come
  back black) — this was verified via successful compilation and manual
  code review of the binding logic, not by actually driving the app.
  Worth a quick manual click-through before relying on it.
- `selectedObjectID` doesn't get explicitly cleared when the document is
  fully rebuilt (import, resize, project load); it's self-healing instead
  (`selectedObject` returns nil once the id no longer matches anything in
  the new document), which is simpler but means the list's internal
  selection state can point at a UUID nothing displays as selected.

## Minimum satin width, for lettering quality

### Added
- `StitchGenerationParameters.minSatinWidthMM` (default 1.0mm): the
  minimum-width mirror of `maxSatinWidthMM`. `StitchTypeClassifier`'s
  previously hard-coded, non-overridable cutoff moved here, so it's now a
  per-object value matching how the maximum already worked.
- `SatinColumnGenerator.generatePartial` now classifies each crossing
  into satin / too-wide (fill) / too-narrow (new), instead of just
  satin/too-wide. A too-narrow run (checked only in the crossing-index
  interior, excluding each column's natural end-cap taper — see
  `interiorRange`) becomes a triple-run (bean-stitch) line along the
  centerline instead of a satin zigzag, closing the exact mirror-image
  gap of what the width-aware satin splitting work fixed for "too wide":
  a column whose *average* width is fine but that narrows below the
  practical minimum in one section (a tapering stroke, a letter's serif)
  previously had no defense-in-depth beyond the classifier's single
  average, which can't see a local dip.
- `generate` (the strict, whole-column variant) gained a matching
  `SatinGenerationError.columnTooNarrow`, symmetric with the existing
  `columnTooWide`.
- 4 new tests: 2 in `SatinColumnGeneratorTests` (a uniformly hairline
  column throws from `generate` and converts to a much shorter triple-run
  line from `generatePartial`) and 1 in `StitchTypeClassifierTests`
  (overriding `minSatinWidthMM` per object changes the classification
  threshold).

### Known limitations at this stage
- Same abrupt-seam and lone-crossing caveats as the maximum-width case.
- Doesn't address small counters (enclosed holes in letters like "e",
  "a", "o") too small to fill at normal density, or any other
  lettering-specific underlay/sequencing.

## True polygon containment for object sequencing (correctness)

### Added
- `PolygonGeometry.pointInPolygon`: a standard even-odd ray-casting
  point-in-polygon test, generically useful beyond this one caller.
- `ObjectSequencer`'s `isBackground` now requires every point of the
  candidate's outer boundary to actually fall inside the containing
  shape's outer polygon, not just that their bounding boxes nest (the
  bounding-box check is kept as a cheap pre-check before the real one).
  A concave (e.g. L-shaped) object's bounding box can enclose something
  sitting entirely in its notch, outside its real area — the previous
  bounding-box-only check would misclassify that as containment and
  wrongly reorder it. Area (for the "meaningfully larger" margin) is now
  computed from the polygon itself rather than the bounding box, for the
  same reason.
- 5 new tests: a dedicated `PolygonGeometryTests` suite for
  `pointInPolygon` (inside/outside/concave-notch/degenerate cases) plus
  `ObjectSequencerTests.trueContainmentIgnoresBoundingBoxCoincidence`
  (an L-shape whose bounding box coincidentally encloses an unrelated
  square sitting in its notch).

### Known limitations at this stage
- Only tests a shape's *outer* boundary (`subPaths.first`), ignoring
  holes — an object inside another's hole would still be misclassified
  as contained. Rare for typical logo/badge artwork.

## Endpoint-based object sequencing (stitch-conversion performance)

### Added
- `DigitizePipeline` now generates every object's stitch points first,
  independently of sew order, then sequences the *results* — closing the
  gap the previous sequencing round named as its own limitation (a
  bounding-box center is a cheap proxy for where a machine actually jumps
  from/to, not the real thing).
- `ObjectSequencer.sequenceGenerated`: the same containment-respecting,
  color-preferring greedy scheduler as `sequence`, but measuring distance
  from each generated path's real first/last points instead of a
  bounding-box center, and able to *reverse* a path (sew it end-first)
  when that's the closer approach from wherever the previous object left
  off — the machine sews an identical shape either direction, so there's
  no reason not to pick whichever shortens the jump into it. `sequence`
  itself is refactored to share the same scheduling core (with entry and
  exit both set to the bounding-box center, so reversal is always a
  no-op) and is kept for callers without generated points yet.
- 2 new tests (`sequenceGeneratedReversesPathForCloserApproach`,
  `sequenceGeneratedDoesNotReverseWhenAlreadyCloser`); all pre-existing
  `ObjectSequencer` and `DigitizePipeline` tests pass unchanged.

### Known limitations at this stage
- Still a greedy heuristic, not a jump-minimal solve, and still treats
  each object as an atomic pre-built unit rather than restructuring a
  satin column into a routable graph the way Ink/Stitch's `auto_satin.py`
  does — see `EMBROIDERY_ALGORITHM_REFERENCE.md`'s "recommended next
  improvements."

## Push compensation (stitch-conversion performance)

### Added
- `PullCompensationCalculator.estimatePush`: push compensation's
  counterpart to the existing pull estimate. Pull narrows a design
  perpendicular to the stitching direction (already handled); push is the
  complementary effect — fabric pushes apart *along* the stitching
  direction — so a satin column or fill region sews slightly longer than
  digitized unless shortened first. Reuses pull's exact formula rather
  than inventing a differently-shaped one with no calibration data to
  justify it.
- `SatinColumnGenerator` and `TatamiFillGenerator` now both apply push
  compensation. Satin drops rail crossings based on their midpoint's
  projection onto the column's principal axis (not by trimming the rail
  polylines by raw arc length — a first attempt at that was caught by a
  failing test: each rail's first/last few millimeters are a
  perpendicular "jog" from the shared end-cap midpoint out to the
  boundary corner, not travel along the column's real length, so
  arc-length trimming barely shortened the column at all). Fill insets
  each scanline row's outermost start/end before resampling, leaving
  internal hole-boundary crossings untouched.
- `StitchGenerationParameters` gained `pushCompensationMM: Double?` (`nil`
  = automatic), mirroring `pullCompensationMM`.
- 2 new tests (`pushCompensationShortensColumn`,
  `pushCompensationShrinksRowSpan`); both `params()`/`squareParams()` test
  helpers now default `pushCompensationMM = 0` alongside the existing
  `pullCompensationMM = 0`, so all pre-existing exact-geometry tests stay
  deterministic against the new default-on automatic behavior.

### Known limitations at this stage
- Reuses pull's formula verbatim; no calibration data exists yet to
  justify push and pull having differently-shaped curves.
- Push and pull are estimated independently per object; two adjacent
  unrelated objects each getting their own estimate could still compound
  in ways neither accounts for.

## Width-aware satin splitting (stitch-conversion performance)

### Added
- `SatinColumnGenerator.generatePartial`: replaces the whole-object
  satin-to-fill fallback with a genuine per-section one. Each rail
  crossing is classified narrow/wide against `maxSatinWidthMM`
  independently, instead of the whole object converting to fill the
  moment any part of it exceeds the limit; contiguous runs of two or more
  wide crossings become a tatami fill sub-region built from that run's
  own rail geometry (pull compensation already baked into the boundary,
  so the sub-fill call doesn't double-apply it), while narrow runs stay
  real satin. A lone over-width crossing surrounded by narrow ones folds
  back into satin rather than becoming a degenerate one-crossing fill
  sliver. `DigitizePipeline` now calls `generatePartial` for every
  `.satin` object; the original `generate` (strict, throws on any width
  violation, whole-object) is kept for direct/test use and any future
  preflight check wanting a hard yes/no answer.
- 3 new tests: `partialMatchesPureSatinWhenColumnFitsEntirely` (identical
  output to `generate` when nothing needs splitting), 
  `generatePartialNeverThrowsWhenUniformlyTooWide`, and
  `generatePartialKeepsNarrowSectionAsSatinAndConvertsWideSection` (a
  tapering trapezoid that `generate` rejects outright but `generatePartial`
  sews as satin at the narrow end and fill at the wide end).

### Known limitations at this stage
- Classifies each crossing against one global width limit; doesn't yet
  smooth the stitch-density transition at a narrow/wide seam, which is a
  clean but abrupt technique change right now.

## Sequencing generalization (stitch-conversion performance)

### Added
- Generalized `ObjectSequencer` from a pairwise containment-swap loop into
  a real constraint-respecting scheduler, aimed squarely at reducing
  what a machine actually pays for at sew time: thread color changes and
  same-color jump distance. Containment (a shape that geometrically
  contains another) still defines a strict "must sew before" order that's
  never violated — computed once as a dependency graph instead of
  discovered by repeated swapping — but objects with no containment
  relationship to each other are now free to be reordered, and the
  scheduler greedily prefers (1) matching the previous object's thread
  color, to consolidate scattered same-color objects into one run instead
  of paying a trim/color-change every time the design happens to alternate
  colors, then (2) whichever candidate is nearest (bounding-box center
  distance) to what was just placed, to shorten the jumps a machine
  executes without operator intervention. Directly closes a "planned
  next" gap noted in `DIGITIZING_ENGINE.md` (spec §24, registration-aware
  color-run reordering) that had been open since Phase 3.
- `BoundingBox` gained a `center` property, needed for the proximity
  heuristic above and generically useful.
- 3 new tests (`groupsSameColorObjectsToMinimizeColorChanges`,
  `prefersNearestSameColorCandidateToMinimizeJumpDistance`,
  `containmentStillWinsOverColorGrouping`) plus 1 for `BoundingBox.center`;
  all 6 pre-existing `ObjectSequencerTests` still pass unchanged against
  the new algorithm.

### Known limitations at this stage
- Still a greedy heuristic over bounding-box centers, not real generated
  stitch-path endpoints, and not a full graph-based router — see
  `EMBROIDERY_ALGORITHM_REFERENCE.md`'s "recommended next improvements."

## Reference-informed algorithm improvements (studying Ink/Stitch, EmbroidePy, pyembroidery)

Per an explicit instruction to study legitimate public embroidery-digitizing
repositories as technical reference material and use that study to improve
the automatic digitization algorithm itself (not just add file-format
coverage), `EMBROIDERY_ALGORITHM_REFERENCE.md` records what was studied
(Ink/Stitch, GPL-3.0; EmbroidePy/samples, MIT; pyembroidery, MIT), the
license of each, and which techniques below are original work vs.
reference-informed vs. adapted. No code was copied from Ink/Stitch (GPL);
it was read for algorithmic understanding only and reimplemented
independently against this project's own model and conventions.

### Added
- Satin auto-fallback to fill (`DigitizePipeline.swift`): when
  `SatinColumnGenerator` throws `columnTooWide` for a shape too wide to
  satin-stitch cleanly, the pipeline now falls back to tatami fill for that
  object instead of failing the whole design. A shape too wide for satin is
  a legitimate, fairly common case (not just bad input), so refusing to
  produce any output for it was a real gap.
- Zigzag underlay for wide satin columns (`UnderlayGenerator.swift`,
  `EmbroideryObject.swift`): reference-informed by Ink/Stitch's "German
  underlay" technique (a real, named professional digitizing technique,
  not this project's invention). `defaultUnderlay` now measures a satin
  object's average rail width and selects `.zigzag` above
  `zigzagUnderlayWidthThresholdMM` (default 4mm) or keeps the existing
  `.centerRun` underlay below it — a single centerline run doesn't
  adequately stabilize a wide column before the satin stitches go down.
  New `UnderlayType.zigzag` case, resamples both rails at
  `zigzagUnderlaySpacingMM` (default 1.2mm) and insets each point toward
  its counterpart rail, alternating rail order each step.
- Automatic fill-angle selection (`FillAngleSelector.swift`, new,
  original work — not an Ink/Stitch technique, which requires an explicit
  manual angle): `fillAngleDegrees` on `StitchGenerationParameters` is now
  `Double?` (nil = automatic). When nil, `TatamiFillGenerator` picks an
  angle perpendicular to the shape's principal (elongation) axis via the
  same PCA machinery already used for satin rails and stitch-type
  classification, instead of every fill always defaulting to a fixed 0°
  regardless of shape — a real, previously undocumented limitation.
- Containment-based object sequencing (`ObjectSequencer.swift`, new):
  before flattening or computing a color sequence, reorders objects so a
  larger object that visually contains a smaller one (by bounding-box
  containment with a 5% area margin against float noise) is always sewn
  first — sewing a background shape after the smaller foreground detail
  it contains would visibly cover that detail. Deliberately conservative:
  only reorders on clear containment, never attempts general jump-
  minimizing routing (see "Known remaining weaknesses" in
  `EMBROIDERY_ALGORITHM_REFERENCE.md` for why a fuller graph-based router,
  informed by Ink/Stitch's `auto_satin.py`, is the top priority next step).
  Wired into both `DigitizePipeline.flatten` and `.colorSequence(for:)` so
  the two stay consistent with each other.
- **Bug fix, found via third-party sample files:** `PESFormat`'s reader
  assumed the embedded PEC block always starts at a fixed byte offset (22),
  which only happened to match this project's own writer output. A real
  `.pes` file from `EmbroidePy/samples` (MIT; vendored as a test fixture
  under `Tests/StitchPilotCoreTests/Fixtures/ThirdPartySamples/`, with its
  license copied alongside it) stores the PEC block's actual location as a
  4-byte little-endian offset at bytes 8-11, with writer-chosen metadata
  in between. The writer now emits a real offset field (pointing
  immediately past itself, since it emits no metadata) and the reader
  follows whatever offset is actually present, with bounds validation. See
  `FORMATS.md`'s PES/PEC section and `ThirdPartySampleTests.swift`, the new
  test file whose `readsRealWorldPESFile` test caught this — a bug that no
  amount of self-authored round-trip testing could have caught, since the
  writer and reader shared the same wrong assumption.

### Known limitations at this stage
- See `EMBROIDERY_ALGORITHM_REFERENCE.md`'s "Known remaining weaknesses"
  and "Recommended next improvements" for the full, prioritized list:
  object sequencing is bounding-box-only (not true polygon containment)
  and doesn't do general jump-minimizing routing; satin's fallback is
  whole-object (no partial/width-aware splitting of a column that's only
  locally too wide); no push compensation yet (only pull); no contour
  fill; small-lettering-specific handling not yet addressed.

## App polish pass (perfecting DST/PES before more format coverage)

### Added
- Hoop profiles (`HoopProfile.swift`, spec §36): a picker in the app plus
  common generic hoop sizes; the canvas draws the hoop boundary (red when
  the design exceeds it, blue otherwise) and `QualityAnalyzer`'s hoop-fit
  check — built earlier but never actually wired to anything in the app —
  now runs against the selected hoop automatically.
- `.stitchpilot` project file (`ProjectFile.swift`, spec §6's "editable
  master format"): every model type was already `Codable`, so this is a
  thin JSON wrapper plus file I/O. Wired into the app as a real macOS File
  menu (Cmd+O for artwork, Cmd+Shift+O for projects, Cmd+S to save) in
  addition to toolbar buttons.
- Fixed a real gap while adding project load: resizing used to depend on
  raw-import state (`lastRawShapes`) that a loaded project doesn't have,
  which would have silently produced an empty document if a user resized
  after opening a project. `applyPhysicalSizeChange` now re-derives from
  the *current* document's own geometry regardless of whether it came from
  an import or a loaded file.
- A real app icon (`Resources/StitchPilot.icns`, generated by
  `Scripts/generate_icon.swift`): a simple original stitch-motif mark
  rather than a generic default, since no external design tools are used
  in this project.
- Verified the full workflow end to end with a new integration test
  (`AppWorkflowIntegrationTests`) mirroring AppState's exact sequence of
  calls: import -> fit/classify/match -> Auto Digitize -> hoop check ->
  save project -> reopen -> resize the *reopened* document -> hoop check
  again (now correctly failing at the larger size) -> export to both
  formats. Also verified `Scripts/build_app_bundle.sh`'s output actually
  launches as a real double-clickable app (via `open`, the same path
  Finder takes) with a visible, correctly-rendered window — confirmed with
  a screenshot of the running app, not just "the process didn't crash."

## Phase 6 — Expanded Format Compatibility (started early)

### Added
- PES/PEC export + independent read-back (`PESFormat.swift`,
  `BrotherThreadPalette.swift`), moved up from Phase 6 because a second
  machine ecosystem (Brother/Baby Lock, alongside Tajima/DST) was judged
  higher-value than continuing further into Phase 3/4 sequencing/quality
  refinements at this point. Writes the "truncated PES version 1"
  structure (signature + stub + embedded PEC block) — a valid,
  machine-sewable file without the larger full-wrapper metadata a
  from-scratch editor would want. Byte layout, the delta-encoding bit
  positions, and the 64-entry Brother thread-index table were verified
  against pyembroidery two ways: reading its source, and calling its
  encoder functions directly on boundary values (0, 62, -63, 63, -64,
  ±2000, flagged jumps) to inspect the actual output bytes — a header
  arithmetic derivation done by eye disagreed with the empirical result
  during development, which is exactly why the empirical check was worth
  doing. Cross-validated against pyembroidery in the test suite
  (`validate_pes.py`), including confirming empirically (via an
  intentionally Y-asymmetric test shape) that PEC needs no Y-axis flip,
  unlike DST. Wired into the app as an Export menu with both DST and PES.
- `DigitizePipeline.colorSequence(for:)`: exposes the color-run sequence
  a document will sew, for format adapters (PES) that need thread color
  and work from `StitchPlan` alone.

### Known limitations at this stage
- Real preview-icon thumbnails aren't rendered — every icon in a PES
  file is the same blank placeholder bitmap (cosmetic only, doesn't
  affect sewing).
- No standalone .pec export (only embedded within .pes) yet.
- JEF, EXP, VP3, XXX, and the rest of spec §5's format list remain
  unimplemented.

## Phase 4 — Quality Engine (started early, alongside Phase 3)

### Added
- Quality analyzer (`QualityAnalyzer.swift`, spec §33/§76): produces a
  0–100 Embroidery Readiness Score plus specific, actionable issues
  (never a vague "density problem" — always the actual numbers involved),
  each tagged info/warning/critical. Checks: sub-minimum or excessive
  stitch lengths that slipped past `StitchFilter`, long jumps, high trim/
  stitch counts, hoop fit (critical if the design doesn't fit a given
  hoop), and empty designs. Runs automatically right after Auto Digitize,
  not as a separate step. Wired into the app: an "Embroidery Readiness"
  panel shows the score and issue list, matching spec §76's "Ready to
  Sew" / "Review Recommended."
- Deliberately not implemented yet (see DIGITIZING_ENGINE.md for why):
  fabric suitability, a real per-region density heatmap, small-text
  detection, and the automatic-repair loop.

## Phase 3 — Professional Digitizing (in progress)

### Added
- Underlay generator (`UnderlayGenerator.swift`): center-run underlay for
  satin (derived from the same two rails `SatinColumnGenerator` sews
  between, so centerline computation can't drift into two different
  answers), edge-run underlay for tatami fill (naive per-vertex polygon
  inset), automatic per-stitch-type defaults with a per-object override.
  Wired into `DigitizePipeline` so underlay sews before an object's main
  stitches. 6 new tests.
- `StitchGenerationParameters` gained `underlayType`, `underlayStitchLengthMM`,
  `underlayInsetMM`.
- `PolygonGeometry` gained shared `pathLength`/`resampleByCount` helpers,
  factored out of `SatinColumnGenerator` so underlay's centerline
  derivation and satin's rail-pairing use the identical resampling logic.

### Added (continued)
- Pull compensation (`PullCompensationCalculator.swift`): a documented
  heuristic (not yet a calibrated physical model — spec §68's future
  calibration system is the intended real fix) that expands satin/fill
  geometry outward before stitch generation to counteract fabric pull.
  Satin widens symmetrically about each crossing's own midpoint (so the
  centerline underlay is generated from stays put); fill offsets its
  outer boundary outward via the same `PolygonGeometry.offsetPolygon`
  underlay's inset uses, just with a negative distance. Automatic by
  default, per-object override via `pullCompensationMM`.
- `PolygonGeometry` gained `offsetPolygon` (signed: positive shrinks,
  negative grows), replacing `UnderlayGenerator`'s private duplicate so
  underlay's inset and pull compensation's outward growth share one
  implementation.

### Added (continued)
- General stitch filtering (`StitchFilter.swift`, spec §30): applied to
  every object's combined (underlay + main) generated points after
  generation, regardless of stitch type — merges sub-minimum-length
  stitches and splits any gap longer than `maxStitchLengthMM`.
  `RunningStitchGenerator`'s previously-private duplicate of the merge
  logic now delegates to this shared version. Centralizing it caught two
  things a per-generator version couldn't: triple-run's exact-duplicate
  turnaround point (now removed for free), and the underlay-to-main-
  stitch transition gap, which only a pass running after concatenation
  can see.

### Added (continued)
- Tie-in/tie-off (`TieStitchGenerator.swift`, spec §27): a short "there and
  back" lock stitch anchors each thread engagement without a visible knot.
  Applied once per color *run* in `DigitizePipeline.flatten` (tie-in on the
  first object of a run, tie-off on the last), not per object — same-color
  objects sewn back to back share one thread and don't need re-anchoring
  between them. Run detection operates on the filtered (non-empty-output)
  object list so a zero-stitch object can't misplace a lock stitch.

### Added (continued)
- Long-jump trim insertion (spec §26): a same-color jump beyond
  `maxJumpWithoutTrimMM` (default 15mm, overridable per call to
  `DigitizePipeline.flatten`) now gets a trim inserted before it, so two
  same-color objects far apart don't carry a visible thread strand
  between them.

### Known limitations at this stage
- Edge-run underlay's polygon inset is a naive per-vertex approximation —
  doesn't handle self-intersection on sharp concave corners.
- Pull compensation is a heuristic, not measured from real sew-outs; not
  yet exposed as an editable value in the app UI.
- Fill's pull compensation doesn't shrink holes to match the outer
  boundary's outward growth.
- No object overlap, hidden travel routing, corner handling, or
  registration-aware color-run reordering yet.

## Phase 2 — Basic Auto Digitizing (complete)

### Added
- Tatami fill generator (`TatamiFillGenerator.swift`): even-odd scanline
  fill with configurable angle/spacing/row-stagger, boustrophedon row
  connection, automatic hole support (holes are just additional sub-paths —
  no special-casing needed). Wired into `DigitizePipeline` for
  `.tatamiFill` objects. 5 new tests including explicit hole-region
  verification.

### Added (continued)
- Satin column generator (`SatinColumnGenerator.swift`): PCA-based
  elongation axis, edge-based (not vertex-based) end-cap detection so
  square-ended rectangles split correctly into two rails, arc-length-
  matched rail resampling, and a hard error (rather than silent bad
  output) when a column exceeds the practical satin width. Two real bugs
  were found and fixed via testing before this worked: farthest-pair-of-
  vertices end detection picks diagonal corners on a rectangle instead of
  its actual ends, and even principal-axis *vertex* extremes tie on a
  rectangle's short side with no vertex at the true end-cap midpoint —
  only cutting at the end-cap *edge* (using its midpoint) is correct. Wired
  into `DigitizePipeline` for `.satin` objects. 4 new tests.

### Added (continued)
- Automatic stitch-type classification (`StitchTypeClassifier.swift`):
  buckets an object into running stitch / satin / tatami fill by estimated
  average width (`area / principal-axis length`). Wired into the app's
  import path, replacing the previous hard-coded `.runningStitch` for
  every imported shape. `PolygonGeometry.swift` factors the shared
  area/PCA math out of `SatinColumnGenerator` for this.

### Added (continued)
- CIE L*a*b* color conversion + Delta-E (`LABColor.swift`), for the
  reason spec §9 requires it: Euclidean RGB distance doesn't track
  perceived color difference.
- Color quantizer (`ColorQuantizer.swift`): deterministic, LAB-space
  k-means with the four presets from spec §8, histogram-bucketed for
  performance. Two real bugs fixed via testing: the histogram's fast
  path was returning bucket-quantization-boundary colors instead of each
  bucket's true average (visibly shifting colors even when no reduction
  was needed), and clustering depended on `Dictionary` iteration order
  for tie-breaking, which produced different results across two calls
  with identical input.
- `ImageImporter` now segments *per quantized color* instead of a single
  foreground/background mask, producing one object per color region with
  its actual color attached. Wired into the app as a "Color Reduction"
  preset picker.
- Found while adding a color-checking test: `CGColor(red:green:blue:alpha:)`
  builds a color in generic calibrated RGB, not a context's actual
  `CGColorSpaceCreateDeviceRGB()` space — filling with it silently shifts
  saturated channels by dozens of units on color-match. Test helpers now
  build colors directly in the context's color space.

### Added (continued)
- Thread library (`ThreadLibrary.swift`): a ~40-entry generic palette
  (original names/values, not sourced from any manufacturer catalog —
  see spec §9's licensing note) plus `nearestMatch`/`nearestMatches`
  Delta-E matching against any palette, so a future manufacturer catalog
  or user "My Thread Inventory" is just a different palette argument, no
  engine change. Wired into the app: artwork colors snap to the nearest
  thread color by default, with a toggle to keep exact artwork colors
  instead; the object list shows each object's matched thread name.

### Known limitations at this stage
- No underlay beneath fill or satin yet (Phase 3).
- Satin end caps always taper to a point (see DIGITIZING_ENGINE.md) —
  correct for pointed ends, an approximation for flat/square ones.
- Stitch-type classification looks only at a shape's outer boundary, not
  its holes, and uses one fixed width threshold rather than considering
  fabric or design size.
- No manufacturer thread catalogs yet, pending license research.

## Phase 1 — Foundation (complete)

### Added
- Project scaffolding: Swift Package Manager workspace (`StitchPilotCore`
  library + `StitchPilotApp` executable + test target), since no full
  Xcode.app is available in the dev environment.
- Neutral internal data model: `Point2D`, `SubPath`, `VectorShape`,
  `BoundingBox` (geometry); `StitchCommand`, `StitchPlan` (flat manufacturing
  output); `ThreadColor`, `RGBColor`; `EmbroideryObject`,
  `StitchGenerationParameters`, `StitchDocument` (object-based master model).
- SVG import: native XML/path parser (`SVGImporter.swift`,
  `SVGPathParser.swift`, `AffineTransform2D.swift`) supporting path
  (M/L/H/V/C/S/Q/T/A/Z, absolute + relative), rect/circle/ellipse/line/
  polygon/polyline, nested `<g>` transforms, viewBox. Curves are flattened
  to polylines at import time rather than rasterized.
- Running-stitch generator (`RunningStitchGenerator.swift`): arc-length
  resampling of a sub-path at a target stitch length, with tiny-stitch
  merging. Triple-run variant.
- Digitize pipeline (`DigitizePipeline.swift`): flattens a `StitchDocument`
  into a `StitchPlan`, with minimal same-color jump / different-color
  trim+colorchange sequencing between objects.
- DST format adapter (`DSTFormat.swift`): writer and independent reader for
  Tajima DST, including the trim "jiggle" convention. Bit layout
  cross-checked against `pyembroidery` (MIT) — see `FORMATS.md`.

- Raster import (`ImageImporter.swift`): background detection (transparency,
  uniform-color, Otsu-threshold fallback), 8-connected component labeling
  with insignificant-speck filtering, Moore-neighbor boundary tracing, and
  Douglas-Peucker simplification — vectorizes a silhouette instead of
  treating every pixel as a stitch.
- SwiftUI app shell (`StitchPilotApp`, `AppState`, `ContentView`,
  `StitchCanvasView`): drag-and-drop or Open-panel import, finished-size
  fields with aspect-ratio lock, Auto Digitize and Export DST toolbar
  actions, an object list, a live stitch/artwork preview canvas, and
  production statistics (stitch count, colors, trims, max stitch length).
  Verified to launch and run without crashing; full interactive/visual
  verification of the native UI needs a human at the keyboard — there is no
  automated way to drive or screenshot a native macOS window in this
  environment (unlike the browser-based tooling used for web UIs).
- `Scripts/build_app_bundle.sh` + `Resources/Info.plist`: packages the SPM
  build product into a normal double-clickable `StitchPilot.app`.
- Integration tests (`ImportToExportIntegrationTests.swift`) exercising the
  full pipeline against real files in `TestArtwork/`, not just in-code
  fixtures.

### Bugs found and fixed during Phase 1 (recorded because they'd otherwise
recur silently)
- **DST cumulative rounding drift:** the writer originally computed each
  stitch's delta from the exact (unquantized) float position of the
  previous stitch, then rounded independently per record. Individual
  rounding remainders don't cancel across many stitches, so a 35mm square
  came back from a round-trip 0.2mm off in width/height — small per
  design, but a real defect that would grow with stitch count. Fixed by
  tracking the running position in *quantized* 0.1mm integer units (each
  absolute target quantized independently, matching what the decoder
  reconstructs) instead of Double millimeters — see the comment in
  `DSTFormat.write`.
- **Inverted raster import:** `ImageImporter` applied a manual
  CGContext flip before drawing a decoded `CGImage`, on the assumption
  (common for hand-rolled bitmap contexts) that a fresh `CGContext` needs
  one. Empirically verified with a throwaway ground-truth probe that
  `CGContext.draw(image:in:)` already places image row 0 at buffer row 0 —
  the manual flip was inverting every raster import vertically. Removed.

### Known limitations at this stage
- Only `.runningStitch` / `.tripleRun` stitch types exist; satin and tatami
  fill throw `unsupportedStitchType` (Phase 2).
- Sequencing is naive (no travel/jump optimization, no registration-aware
  ordering) — Phase 3.
- Only DST export; no other machine formats yet — Phase 6.
- No `.stitchpilot` project file (save/load) yet.
- Raster color is not yet classified per-region (Phase 2 color
  quantization) — every imported raster shape defaults to black thread.

### Environment notes
- No Homebrew, Rust, or cmake in the dev environment; no full Xcode.app,
  Command Line Tools only. Confirmed `swift build`/`swift test` work fully
  under CLT alone, including a SwiftUI `App` target — this is why the
  project has no `.xcodeproj`.
- `pyembroidery` installed locally via `pip3 install --user pyembroidery`
  for test-suite cross-validation only (see `TESTING.md`); not a build or
  runtime dependency.
