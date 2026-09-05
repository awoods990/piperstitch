# Changelog

All notable progress is recorded here, grouped by the phase plan in
`ARCHITECTURE.md`. This file is the source of truth for "what actually
works" — `README.md`'s feature list is aspirational/target state.

## Phase 1 — Foundation (in progress)

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
