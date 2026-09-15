# Wilcom EmbroideryStudio Reference Manual — review against the PiperStitch engine

Source: `TestArtwork/Reference Manuals General/Wilcom Reference Manual.pdf`
(EmbroideryStudio 2025, 1,549 pages). Reviewed 2026-09-15. Chapters read:
Stitch Types (p219–243), Digitizing Shapes (p244–277), Working with
fabrics (p285–291), Sequencing (p334–343), Embroidery Reinforcement
(p409–432), Stitch Quality (p433–457), Connectors (p458–483), Lettering
(p825–893), Automatic Digitizing (p1040–1062), Start & end points (p1102–1106).

This is a *rules* document, not a code copy: Wilcom is proprietary, and
nothing here reproduces its implementation — only the industry practice
its manual documents (numbers, thresholds, when-to-use-what), which is
common knowledge among digitizers. Compare `EMBROIDERY_ALGORITHM_REFERENCE.md`
for the open-source engines studied earlier.

Each item: **what the manual says → what the engine does today → gap →
recommendation**. Priority is by expected sew-out impact per hour of work.

---

## A. Rules the engine is missing (highest impact)

### A1. Visible-connector rule: anything longer than ~3 mm must be trimmed or buried
- **Manual (p465):** "Usually, connectors shorter than 3 mm are not visible on the final embroidery." Trim, or cover with later stitching, anything longer. Trim-after thresholds are a per-object property ("trim if next connector > N").
- **Engine:** `DigitizePipeline.defaultMaxJumpWithoutTrimMM = 15.0`. A same-color jump under 15 mm is emitted as a plain jump (thread carried on the surface) and `HiddenTravelRouter` only fires *above* that threshold, on the assumption the short carry "ends up buried just the same once something covers it" — which is only true if something later actually covers it.
- **Gap:** a 4–15 mm same-color carry with nothing sewn over it afterwards is a loose thread on top of the finished piece. This is the single most common "looks amateur" defect in auto-digitized output.
- **Recommend:** lower the trim threshold to **3 mm** for uncovered gaps; for gaps 3–15 mm, first try `HiddenTravelRouter` (bury under later coverage), then trim. Add a `QualityAnalyzer` check: "N uncovered connectors between 3 mm and 15 mm". ~½ day, mostly tests.

### A2. Satin auto-spacing by column width
- **Manual (p224–228):** density is not a constant. Narrow columns get *wider* spacing ("in narrow columns, stitch density may be too great and needle penetrations damage the fabric"); wide columns get tighter spacing so long stitches still cover. Auto Spacing is a length→spacing table (spacing increases as stitch length decreases). "75% [of preset] generally produces high quality embroidery."
- **Engine:** `satinDensityMM = 0.32` flat, modulated only by curvature (`curvatureDensityWeight`). Width has no effect.
- **Gap:** small lettering (<2 mm columns) is over-dense — thread breaks and a hard, raised feel; 8–12 mm columns are under-covered.
- **Recommend:** `SatinColumnGenerator`: spacing = f(local column width) via a 3–4 point table, e.g. width ≤1.5 mm → 0.45 mm, 3 mm → 0.38, 6 mm → 0.32, ≥10 mm → 0.28, interpolated, then curvature weighting on top. Expose as `autoSpacing: Bool` (default on) so `satinDensityMM` remains the override. ~1 day incl. tests + DigitizeCLI corpus check.

### A3. Inside-edge bunching on curves: fractional spacing + stitch shortening
- **Manual (p446–451):** standard spacing is measured at the *outside* edge of a curve, so the inside edge bunches (thread breaks, hard spots). Fixes: **Fractional Spacing** (measure spacing at an offset fraction across the column — 0.33 fewer stitches, 0.66 no inside bunching) and **Stitch Shortening** (when inside spacing drops below 40–90 % of nominal, shorten up to 5 consecutive stitches to 55–90 % of full length, in a jagged/randomised pattern so no line forms).
- **Engine:** the opposite lever only — curvature *adds* crossings (`curvatureDensityWeight = 3.0`) to keep the outside covered, which makes inside-edge bunching worse on tight bends.
- **Gap:** tight curves in satin (the bowl of a "B", a script font) pile up on the inside.
- **Recommend:** compute spacing at an offset fraction (default 0.33) instead of the outer rail, and add stitch shortening: on any crossing where inside-edge spacing < 60 % of nominal, pull alternating penetrations back toward the outside rail by 70–90 % in a `[80], [85,70], [70,90,70] …` pattern. Rerun the sew-out that motivated curvature weighting to confirm outside coverage holds. ~1.5 days.

### A4. Corner handling for satin columns (mitre / cap / lap)
- **Manual (p439–447):** sharp corners in satin columns bunch and can damage needle/fabric. Three techniques by corner angle: **mitre** below ~45° (two segments meeting on a sharp line, overlap 0.5–1.5 mm), **cap** below ~20–30° (an extra segment whose stitches stay parallel to the column, fewer stitches), **lap** below ~110° (Tidori-style overlapped segments). "Round sharp corners" as an alternative.
- **Engine:** squared end caps only (`squareCapMinEdgeLengthMM`); a column that *turns* a sharp corner is railed straight through it, and stitches fan around the vertex.
- **Gap:** satin borders/frames, block letters' corners (E, F, L, T) and any polygonal satin outline.
- **Recommend:** in `SatinColumnGenerator.computeRails`, detect rail vertices where the direction changes by more than a threshold; split the column there; for < 45° mitre the two segments with a 1 mm overlap, for < 25° cap with an extra parallel segment. Needs `StrokeTopologyAnalyzer`'s junction work as a base. ~2–3 days; big visible win on lettering.

### A5. Lettering underlay by letter height
- **Manual (p891):** "Lettering with heights under 5 mm should not have underlay. Letters 6–10 mm can have a center-run underlay. Larger than 10 mm: edge-run. Jacket-back letters: a second layer, double-zigzag for loft." Lettering underlay is applied **by shape** (whole letter), not per segment — fewer travel runs, less bunching, lower stitch count.
- **Engine:** `UnderlayGenerator.defaultUnderlay` picks by stitch type and column width only; lettering (`LetteringGenerator`) has no height rule; every satin gets center-run regardless of size.
- **Gap:** small text is stiffened and over-stitched by an underlay that's doing nothing.
- **Recommend:** pass cap height (already known to `LetteringGenerator`) into the underlay decision: < 5 mm → none; 5–10 mm → center run; > 10 mm → edge run; > 25 mm → edge run + zigzag. Apply the same *width-based* equivalent to raster-imported shapes (column width < ~1.5 mm → none). ~½ day.

### A6. Auto-split long satin stitches instead of falling to tatami
- **Manual (p451–454):** wide columns keep the satin look by **splitting** each long stitch into ≤ 7 mm pieces with the penetration points **randomised** so they don't form a line down the middle ("looks more satin-like and works well with turning stitches… tatami is flat and can show unwanted patterns with tight curves"). Min split length 0.4 mm.
- **Engine:** width > `maxSatinWidthMM` (12 mm) → width-aware section split, else tatami fallback; `StitchFilter.splitLongStitches` splits evenly (so it *does* form a line).
- **Gap:** wide letters and shapes that should read as glossy satin come out flat and textured.
- **Recommend:** `SatinColumnGenerator` option `autoSplit` (default on above 7 mm): split crossings > 7 mm at a randomised fraction (seeded per object for reproducibility), keep classification satin up to ~20 mm before falling to fill. `StitchFilter.splitLongStitches` should jitter its split points too. ~1 day.

### A7. Second underlay layer and underlay angle for large fills on soft fabrics
- **Manual (p412–418):** large fills: **edge run + tatami underlay** (open rows, spacing 2–3 mm, angle counter to the cover stitching); very soft/elastic fabric: **double tatami** at ±45° for a cross-hatch; wide satin: edge/center run + zigzag, or double zigzag. Underlay margin (inset) ≈ 0.8 mm typical.
- **Engine:** one underlay per object; `.edgeRun` for tatami fill (no tatami underlay type); zigzag for satin only above 4 mm; a single `underlayInsetMM`.
- **Gap:** large fills on knits/fleece/beanies pucker; there is no cross-hatch option for the fabrics we now list as "challenging".
- **Recommend:** add `UnderlayType.tatami` (open rows at `fillAngle + 90°`, 3 mm spacing, 4 mm length) and a second-underlay slot in `StitchGenerationParameters` (`secondUnderlay: UnderlayType?`); default by fabric: stable → edge run; knit/stretch/beanie/terry → edge run + tatami (double tatami for stretch/beanie); satin > 6 mm on knit → zigzag + center run. ~1.5 days.

## B. Rules the engine partly has — tune to the manual's numbers

### B1. Pull compensation table
- **Manual (p429):** drills/cotton **0.20 mm**, T-shirt **0.35**, fleece/jumper **0.40**, lettering **0.2–0.3**. Fabric presets carry Low/Medium/High (denim / silk / terry).
- **Engine:** heuristic `0.15 + densityFactor` scaled by `widthFactor` and fabric multiplier, capped 0.6 (hard 1.0). Roughly the right band, but lettering isn't special-cased and multipliers are guesses.
- **Recommend:** re-base so the *standard-fabric, mid-width satin* result lands at 0.20–0.25 mm, T-shirt (knit ×1.3) ≈ 0.35, fleece/terry ≈ 0.40; clamp lettering to 0.2–0.3 regardless. Then keep the calibration-sheet plan (measure, don't guess). ~2 hours + sew-out.

### B2. Tie-in / tie-off methods
- **Manual (p462–466):** tie-in *on the second stitch inside the shape*; tie-off methods: (1) small stitches between the last two stitch lines — dense fills; (2) up-and-back on the last line — open fills, small objects; (3) split the second-last line in three. "For narrow shapes or columns – e.g. small lettering – use only one tie-off stitch," default two. Tie-in only *after a trim or colour change*, not on every object.
- **Engine:** `TieStitchGenerator` one method, fixed 0.5 mm lock stitches, applied to every object.
- **Recommend:** tie-in only when the preceding connector was trimmed; tie-off count 1 for columns < 2 mm; method (1) for fills, (2) for satin. ~½ day.

### B3. Travel-run length under cover
- **Manual (p469):** travel runs inside objects use a **short** stitch (1–3 mm; shorter follows curves and stays hidden under cover) and vary automatically on tight curves.
- **Engine:** buried travel uses the object's `stitchLengthMM` (3 mm) or underlay length. Fine for straight paths; too long on curves, where it can peek out.
- **Recommend:** 1.5–2 mm for buried travel, variable on curves (see B5). Trivial.

### B4. Small-stitch filter
- **Manual (p438):** remove stitches below a minimum (0.4 mm is the working default across tatami/satin dialogs); applied continuously or on output.
- **Engine:** `StitchFilter` min 0.4 (`minStitchLengthMM`), max 12 — matches. **No change**, but see A6 for the split jitter.

### B5. Variable run length (chord gap) on curves
- **Manual (p221–222):** run stitches follow tight curves by shortening automatically: nominal length (e.g. 2.5–3 mm), **min length**, and a **chord gap** (max distance between the digitized curve and the stitch, default 0.07 mm). 1.8 mm for sharp curves; 4 mm for a hand-stitched look.
- **Engine:** `RunningStitchGenerator` resamples at a fixed arc length; a 3 mm stitch cuts the corner of a tight curve.
- **Recommend:** chord-gap-limited resampling (subdivide while the mid-point deviation > 0.07 mm, floor at min length). Small change; improves outlines, underlay edge runs and buried travel. ~½ day.

### B6. Tatami rows: backstitch type and random offset
- **Manual (p230–234):** row stagger to hide split lines (we have this); *standard* backstitch (rows of different lengths → fewer edge micro-stitches), *borderline* (clean edge for open fills), *diagonal* (for turning shapes); a **random factor** eliminates regular penetration patterns.
- **Engine:** boustrophedon rows with a fixed stagger — regular enough to show a faint diagonal on large flat fills.
- **Recommend:** add a small seeded random jitter (±15 % of stitch length) to interior penetrations; keep edges exact. ~2 hours.

### B7. Sequencing: details last, entry/exit "closest join", cap-friendly lettering order
- **Manual (p332, p471–475, p880–883):** "Details should always be stitched last." Closest Join: entry and exit points chosen so consecutive objects join at their nearest points (recomputed after any edit). Lettering sequence options: left-to-right, **center-out** (caps), lines bottom-to-top (caps and difficult fabrics), and *bottom join* for towelling (joins hidden in the pile).
- **Engine:** containment DAG + greedy nearest + 2-opt with run reversal — a good closest-join approximation — plus reading-order start. No "details last" and no cap-specific ordering.
- **Recommend:** (a) in `ObjectSequencer`, weight small/thin objects (running-stitch details, objects < ~2 % of design area) to the end of their colour block; (b) when `fabricType.isHeadwear` and placement is a cap front, sequence lettering runs center-out and stack multi-line text bottom-to-top; (c) on terry, prefer bottom joins for letters. ~1 day.

### B8. Raised satin, satin count
- **Manual (p228–229):** multiple satin layers (3–4 at 0.30 mm) for loft on columns ≤ 7 mm; satin count > 10 risks breaks.
- **Engine:** none.
- **Recommend:** low priority; a "Raised" per-object toggle later for monograms.

## C. Concepts the engine doesn't have (features)

### C1. Laydown stitch for napped fabrics
- **Manual (p419–427):** a light one- or two-layer fill (opposing angles, default 90°) placed *first in the sequence* under the whole design (offset ~2 mm outside the outline, holes optionally included) so terry/fleece/fur nap is flattened and the embroidery isn't lost in it. Thread colour chosen to blend with the fabric.
- **Engine:** terry is a fabric type that only raises compensation.
- **Recommend:** when fabric is terry/fleece-plush, generate a `laydown` object automatically: union of all objects' outlines offset +2 mm, one layer of very open tatami (3 mm spacing) at 0° then a second at 90°, colour = a user-chosen "fabric colour", sequenced first. Surface in the setup flow as "Flatten the nap first (recommended for towels and fleece)". ~1.5 days.

### C2. Remove overlaps ("cutters")
- **Manual (p431–433):** where a later object covers an earlier one, remove the underlying stitching with a 1–2 mm overlap kept for registration; ignore objects narrower than N; drop fragments smaller than a minimum so no tiny objects/colour changes are created.
- **Engine:** raster import separates overlapped regions into layers at trace time (so this is mostly solved for images); SVG import with overlapping filled paths double-stitches.
- **Recommend:** apply `ShapeMerger`'s layer separation to SVG import too (subtract later-sewn opaque shapes from earlier ones, keep 1.5 mm overlap, drop fragments < 4 mm²). ~1 day.

### C3. Thread-weight spacing offsets
- **Manual (p226):** spacing offset by thread thickness: 40 wt 0 (reference), 30 wt +0.03 mm, 60 wt −0.03, 80/100 wt −0.06.
- **Engine:** thread palettes carry colour only.
- **Recommend:** a design-level `threadWeight` (40/30/60) that offsets satin and fill spacing accordingly; expose in the setup flow's colour step. ~3 hours.

### C4. Auto start & end point
- **Manual (p1100–1103):** first and last needle positions set to hoop centre (or a corner) with a connector before the first / after the last stitch, so the machine's needle-down position matches the hoop and the operator can align. Some machines auto-centre and ignore it.
- **Engine:** design starts at the first object's first stitch.
- **Recommend:** optional "Start and end at hoop centre" (default off; on for caps since cap frames register on the centre); emits a jump from centre to first stitch and back. Trivial, and formats already support it. ~2 hours.

### C5. Process Stitches / target stitch count
- **Manual (p436–438):** scale density across a design to hit a target stitch count or percentage (production cost), per stitch type, with pull compensation adjusted in the same dialog.
- **Engine:** project-wide density sliders exist.
- **Recommend:** a "Target stitch count" control that solves density from the current plan (near-linear in 1/spacing), plus an *estimated run time* readout (stitches ÷ machine spm + trims × ~3 s + colour changes × ~20 s; Wilcom's Runtime Estimates chapter) — valuable for shops quoting jobs. ~½ day; the estimate alone is an hour.

### C6. Fabric presets carry stabiliser recommendations
- **Manual (p286–291):** each fabric preset stores default tatami/wide-satin/narrow-satin/lettering settings *and* recommended stabilisers, shown when the fabric is picked.
- **Engine/app:** `FabricType` only scales compensation.
- **Recommend:** extend `FabricType` with `recommendedStabilizer` copy (cut-away for knits/caps, tear-away for stable wovens, water-soluble topping + cut-away for terry, etc.) and show it in the setup flow's fabric step and on the readiness report. 1 hour; pure UX.

### C7. Auto-digitizing "details" and outlines
- **Manual (p1055–1061):** Smart Design lets thin shapes become satin, Column C or double-run; can add a run-stitch **outline around every colour block** and a satin **border** around the design; a Details slider filters small colour areas.
- **Engine:** classification by width already covers satin/run; no "outline all colour blocks" or "add border" options; the Colour Reduction presets partly cover the details slider.
- **Recommend:** two one-click options after import: "Outline colour areas" (bean-stitch outline per object, sequenced last per colour) and "Add satin border" (offset outline of the union, 2–3 mm satin). ~1 day.

---

## D. Confirmed: things the engine already does the manual's way
- Satin ↔ fill choice by width; satin rings around single counters; whole-word stitch-type consistency.
- Underlay stitched before cover per object; edge-run inset (`underlayInsetMM`).
- Tatami stagger; even-odd holes; fill angle across the shape's narrow axis.
- Pull compensation widening rails symmetrically about the centreline so underlay stays put.
- Min/max stitch filtering (0.4 / 12 mm); tie-in/tie-off present; trims on long jumps; hidden travel under later coverage; jump length limits.
- Containment-first sequencing, colour-change consolidation, closest-join-style run reversal, 2-opt refinement.
- Readiness report with specific, numeric issues.

---

## E. Suggested order of work

| # | Item | Effort | Why first |
|---|------|--------|-----------|
| 1 | A1 visible-connector rule (3 mm) + readiness check | ½ d | Most visible defect; pure logic |
| 2 | A2 width-based satin auto-spacing | 1 d | Small lettering quality; thread breaks |
| 3 | A5 lettering underlay by height (+ width rule for raster) | ½ d | Small text stiffness |
| 4 | B1 pull-compensation re-base to the manual's table | 2 h | Numbers, not a new mechanism |
| 5 | A3 fractional spacing + stitch shortening | 1.5 d | Script/curved satin |
| 6 | A6 auto-split satin with randomised penetrations | 1 d | Keeps glossy look on wide shapes |
| 7 | A7 tatami underlay + second underlay by fabric | 1.5 d | Knits, caps, beanies |
| 8 | B7 details-last + cap centre-out lettering | 1 d | Caps now first-class |
| 9 | A4 corner handling (mitre/cap) | 2–3 d | Biggest single quality jump for block lettering; hardest |
| 10 | C1 laydown for terry/fleece | 1.5 d | Whole new capability |
| 11 | C4/C5/C6 start-end point, run-time estimate, stabiliser advice | ½ d total | Cheap, shop-facing |
| 12 | B5, B6, B2, B3, C3 | 1.5 d total | Polish |
| 13 | C2, C7 | 2 d | SVG overlap cleanup; outline/border options |

Every item lands with tests in `Tests/StitchPilotCoreTests/` and a
before/after run of `DigitizeCLI` over `TestArtwork/` (the regression
corpus proposed separately); A1–A4 and B1 should each get a real sew-out.
