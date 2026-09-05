# Testing

## Running the suite

```bash
swift test
```

`StitchPilotCore` has zero UI dependency, so the whole engine is testable
headlessly — no simulator, no display, safe for CI.

## Test framework: Swift Testing, not XCTest

The test target uses **Swift Testing** (`import Testing`, `@Test`,
`#expect`) rather than XCTest. This wasn't a style preference: the Command
Line Tools SDK installed in this dev environment does not include a real
`XCTest.framework` (only a private `XCTestSupport` stub used internally by
the OS) — `import XCTest` fails to resolve without a full Xcode.app
install. `Testing.framework` *is* bundled with Command Line Tools and
`swift test` runs it natively, so that's what the suite is written against.
If this project is later built where full Xcode is available, both
frameworks work fine side by side — there's no need to migrate back.

## Cross-validation against an independent parser

Spec §59/§60 are explicit that a file should never be trusted just because
writing it completed: every exported format must be read back and compared
against the design that was supposed to be exported, ideally through a
parser implementation the writer can't share bugs with.

StitchPilot's DST round-trip tests do this two ways:

1. **In-process, always runs:** `DSTFormat.read` (a second, independently
   written code path in the same file, not a shared helper with the
   writer — see `FORMATS.md`) decodes the just-written `Data` and the test
   asserts the recovered stitch/jump coordinates match the original
   `StitchPlan` within rounding tolerance (±0.05mm, from the 0.1mm native
   unit's rounding).
2. **External oracle, when available:** if `python3 -c "import pyembroidery"`
   succeeds on the machine running the tests, a second test shells out to a
   small Python script (`Tests/Fixtures/validate_dst.py`) that parses the
   exported file with `pyembroidery` — a completely independent
   implementation maintained by a different team — and compares stitch
   count, bounding box, and color-change count. This test is skipped (not
   failed) when `pyembroidery` isn't installed, since it is a development-
   time-only convenience and never a build or runtime requirement of the
   shipped app (see `ARCHITECTURE.md`).

This is why `pyembroidery`'s coordinate-sign convention (Y-up internally,
flipped at its own format boundary) is called out explicitly in
`DSTFormat.swift`: the external-oracle test must negate Y before comparing,
or it would "fail" on a correct file simply because the two projects chose
opposite internal conventions. `PESFormatTests` runs the same
cross-validation (`validate_pes.py`) against PES exports — empirically, PEC
needs no such Y-flip (verified with an intentionally Y-asymmetric test
shape, so a sign error would have shown up as a bounding-box mismatch).

## What "round trip" means here

For a `StitchDocument` → `DigitizePipeline.flatten` → `StitchPlan` →
`DSTFormat.write` → `DSTFormat.read` chain, the test asserts:

- Stitch count matches exactly (no dropped/duplicated stitches)
- Color-change count matches exactly
- Every recovered point matches the original within ±0.05mm (rounding to
  DST's 0.1mm native unit)
- The recovered bounding box matches the `StitchPlan`'s bounding box within
  the same tolerance

Known lossy conversions (e.g. any future format with coarser native
resolution, or one that can't represent trims) are documented per-format in
`FORMATS.md` and the corresponding test asserts the *documented* tolerance,
not exact equality — silently loosening a tolerance to make a test pass
without writing down why is not acceptable.

## Regression/quality benchmarks (Phase 4+)

Spec §67 calls for a synthetic test-artwork library (simple logo, tiny
lettering, narrow columns, gradients, photograph, cap design, etc.,
generated programmatically to avoid copyright concerns) with recorded
quality-engine metrics (stitch count, trims, jumps, density violations,
Embroidery Readiness Score) as a regression baseline. This lands alongside
the quality engine in Phase 4 — tracked here so it isn't forgotten, not
implemented yet.

## Test fixtures

`Tests/StitchPilotCoreTests/Fixtures/` holds small synthetic SVG/artwork
inputs used by the tests. Fixtures are generated/authored directly (simple
geometric shapes), not sourced from third-party artwork, to keep the test
suite license-clean.
