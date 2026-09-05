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

## Phase 2 — planned next

- Background/foreground detection and removal for raster input
- Color quantization with the four presets in spec §8
- Object segmentation (connected components + contour tracing → vector regions)
- Satin-column detection and generation (centerline/rails, width-adaptive)
- Tatami fill generation (spacing, angle, row stagger)
- Automatic stitch-type selection per object (running vs. satin vs. fill)
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
