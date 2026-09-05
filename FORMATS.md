# Embroidery File Formats

StitchPilot uses a neutral internal `StitchPlan` (see `ARCHITECTURE.md`);
every machine format is an *adapter* between that and a specific binary
layout, living in `Sources/StitchPilotCore/Formats/`. This document tracks
what's implemented, how each was validated, and known losses/limitations.

## Status

| Format | Ecosystem | Read | Write | Status |
|---|---|---|---|---|
| DST | Tajima / commercial | ✅ | ✅ | Implemented, Phase 1 |
| PES | Brother/Baby Lock | ✅ | ✅ | Implemented, Phase 3 (moved up from Phase 6) |
| JEF | Janome | — | — | Planned, Phase 6 |
| EXP | Melco/Bernina-compatible | — | — | Planned, Phase 6 |
| VP3 | Husqvarna Viking/Pfaff | — | — | Planned, Phase 6 |
| XXX | Singer/Compucon | — | — | Planned, Phase 6 |
| PEC | (Brother, embedded in PES) | ✅ | ✅ | Implemented as part of PES (see below); not offered as a standalone .pec export yet |
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

## PES / PEC (Brother, Baby Lock)

**Implemented in:** `PESFormat.swift` (writer + reader) and
`BrotherThreadPalette.swift` (the format's fixed 64-entry thread-color
table). PES's actual general structure is: an 8-byte `#PES0001` signature,
a 4-byte little-endian offset pointing to wherever the embedded PEC block
actually starts, then however much version-specific metadata (embedded
thread-chart/sewing-segment descriptions design software uses for
re-editing, not something a machine needs to sew) the writer chose to put
before it, then the PEC block at the recorded offset. This writer emits no
metadata at all — the offset always points immediately past itself — which
is a legitimate minimal use of the mechanism (several other embroidery
tools produce similarly minimal PES files), not a different, non-standard
format. The reader follows the offset rather than assuming a fixed
position, specifically because an earlier version hard-coded offset 22
(matching only this writer's own minimal output) and silently mis-parsed a
real-world PES file from another project as a result — see "Known
limitation" below and `TESTING.md`.

**Layout:** the 8-byte signature and 4-byte offset above, then (at that
offset) a fixed 512-byte PEC header (`LA:` name field, an icon-size stub, a
thread-count byte followed by that many Brother palette indices, padded to
exactly 512 bytes total regardless of thread count), a stitch block (a
3-byte little-endian length prefix, a fixed marker, width/height, then the
encoded stitches), and finally one blank 228-byte placeholder icon per
color (real thumbnail rendering is cosmetic only and out of scope — every
icon is the same blank bitmap). Stitch deltas use a different scheme than
DST's ternary encoding: a value fits in a single byte when it's in
-63...62, otherwise it's a 12-bit two's-complement value split across 2
bytes with flag bits (jump/trim) folded into the otherwise-unused high
nibble of the first byte. Unlike DST, PEC has *no* separate bare trim
record — trimming is a flag on the jump that follows it, and (per the
reference implementation's verified behavior) every jump except the very
first movement in the design is treated as an implicit trim+jump.

**Correctness approach:** the exact byte layout, thread-index table, and
delta-encoding bit positions were verified two ways before writing any
Swift: by reading `PecWriter.py`/`PecReader.py`/`EmbThreadPec.py`
(pyembroidery, MIT license), and by calling pyembroidery's own encode
functions directly with boundary values (0, 62, -63, 63, -64, 2000, -2000,
flagged jumps) and inspecting the raw output bytes — plus generating a real
`.pes` file and inspecting its actual byte offsets — rather than trusting a
derivation-by-eye of the header arithmetic, which turned out to disagree
with the empirical result during development. The 64-entry Brother thread
table is factual interoperability data (index -> RGB -> name for a
commercial format), the same category as DST's byte layout, not creative
expression.

**Known limitation:** a defensive zero-delta "closing" stitch is inserted
after every run of jumps before the next real stitch or color change,
matching verified reference behavior. This is behaviorally invisible on
real hardware (a zero-movement stitch is one needle penetration exactly
where the needle already is) but means the *decoded* stitch count can
exceed the StitchPlan's own count — round-trip tests compare "every
original point appears in order in the decoded output," not raw counts,
for exactly this reason (see `TESTING.md`).

**Known limitation:** thread colors are matched to the nearest of Brother's
64 fixed palette entries by Delta-E (reusing the same `RGBColor.deltaE`
infrastructure as `ThreadLibrary`), since PES/PEC references colors by
index into that table rather than storing arbitrary RGB directly.

## Adding a new format

1. Create `Formats/<Name>Format.swift` with `write(_:designName:) throws -> Data`.
2. If the format's layout can be feasibly decoded, add `read(_:) throws -> DecodedPattern` for round-trip self-validation.
3. Document the layout source and license attribution here, following the DST section's structure.
4. Add round-trip fixtures per `TESTING.md`.

No engine or model changes should be required — if adding a format requires
touching `EmbroideryObject.swift` or `DigitizePipeline.swift`, that's a sign
the format needs a capability (e.g. sequins, a stitch type) the neutral
model doesn't yet represent, which is a separate, deliberate model change.
