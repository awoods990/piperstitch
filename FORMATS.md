# Embroidery File Formats

StitchPilot uses a neutral internal `StitchPlan` (see `ARCHITECTURE.md`);
every machine format is an *adapter* between that and a specific binary
layout, living in `Sources/StitchPilotCore/Formats/`. This document tracks
what's implemented, how each was validated, and known losses/limitations.

## Status

| Format | Ecosystem | Read | Write | Status |
|---|---|---|---|---|
| DST | Tajima / commercial | ✅ | ✅ | Implemented, Phase 1 |
| PES | Brother/Baby Lock | — | — | Planned, Phase 6 |
| JEF | Janome | — | — | Planned, Phase 6 |
| EXP | Melco/Bernina-compatible | — | — | Planned, Phase 6 |
| VP3 | Husqvarna Viking/Pfaff | — | — | Planned, Phase 6 |
| XXX | Singer/Compucon | — | — | Planned, Phase 6 |
| PEC | (Brother, related to PES) | — | — | Planned, Phase 6 |
| U01 | — | — | — | Planned, Phase 6 |
| TBF | Barudan | — | — | Investigate, Phase 6 |
| HUS / VIP / SEW / PCS / SHV / TAP | various | — | — | Investigate, Phase 6 |
| SVG stitch map | — | — | Planned | Phase 5 |
| PNG preview | — | — | Planned | Phase 1 (preview render) |
| PDF production worksheet | — | — | Planned | Phase 5 |
| CSV stitch data | — | — | Planned | Phase 5 |

## DST (Tajima)

**Implemented in:** `DSTFormat.swift`. Both writer and reader.

**Layout:** 512-byte ASCII header (`LA/ST/CO/+X/-X/+Y/-Y/AX/AY/MX/MY/PD`
fields, space-padded, `0x1A` EOF marker at the end of the metadata text)
followed by 3-byte stitch records using the "Tajima ternary" delta encoding
(each axis's magnitude built from weights 81/27/9/3/1, sign-coded, ±121
units = ±12.1mm max delta per record). No native trim command exists in the
byte format; a trim is conventionally signaled by 3 small jump records
summing to zero net movement, which is what most DST-reading software
(including this project's own reader) and machines interpret as an explicit
trim.

**Correctness approach:** the exact bit-weight table and header field
layout were cross-checked against `pyembroidery`'s `DstReader.py` /
`DstWriter.py` (MIT license) rather than reconstructed from memory, since
getting this wrong produces files that *load* but sew incorrectly — exactly
the failure mode spec §59 warns about ("never assume a file is correct
merely because writing completed successfully"). The Swift implementation
here is an independent rewrite (different variable names, different control
flow, and a different internal coordinate-sign convention — see the
"Coordinate convention" note in `DSTFormat.swift`), not a transliteration.

This gives three genuinely independent code paths for validation, exercised
in `TESTING.md`'s round-trip tests: StitchPilot's own writer, StitchPilot's
own reader (used for immediate post-export self-validation, spec §59), and
`pyembroidery`'s independently-implemented reader (used as an external
oracle in the test suite only, never shipped).

**Known limitation:** the trim "jiggle" (3 small jump records, see above)
intentionally moves the needle up to 0.2mm around the final stitch position.
Round-trip validation must compare stitch-only extent, not the full
decoded command list including jumps, or a correct file looks like a
bounding-box regression (see `TESTING.md`).

**Known limitation:** color-change/stop records carry no position delta
(this matches the real format's semantics: DST has no separate concept of
"jump to the new color's start location" bundled into the color-change
byte). The engine is responsible for placing objects so a color change
doesn't imply a position jump the format can't represent — currently true
by construction since `.colorChange` carries no `Point2D`.

## Adding a new format

1. Create `Formats/<Name>Format.swift` with `write(_:designName:) throws -> Data`.
2. If the format's layout can be feasibly decoded, add `read(_:) throws -> DecodedPattern` for round-trip self-validation.
3. Document the layout source and license attribution here, following the DST section's structure.
4. Add round-trip fixtures per `TESTING.md`.

No engine or model changes should be required — if adding a format requires
touching `EmbroideryObject.swift` or `DigitizePipeline.swift`, that's a sign
the format needs a capability (e.g. sequins, a stitch type) the neutral
model doesn't yet represent, which is a separate, deliberate model change.
