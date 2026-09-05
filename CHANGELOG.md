# Changelog

All notable progress is recorded here, grouped by the phase plan in
`ARCHITECTURE.md`. This file is the source of truth for "what actually
works" — `README.md`'s feature list is aspirational/target state.

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

### Known limitations at this stage
- Edge-run underlay's polygon inset is a naive per-vertex approximation —
  doesn't handle self-intersection on sharp concave corners.
- Pull compensation is a heuristic, not measured from real sew-outs; not
  yet exposed as an editable value in the app UI.
- Fill's pull compensation doesn't shrink holes to match the outer
  boundary's outward growth.
- No object overlap, travel routing, jump/trim optimization, tie-in/
  tie-off, or general stitch filtering yet.

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
