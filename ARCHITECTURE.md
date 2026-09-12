# StitchPilot Architecture

## Guiding principle

> The source image describes what the customer wants to see. The embroidery
> design describes how the machine must sew to create it. Those are
> fundamentally different representations.

Every module boundary in this codebase exists to keep those two
representations separate and to make the *translation* between them — the
actual digitizing intelligence — an explicit, inspectable, testable pipeline
rather than a single black-box "image to stitches" function.

## Environment this project targets

Developed and built on macOS 15 (Apple Silicon), with **Xcode Command Line
Tools only** — no full Xcode.app, no Homebrew, no Rust/cmake toolchain
installed. This shaped a real architectural decision (see "Why pure Swift"
below): the project must build and run with nothing beyond what CLT
provides, using Swift Package Manager instead of an `.xcodeproj`.

## Why pure Swift (engine + UI), no C++/Rust/Python

The spec allows the computational engine to be Python, C++, Rust, or Swift.
Given the actual constraints of this build:

- **No Python at runtime, ever** (spec §3: normal users must never need
  Python/Terminal/Homebrew). Embedding a Python interpreter (PythonKit or
  similar) to reuse `pyembroidery` directly would violate that and adds
  substantial packaging complexity for a "normal Mac app."
- **The two realistic open-source format libraries have real drawbacks for
  direct use as a runtime dependency:**
  - `pyembroidery` (MIT) — Python, excluded for the reason above.
  - `libembroidery` (zlib/libpng license, very permissive) — C, but tagged
    `v1.0-alpha, under construction` upstream. Taking a hard dependency on
    an explicitly-alpha C library for the most safety-critical part of the
    app (writing files a physical machine will execute) was judged too
    risky, especially with no `cmake` available to build it in its native
    way (it *could* be vendored as raw `.c` files into an SPM C target, but
    that still means shipping alpha code as the trust boundary for machine
    safety).
  - Ink/Stitch is GPL-3.0 — copyleft, not usable as an embedded dependency
    in a closed-source product without relicensing implications.
- **No Rust/cmake toolchain is installed**, and installing one would need
  Homebrew (itself not installed) or a manual download — avoidable
  complexity when Swift alone is sufficient.
- Swift Package Manager alone (verified against this environment) can build
  a windowed SwiftUI `App` target with nothing but Command Line Tools, has
  full Accelerate/Metal access for later performance work, and keeps the
  entire codebase in one language with no FFI boundary to maintain.

**Decision:** StitchPilot's engine and UI are 100% Swift, built via SPM.
Machine-format encoders/decoders (starting with DST) are **native Swift
implementations**, not vendored C/Python code. Where a format's binary
layout is safety-critical and non-obvious (e.g. DST's Tajima ternary delta
encoding), the exact bit layout was cross-checked against `pyembroidery`'s
source (MIT-licensed, permits this) rather than reconstructed from memory —
see `FORMATS.md` for the attribution this requires per-format, and
`TESTING.md` for how a locally-installed `pyembroidery` is used as an
independent development-time oracle to validate every exported file, without
ever being a runtime dependency of the shipped app.

This decision is revisited per format in Phase 6 if a format's complexity
makes a native reimplementation impractical — the format-adapter boundary
(see below) is designed so that decision can be made per-format without
touching the engine.

## Branding

The product has been renamed twice without ever touching engine, model, or
format code — exactly the outcome this section originally described as the
point of keeping the name out of core logic: from its original working name
"StitchPilot" to "OneClickStitch", and then from "OneClickStitch" to
"PiperStitch" (real brand assets — a sandpiper carrying a loop of thread —
supplied as `Logo/Primary Logo.png` for the wordmark and `Logo/Favicon.png`
for the square icon mark; `Logo/First Logo.png` is an alternate
illustration-style mark kept as a source asset but not used in the app).
Concretely, what
did and didn't change, both times:

- **Changed:** `Resources/Info.plist` (`CFBundleName`/`CFBundleDisplayName`/
  `CFBundleIdentifier`/`CFBundleIconFile`, and — second rename only — the
  `com.oneclickstitch.*` UTI identifier prefix to `com.piperstitch.*`; the
  `stitchpilot` project-file extension itself was deliberately left alone,
  see below), the SwiftUI `WindowGroup` title, `Scripts/build_app_bundle.sh`'s
  output bundle name, the app icon (`Resources/PiperStitch.icns`, generated
  from the real brand assets in `Resources/Branding/` — see below — replacing
  the prior rebrand's icon), an in-app brand mark image bundled as an SPM
  resource for `StitchPilotApp` (`Sources/StitchPilotApp/Resources/`, loaded
  via `Bundle.module`), and user-facing documentation.
- **Deliberately left unchanged:** `Package.swift`'s package/target/product
  names (`StitchPilot`, `StitchPilotCore`, `StitchPilotApp`), Swift type
  names (`StitchPilotApp` the `App` struct), module import statements, the
  actual compiled binary's filename inside the bundle
  (`Contents/MacOS/StitchPilot`, referenced by `CFBundleExecutable`), and the
  `.stitchpilot` project-file extension. These are internal identifiers with
  zero user-visible surface — nothing outside the source tree and this doc
  ever sees them, and an existing `.stitchpilot` file on someone's disk
  shouldn't stop opening just because the app's own name changed again — so
  renaming them would be pure mechanical churn (or, for the file extension,
  actively user-hostile) for no visible benefit. `CFBundleDisplayName` (what
  Finder, the Dock, and the menu bar actually show) is what carries the
  product's real name to the user, independent of both the binary's own
  filename and the project file's extension — a normal, common pattern.

No engine, model, or format code references the product name. Renaming the
product again later is the same find/replace of display strings and
resources described above, not an architecture change.

## Units

**Millimeters** are the canonical unit everywhere in the internal model
(`Point2D`, `BoundingBox`, `StitchGenerationParameters`, physical document
size). Pixels only exist transiently during raster import; SVG user-space
units only exist transiently during vector import (see `Import/`). Machine
formats convert to their native unit (e.g. DST = 0.1mm) only at the format
adapter boundary, never earlier.

**Coordinate convention:** Y increases *downward* (SVG/bitmap convention),
chosen because both raster and SVG import land in that space naturally.
Format adapters are responsible for any sign flip their target format's
native convention requires — see the coordinate-convention note in
`DSTFormat.swift`.

## Data model (`StitchPilotCore/Model`)

Two representations, deliberately kept distinct:

1. **`StitchDocument`** (`EmbroideryObject.swift`) — the editable master
   representation, and eventually the `.stitchpilot` project file's schema
   (spec §6). A `StitchDocument` is a physical size (mm) plus an ordered
   list of `EmbroideryObject`s. Each object owns *its own* shape geometry,
   stitch type, thread color, and generation parameters — there is
   deliberately no global density/underlay/angle; every professional
   digitizing decision is per-object (spec §10, §14: "Density must not
   simply be one global constant").

2. **`StitchPlan`** (`Stitch.swift`) — the flat, ordered manufacturing
   output: exactly the sequence of needle-down stitches, jumps, color
   changes, and trims a machine will execute. This is *generated from* a
   `StitchDocument` by the engine (`DigitizePipeline.flatten`); it is never
   hand-authored and never the source of truth. Every machine format writer
   consumes a `StitchPlan`, not a `StitchDocument` — format adapters know
   nothing about objects, thread-matching, or digitizing decisions.

Geometry (`Geometry.swift`) represents curves as flattened polylines
(`SubPath`/`VectorShape`) rather than rasterizing artwork to pixels — vector
precision is preserved through import, just expressed piecewise-linearly so
every downstream algorithm (resampling, offsetting, satin-rail generation)
works with plain line segments instead of re-deriving curve math throughout
the engine.

## The auto-digitize pipeline

The full pipeline (target — see `CHANGELOG.md` for what's implemented today)
is a sequence of independent, individually testable modules, not one
function:

```
Artwork Import → Normalize → Background Analysis → Color Analysis →
Object Segmentation → Geometry Cleanup → Physical-Size Analysis →
Stitchability Analysis → Object Classification → Thread Mapping →
Stitch-Type Selection → Stitch-Angle Selection → Underlay Generation →
Pull/Push Compensation → Overlap Calculation → Object Sequencing →
Travel Optimization → Stitch Generation → Stitch Filtering →
Density Analysis → Machine-Limit Validation → Quality Analysis →
Automatic Repair → Re-analysis → Realistic Simulation →
Export Adaptation → Machine File Generation → Read-Back Validation
```

Phase 1 implements a minimal vertical slice through this pipeline (import →
object model → running-stitch generation → sequencing → DST export →
independent read-back validation) so every later phase adds a real module to
a working end-to-end path, rather than building every stage as a stub
simultaneously.

## Module layout

```
Sources/StitchPilotCore/       Swift library — the engine, no UI dependency
  Model/                       StitchDocument, EmbroideryObject, StitchPlan, ThreadColor, Geometry
  Import/                      SVG (native XML/path parser) and raster importers
  Engine/                      Stitch generators + the digitize pipeline
  Formats/                     One file per machine format; each is an adapter
                                consuming/producing StitchPlan + metadata only
Sources/StitchPilotApp/        SwiftUI app (thin — delegates to StitchPilotCore)
Sources/DigitizeCLI/           No-GUI harness around the same pipeline (diagnostics)
Tests/StitchPilotCoreTests/    Unit + round-trip + cross-validation tests
server/                        Web edition: Vapor HTTP API around StitchPilotCore (Linux)
web/                           Web edition: the browser app (React + TypeScript)
```

`StitchPilotCore` has no dependency on AppKit/SwiftUI and can be fully unit
tested headlessly (`swift test`), including on CI with no display attached.

## The web edition (`server/` + `web/`)

PiperStitch launches first as a browser app, with the Mac app kept fully
intact for a later release. Both are the *same engine*: `server/` is a
separate SwiftPM package that depends on this one by path and wraps
`DigitizePipeline` and friends in a small, stateless JSON API (Vapor),
built for Linux in Docker; `web/` is the browser UI that drives it. The
root package, and the Mac app inside it, are not modified for the web's
sake — the server is a *sibling* of `StitchPilotApp`, not a fork of it.

What made this cheap: the engine was already platform-neutral apart from
four files, each of which now compiles its Apple-framework code under
`#if canImport(...)` so the Mac build is byte-identical and Linux skips
it:

| File | Apple dependency | Web edition instead |
|---|---|---|
| `Import/ImageImporter` | ImageIO decodes the file | The browser decodes and downsizes; the server receives straight RGBA via the platform-neutral `importShapes(rgba:width:height:)` — every step after decoding is the same code |
| `Rendering/StitchRenderer` | CoreGraphics draws the preview | The browser draws the plan on a `<canvas>` with the same thread-width/shade technique (`web/src/render.ts`) |
| `Engine/LetteringGenerator` | CoreText glyph outlines | Not yet on the web (planned: outlines from the browser, submitted as shapes) |
| `Engine/TextDetector` | Vision OCR | Not yet on the web (returns no regions on Linux) |

The `Licensing/` client is desktop-only and is likewise skipped on Linux.

The browser holds the document (all model types are `Codable`, so
`StitchDocument` crosses the wire as JSON) and the server keeps nothing
between requests, mirroring `AppState`'s lifecycle as endpoints:
`import/raster` or `import/svg` (→ source shapes + a recommended size),
`build` (`regenerateFromStoredGeometry`), `resize`
(`applyPhysicalSizeChange`), `digitize` (`flattenWithColors` +
`QualityAnalyzer`), `export/{dst,pes,jef,exp,vp3}`, and `catalog` (the
UI's pick-lists straight from the engine's tables). A full digitize is
~0.4 s, so only re-digitizing actions round-trip; pan/zoom/select are
local. Engine improvements land in `StitchPilotCore` once and reach both
editions. See `server/README.md` and `web/README.md` to run them.

## Format adapters

Every machine format lives in its own file under `Formats/`, consuming a
`StitchPlan` (plus a small metadata struct: design name, thread list) and
producing `Data`, and — where practical — the reverse (`Data -> StitchPlan`)
for read-back validation and for importing existing embroidery files (spec
§40). New formats are added by writing a new adapter; they never require
engine changes. See `FORMATS.md` for the status of each format.

## Distribution

No Xcode.app is available in this environment, so there is no `.xcodeproj`.
The app is built with `swift build -c release` and packaged into a normal
`.app` bundle by `Scripts/build_app_bundle.sh`, so end users never see Swift
Package Manager, Terminal, or source code — see spec §3. Opening
`Package.swift` in Xcode (when available) also works directly, with no
`.xcodeproj` generation step needed, for anyone who wants to develop this in
the Xcode IDE later.

Verified end to end: `Scripts/build_app_bundle.sh` produces `PiperStitch.app`
that launches via `open` (the same path double-clicking in Finder takes) as a
real, independent process — confirmed via `System Events` recognizing it as
a running application and the system log showing AppKit actually creating
and ordering its window to the front, plus a direct screenshot of the
running window's content. The bundle carries a real icon
(`Resources/PiperStitch.icns`, generated from the actual brand assets —
see "Branding" above — rather than shipping with a generic default).

## Third-party dependencies

**Runtime dependencies of the shipped app: none.** Everything PiperStitch
ships with is Swift + Apple system frameworks (Foundation, SwiftUI,
CoreGraphics, Accelerate).

**Development/test-time only:**

| Dependency | License | Used for | Ships in app? |
|---|---|---|---|
| Python 3 (system) + `pyembroidery` | MIT | Independent DST/format cross-validation oracle in the test suite (`TESTING.md`) | No |

**Reference-only (no code vendored, format layouts cross-checked against source for correctness, per-format attribution in `FORMATS.md`):**

| Project | License | Role |
|---|---|---|
| [pyembroidery](https://github.com/EmbroidePy/pyembroidery) | MIT | Reference for exact binary layouts of DST and PES/PEC (implemented); JEF/EXP/VP3/XXX/U01 (later) |
| [libembroidery](https://github.com/Embroidermodder/libembroidery) | zlib/libpng | Cross-reference for format coverage/edge cases; not vendored (alpha status, see above) |
| [Ink/Stitch](https://github.com/inkstitch/inkstitch) | GPL-3.0 | Read-only reference for digitizing *algorithms/ideas* (satin/fill heuristics) — no code viewed-and-copied; GPL code is never vendored into this codebase |

## Roadmap

See spec §69 for the full 7-phase plan; `CHANGELOG.md` tracks actual
progress against it phase by phase.
