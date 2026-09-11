# PiperStitch

*Turn any image into embroidery.* Fast, easy, affordable — professional
automatic embroidery digitizing software for macOS (Apple Silicon).

PiperStitch converts ordinary image and vector artwork into machine-ready
embroidery designs by making the same technical decisions an experienced
human digitizer would: it segments artwork into objects, chooses a stitch
technique per object, generates underlay and compensation, sequences the
sew-out, simulates the result, and audits the output for real embroidery
problems — rather than tracing pixels into stitches. Drop in artwork, click
**Create Embroidery File**, and it does the rest.

> **Status:** early development (Phase 1 of the roadmap in `ARCHITECTURE.md`).
> Not yet a finished product. See `CHANGELOG.md` for what actually works today.

"PiperStitch" is a working product name (the project was built and is still
documented throughout under its original working name, StitchPilot, and was
briefly rebranded "OneClickStitch" before this — see ARCHITECTURE.md →
"Branding"); the name is kept out of core logic so it can change again later
without a rewrite.

## What it does (target — see CHANGELOG.md for current state)

Open an image or vector file → set the finished size, fabric, and machine →
click **Create Embroidery File** → get a realistic stitch preview, an
automatic quality audit, and the embroidery format your machine reads
(DST, PES, JEF, EXP, VP3, XXX, and more) — in one click.

## Documentation

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — system design, module boundaries, the internal data model, the auto-digitize pipeline, and third-party dependencies + licenses.
- [`DIGITIZING_ENGINE.md`](DIGITIZING_ENGINE.md) — how the engine actually digitizes: stitch-type selection, density, underlay, compensation, sequencing, quality scoring.
- [`FORMATS.md`](FORMATS.md) — every supported embroidery file format, what PiperStitch can read/write, and known format-specific limitations.
- [`TESTING.md`](TESTING.md) — how the automated test suite works, including cross-validation against an independent embroidery library.
- [`CHANGELOG.md`](CHANGELOG.md) — what's actually implemented, phase by phase.
- [`LICENSING.md`](LICENSING.md) — the subscription model: the in-app trial and sign-in, the `license-admin/` service, and the `website/` download gate and subscribe form.

## Building from source

Requires macOS 13+ on Apple Silicon and Xcode Command Line Tools (`xcode-select --install`) — a full Xcode.app install is *not* required; the project builds with Swift Package Manager.

```bash
swift build -c release
swift test
```

To run the app during development:

```bash
swift run StitchPilot
```

There is no Python, Homebrew, or Rust dependency for building or running the
shipped app — the entire product is Swift. (A locally-installed Python +
`pyembroidery` is used *only* by the test suite, as an independent oracle to
cross-check exported files; see `TESTING.md`. It is never required to build
or run StitchPilot itself.)
