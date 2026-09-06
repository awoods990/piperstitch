# Changelog

All notable progress is recorded here, grouped by the phase plan in
`ARCHITECTURE.md`. This file is the source of truth for "what actually
works" — `README.md`'s feature list is aspirational/target state.

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
