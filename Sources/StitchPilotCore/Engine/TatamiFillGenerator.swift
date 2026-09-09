import Foundation

/// Generates tatami (scanline) fill stitches for a closed region — spec
/// §11 "Tatami / Fill Stitch". The shape's sub-paths are treated as a
/// single even-odd-rule polygon set, so additional sub-paths beyond the
/// first are automatically holes (spec §21 "Negative Space") without any
/// special-casing: a hole's boundary just contributes scanline crossings
/// that toggle the inside/outside state like any other edge.
///
/// Algorithm: rotate the shape so the fill angle becomes horizontal, grow
/// the boundary for pull compensation, walk scanlines at `fillSpacingMM`
/// intervals computing edge-crossing intervals (standard even-odd scanline
/// fill), shrink each row's overall span for push compensation. A hole
/// splits some rows into more than one crossing interval ("run") — rather
/// than flattening every row's runs into one stitch sequence regardless
/// (which would stitch a straight, solid-looking bridge across the hole on
/// every row that crosses it), `chainRuns` groups runs into independently-
/// connected regions across rows by X-overlap first, so a hole produces
/// separate chains that never cross it. Each chain is then resampled into
/// stitches at `stitchLengthMM` with its own boustrophedon alternation
/// (consecutive rows of that region connect with a short stitch instead of
/// a jump) and stitch-phase stagger (so seams don't line up into a visible
/// grid), `sequenceChains` orders the chains for minimal travel between
/// them, and the concatenated result is rotated back.
public enum TatamiFillGenerator {
    /// Flat convenience wrapper for callers that don't care about internal
    /// hole-crossing connectors (satin's tatami-converted sub-regions,
    /// existing geometry-only tests) — identical output to always merging
    /// every chain into one continuous run, exactly as this generator did
    /// before `generateRuns` existed.
    public static func generate(for shape: VectorShape, parameters: StitchGenerationParameters) -> [Point2D] {
        generateRuns(for: shape, parameters: parameters, breakThresholdMM: .infinity).flatMap { $0 }
    }

    /// Like `generate`, but keeps a hole-crossing connector between two
    /// chains as a *separate* output run instead of silently merging it in,
    /// whenever that connector is longer than `breakThresholdMM` — the
    /// caller (`DigitizePipeline`) turns a run boundary into a real
    /// trim+jump, avoiding a long, structurally weak thread bridged
    /// straight across open fabric where a hole is wide (a ring, a large
    /// cutout) rather than the narrow letterform counters this generator
    /// was originally tuned against. A connector shorter than the
    /// threshold stays merged into the same run, unchanged from before —
    /// see `stitchSegmentsCrossingAHoleAreBoundedNotOnePerRow`'s doc
    /// comment in `TatamiFillGeneratorTests.swift` for why a small residual
    /// crossing is fine and expected for that common case.
    public static func generateRuns(for shape: VectorShape, parameters: StitchGenerationParameters, breakThresholdMM: Double) -> [[Point2D]] {
        guard !shape.subPaths.isEmpty else { return [] }
        if parameters.fillPattern == .crossHatch {
            return generateCrossHatchRuns(for: shape, parameters: parameters, breakThresholdMM: breakThresholdMM)
        }
        if parameters.fillPattern == .basketWeave {
            return generateBasketWeaveRuns(for: shape, parameters: parameters, breakThresholdMM: breakThresholdMM)
        }
        let angleDegrees = parameters.fillAngleDegrees ?? FillAngleSelector.selectAngle(for: shape)
        let angleRad = angleDegrees * .pi / 180
        let cosA = cos(-angleRad), sinA = sin(-angleRad) // rotate shape by -angle so fill rows become horizontal

        func rotate(_ p: Point2D, cos c: Double, sin s: Double) -> Point2D {
            Point2D(p.x * c - p.y * s, p.x * s + p.y * c)
        }

        var rotatedPolygons: [[Point2D]] = shape.subPaths.map { sp in sp.points.map { rotate($0, cos: cosA, sin: sinA) } }
        var box = BoundingBox.empty
        for poly in rotatedPolygons { box = box.union(BoundingBox(points: poly)) }
        guard !box.isEmpty, box.height > 0 else { return [] }

        // Pull compensation (spec §17): grow the outer boundary outward
        // before scanning, so the fill sews at its intended size after
        // fabric pulls it in.
        let compensation = parameters.pullCompensationMM
            ?? PullCompensationCalculator.estimate(stitchType: .tatamiFill, densityMM: parameters.fillSpacingMM, objectWidthMM: box.height, fabricType: parameters.fabricType)
        // Skip compensation on a shape too small relative to it: growing a
        // near-degenerate sliver by pull compensation would fabricate a
        // fill region that wasn't really there rather than adjusting one
        // that was. Such shapes should be filtered upstream as
        // insignificant (spec §19) once that exists; this guard just keeps
        // this generator from doing something clearly wrong in the meantime.
        if compensation > 0, box.height > compensation * 4, !rotatedPolygons.isEmpty {
            rotatedPolygons[0] = PolygonGeometry.offsetPolygon(rotatedPolygons[0], by: -compensation)
            // Pull pulls fabric together at a hole's own edge too, the
            // same way it does at the outer boundary -- the stitched fill
            // right around a hole pulls away from the opening, which
            // tends to sew the hole LARGER than digitized unless
            // compensated. That's the opposite direction from the outer
            // boundary's own compensation: grow the *stitched* area
            // there, i.e. shrink the hole polygon itself (positive
            // `offsetPolygon` offset), rather than leaving it as-digitized.
            // Guarded the same way as the outer boundary, per-hole, so a
            // hole too small relative to the compensation amount doesn't
            // get offset into a collapsed/self-intersecting polygon.
            for i in 1..<rotatedPolygons.count {
                let holeBox = BoundingBox(points: rotatedPolygons[i])
                guard holeBox.height > compensation * 4, holeBox.width > compensation * 4 else { continue }
                rotatedPolygons[i] = PolygonGeometry.offsetPolygon(rotatedPolygons[i], by: compensation)
            }
            box = BoundingBox.empty
            for poly in rotatedPolygons { box = box.union(BoundingBox(points: poly)) }
        }

        let spacing = max(parameters.fillSpacingMM, 0.05)
        let stitchLength = max(parameters.stitchLengthMM, 0.3)
        let stagger = parameters.fillRowStaggerMM

        // Push compensation: fabric pushes apart *along* the stitching
        // direction (as opposed to pull, which narrows a design
        // perpendicular to it — see `PullCompensationCalculator`). Rows run
        // horizontally in this rotated space, so push acts along x: shrink
        // each row's *overall* span by insetting only its outermost start
        // and end, before resampling — not every enter/exit pair, which
        // would incorrectly nibble at a hole's boundary too. `box.width` is
        // the shape's extent along the row direction, the relevant "length"
        // axis for this effect (as opposed to `box.height`, along which
        // pull compensation above already grew the boundary).
        let pushCompMM = parameters.pushCompensationMM
            ?? PullCompensationCalculator.estimatePush(stitchType: .tatamiFill, densityMM: spacing, objectLengthMM: box.width, fabricType: parameters.fabricType)

        // Collect each row's crossing-pairs as raw intervals first, without
        // resampling yet -- `chainRuns` below needs to see run-to-run
        // adjacency across rows before any stitch points exist.
        var rowRuns: [[Run]] = []
        var rowIndex = 0
        var y = box.minY + spacing / 2 // center rows within the shape rather than starting exactly on the edge

        while y < box.maxY {
            var crossings = scanlineCrossings(polygons: rotatedPolygons, y: y)
            if pushCompMM > 0, crossings.count >= 2, crossings.last! - crossings.first! > pushCompMM {
                crossings[0] += pushCompMM / 2
                crossings[crossings.count - 1] -= pushCompMM / 2
            }
            var runs: [Run] = []
            var runIndex = 0
            while runIndex + 1 < crossings.count {
                let xStart = crossings[runIndex]
                let xEnd = crossings[runIndex + 1]
                runIndex += 2
                guard xEnd > xStart else { continue }
                runs.append(Run(start: xStart, end: xEnd, y: y, rowIndex: rowIndex))
            }
            rowRuns.append(runs)
            rowIndex += 1
            y += spacing
        }

        let chains = chainRuns(rowRuns)
        let orderedChains = sequenceChains(chains)

        var rotatedChainPoints: [[Point2D]] = []
        for chain in orderedChains {
            var chainPoints: [Point2D] = []
            for run in chain {
                let phase = (Double(run.rowIndex) * stagger).truncatingRemainder(dividingBy: stitchLength)
                var points = resampleRun(y: run.y, xStart: run.start, xEnd: run.end, stitchLength: stitchLength, phase: phase)
                // Boustrophedon: alternate direction by each run's own
                // *absolute* row index (not its position within whatever
                // chain/segment it ended up in after splicing), so
                // direction stays consistent with true row adjacency
                // regardless of how `sequenceChains` split a chain into
                // pieces to splice side-strips in between them.
                if run.rowIndex % 2 == 1 { points.reverse() }
                chainPoints.append(contentsOf: points)
            }
            if !chainPoints.isEmpty { rotatedChainPoints.append(chainPoints) }
        }

        // Merge consecutive chains back into one continuous output run
        // whenever the connector between them is short enough to sew as a
        // plain stitch (unchanged from this generator's original,
        // always-flattened behavior) — only a connector longer than
        // `breakThresholdMM` becomes a genuine run boundary the caller can
        // turn into a trim+jump. Distance is measured in this rotated space,
        // which rotation preserves exactly.
        //
        // Short alone isn't sufficient, though: `breakThresholdMM` (spec:
        // `maxJumpWithoutTrimMM`) exists on the premise that an untrimmed
        // same-color carry this short ends up buried under stitching sewn
        // moments later, the same reasoning `HiddenTravelRouter` uses
        // between separate objects -- but *within* one fill object, two
        // chains can sit on opposite sides of the shape's own concave
        // notch (e.g. a "U"'s open top, between its two strokes), where
        // the straight connector between them crosses empty space with no
        // fill on either side of it to hide it under. Found directly
        // against a real raster-imported logo's own "U" -- a genuine
        // ~11.5mm diagonal scratch across its open notch, well under the
        // default 15mm threshold and so never converted to a trim. Only
        // merge when the connector's own path actually stays inside the
        // shape, mirroring `HiddenTravelRouter.pathIsCoveredByShape`; a
        // connector that would leave the shape becomes a real run
        // boundary instead, however short it is. See CHANGELOG.md.
        var mergedRuns: [[Point2D]] = []
        for chainPoints in rotatedChainPoints {
            if let lastPoint = mergedRuns.last?.last, let firstPoint = chainPoints.first,
               lastPoint.distance(to: firstPoint) <= breakThresholdMM,
               connectorStaysInsideShape(from: lastPoint, to: firstPoint, polygons: rotatedPolygons) {
                mergedRuns[mergedRuns.count - 1].append(contentsOf: chainPoints)
            } else {
                mergedRuns.append(chainPoints)
            }
        }

        return mergedRuns.map { run in run.map { rotate($0, cos: cos(angleRad), sin: sin(angleRad)) } }
    }

    /// Samples several interior points along the straight line from `a` to
    /// `b` and checks each stays inside `polygons` (even-odd, so a hole
    /// correctly counts as outside) -- endpoints excluded deliberately,
    /// same reasoning as `HiddenTravelRouter.pathIsCoveredByShape`: both
    /// endpoints already sit on real stitched content by construction, so
    /// they're not informative about whether the path *between* them does.
    private static func connectorStaysInsideShape(from a: Point2D, to b: Point2D, polygons: [[Point2D]]) -> Bool {
        let sampleCount = 5
        for step in 1...sampleCount {
            let t = Double(step) / Double(sampleCount + 1)
            let sample = Point2D(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
            guard PolygonGeometry.pointInPolygons(sample, polygons: polygons) else { return false }
        }
        return true
    }

    /// One scanline row's crossing interval, in rotated space, before
    /// resampling into actual stitch points.
    private struct Run {
        var start: Double
        var end: Double
        var y: Double
        var rowIndex: Int
    }

    /// Two overlapping `.rows` passes at right angles, each at half the
    /// requested density -- see `FillPattern.crossHatch`'s own doc
    /// comment. Delegates entirely back to `generateRuns` (with the
    /// pattern reset to `.rows` so it doesn't recurse) for each pass, so
    /// every existing behavior -- hole handling via `chainRuns`, stagger,
    /// pull/push compensation, the `breakThresholdMM` hole-connector
    /// split -- applies identically to both passes without needing its
    /// own reimplementation here.
    private static func generateCrossHatchRuns(for shape: VectorShape, parameters: StitchGenerationParameters, breakThresholdMM: Double) -> [[Point2D]] {
        let baseAngle = parameters.fillAngleDegrees ?? FillAngleSelector.selectAngle(for: shape)
        var passParameters = parameters
        passParameters.fillPattern = .rows
        passParameters.fillSpacingMM = max(parameters.fillSpacingMM * 2, 0.05)

        passParameters.fillAngleDegrees = baseAngle
        let passA = generateRuns(for: shape, parameters: passParameters, breakThresholdMM: breakThresholdMM)

        passParameters.fillAngleDegrees = baseAngle + 90
        let passB = generateRuns(for: shape, parameters: passParameters, breakThresholdMM: breakThresholdMM)

        return passA + passB
    }

    /// The target cell size for `.basketWeave`'s checkerboard grid --
    /// smaller than this and the grid itself becomes a more visible
    /// artifact than whatever "grain" it's meant to break up; the actual
    /// cell size still varies a bit (the shape's own bounding box is
    /// divided evenly by however many cells that rounds up to, not
    /// clipped to a fixed grid), so it doesn't need to divide the shape's
    /// size evenly.
    private static let basketWeaveCellSizeMM = 12.0

    /// Splits `shape`'s own bounding box into a grid of roughly
    /// `basketWeaveCellSizeMM`-sized cells, clips the shape (every
    /// sub-path, so holes clip the same way the outer boundary does) to
    /// each cell via `PolygonGeometry.clipPolygonToRect`, and fills each
    /// cell independently as `.rows` at one of two angles 90° apart in a
    /// checkerboard -- see `FillPattern.basketWeave`'s own doc comment.
    /// Cells whose clipped shape has no usable outer boundary (the shape
    /// doesn't reach that cell at all) are simply skipped.
    private static func generateBasketWeaveRuns(for shape: VectorShape, parameters: StitchGenerationParameters, breakThresholdMM: Double) -> [[Point2D]] {
        var box = BoundingBox.empty
        for sp in shape.subPaths { box = box.union(sp.boundingBox) }
        guard !box.isEmpty, box.width > 0, box.height > 0 else { return [] }

        let baseAngle = parameters.fillAngleDegrees ?? FillAngleSelector.selectAngle(for: shape)
        let cols = max(1, Int((box.width / basketWeaveCellSizeMM).rounded(.up)))
        let rowCount = max(1, Int((box.height / basketWeaveCellSizeMM).rounded(.up)))
        let cellWidth = box.width / Double(cols)
        let cellHeight = box.height / Double(rowCount)

        var passParameters = parameters
        passParameters.fillPattern = .rows

        var allRuns: [[Point2D]] = []
        for row in 0..<rowCount {
            for col in 0..<cols {
                let cellMinX = box.minX + Double(col) * cellWidth
                let cellMinY = box.minY + Double(row) * cellHeight
                // The last row/column reaches exactly to the shape's own
                // extent rather than accumulated cell widths, so rounding
                // error can't leave a sliver of the shape uncovered by any
                // cell at the far edge.
                let cellMaxX = col == cols - 1 ? box.maxX : cellMinX + cellWidth
                let cellMaxY = row == rowCount - 1 ? box.maxY : cellMinY + cellHeight

                let clippedSubPaths = shape.subPaths.compactMap { sp -> SubPath? in
                    let clipped = PolygonGeometry.clipPolygonToRect(sp.points, minX: cellMinX, minY: cellMinY, maxX: cellMaxX, maxY: cellMaxY)
                    guard clipped.count >= 3 else { return nil }
                    return SubPath(points: clipped, closed: true)
                }
                guard !clippedSubPaths.isEmpty else { continue }

                passParameters.fillAngleDegrees = (row + col).isMultiple(of: 2) ? baseAngle : baseAngle + 90
                let cellRuns = generateRuns(for: VectorShape(subPaths: clippedSubPaths), parameters: passParameters, breakThresholdMM: breakThresholdMM)
                allRuns.append(contentsOf: cellRuns)
            }
        }
        return allRuns
    }

    /// Groups runs into connected chains across rows by X-overlap, so a
    /// hole that splits one row into two runs produces two independently-
    /// connected fill regions instead of one row's "run" list being
    /// flattened and stitched straight across the gap between them. Without
    /// this, every row crossing a hole added one dense stitch bridging
    /// straight through its middle -- individually invisible, but repeated
    /// at normal row spacing (as low as ~0.4mm) across the hole's full
    /// height, those bridging stitches alone were dense enough to visually
    /// fill the hole back in, even though the shape data and even-odd
    /// scanline logic already correctly excluded it. Found against a real
    /// multi-hole letterform ("B", two counters) in a user's logo — a
    /// single-hole synthetic test (`TatamiFillGeneratorTests.
    /// holeIsRespected`) didn't catch it because it only checked that no
    /// fill *points* land inside the hole, not that no stitch *segment*
    /// crosses through it (see CHANGELOG.md).
    ///
    /// Matching is greedy-by-overlap, resolved most-overlap-first so two
    /// rows competing for the same chain don't get assigned arbitrarily:
    /// a hole opening (1 row's run -> 2 next row's runs) starts a new
    /// chain for whichever run doesn't win the best-overlap match; a hole
    /// closing (2 active chains -> 1 run) continues whichever chain
    /// overlaps most and leaves the other to end where it is -- coverage
    /// is unaffected either way (every run always joins some chain), only
    /// which underlying thread path continues which region.
    private static func chainRuns(_ rowRuns: [[Run]]) -> [[Run]] {
        var chains: [[Run]] = []
        var activeChainIndices: [Int] = []

        for runs in rowRuns {
            var candidates: [(runIndex: Int, chainIndex: Int, overlap: Double)] = []
            for (ri, run) in runs.enumerated() {
                for chainIndex in activeChainIndices {
                    guard let lastRun = chains[chainIndex].last else { continue }
                    let overlap = min(run.end, lastRun.end) - max(run.start, lastRun.start)
                    if overlap > 0 { candidates.append((ri, chainIndex, overlap)) }
                }
            }
            candidates.sort { $0.overlap > $1.overlap }

            var runToChain = [Int?](repeating: nil, count: runs.count)
            var chainClaimed = Set<Int>()
            for candidate in candidates {
                guard runToChain[candidate.runIndex] == nil, !chainClaimed.contains(candidate.chainIndex) else { continue }
                runToChain[candidate.runIndex] = candidate.chainIndex
                chainClaimed.insert(candidate.chainIndex)
            }

            var newActive: [Int] = []
            for (ri, run) in runs.enumerated() {
                if let chainIndex = runToChain[ri] {
                    chains[chainIndex].append(run)
                    newActive.append(chainIndex)
                } else {
                    chains.append([run])
                    newActive.append(chains.count - 1)
                }
            }
            activeChainIndices = newActive
        }
        return chains
    }

    /// Orders chains for final concatenation by splicing each side-chain in
    /// immediately adjacent to the exact row where it split off from the
    /// main fill, instead of appending disconnected chains in some other
    /// order and hoping a straight connector between them happens to look
    /// reasonable.
    ///
    /// A fully-enclosed hole (an ordinary letter counter, not one that
    /// touches the shape's outer edge) never actually removes a row from
    /// the main chain's own row sequence -- every row still gives the main
    /// chain *a* run, just a narrower one on one side of the hole, while
    /// the hole's other side becomes a separate short side-chain for
    /// exactly the hole's row range. So "the main chain's row numbers have
    /// a gap" is not a reliable signal of where a hole is (an earlier
    /// version of this function assumed it was, found nothing to splice for
    /// this exact case, and fell through to appending the side-chain at the
    /// very end -- reintroducing a long-distance connector that could cut
    /// straight back through the hole it came from). The reliable signal is
    /// simpler: a side-chain's *first* row tells you exactly which row of
    /// the main chain it split away from, so that's where it belongs.
    private static func sequenceChains(_ chains: [[Run]]) -> [[Run]] {
        guard chains.count > 1 else { return chains }
        // The chain with the most rows is, in practice, the one that
        // continues across most holes' splits and merges -- most other
        // chains are short side-strips confined to one hole's row range,
        // starting and ending somewhere inside this one's own row span.
        guard let rootIndex = chains.indices.max(by: { chains[$0].count < chains[$1].count }) else { return chains }

        var chainsStartingAtRow: [Int: [Int]] = [:]
        for (ci, chain) in chains.enumerated() where ci != rootIndex {
            guard let firstRowIndex = chain.first?.rowIndex else { continue }
            chainsStartingAtRow[firstRowIndex, default: []].append(ci)
        }

        let rootLastRow = chains[rootIndex].last?.rowIndex ?? Int.max
        var placed = Set([rootIndex])
        var ordered: [[Run]] = []
        var deferredToEnd: [[Run]] = []
        var pending: [Run] = []
        func flushPending() {
            guard !pending.isEmpty else { return }
            ordered.append(pending)
            pending = []
        }

        for run in chains[rootIndex] {
            pending.append(run)
            // Splice in every side-chain that begins at this exact row,
            // right after finishing the root's own run for it -- the
            // shortest possible connector in both directions, since the
            // side-chain's own first (and, after it, the root's very next)
            // row are immediately adjacent to this one. Except: a chain
            // that itself outlives root (its own last row is past root's)
            // would hijack root's flow -- splicing it in here mid-stream,
            // then coming back to root's remaining rows afterward, means
            // jumping backward from wherever *that* chain ends to root's
            // own next row, which can be a long, awkward connector (found
            // against a real "B": one hole's other-side chain outlived
            // root, entered here, and left a visible diagonal line back
            // across the counter once spliced mid-stream -- see
            // CHANGELOG.md). Defer those to the very end instead, where
            // root's flow stays uninterrupted and only the one deferred
            // chain's own entry connector is imperfect, not root's exit too.
            if let starting = chainsStartingAtRow[run.rowIndex] {
                flushPending()
                for chainIndex in starting {
                    placed.insert(chainIndex)
                    if (chains[chainIndex].last?.rowIndex ?? Int.min) > rootLastRow {
                        deferredToEnd.append(chains[chainIndex])
                    } else {
                        ordered.append(chains[chainIndex])
                    }
                }
            }
        }
        flushPending()
        ordered.append(contentsOf: deferredToEnd)

        // Safety net: a real "B" (two holes) can produce a chain whose own
        // row range starts *before* root's or extends *past* root's own
        // end -- e.g. root winning the first hole's left side, right side,
        // then continuing solo, only for a *different* chain to win the
        // second hole's other side and outlive root entirely. Such a chain
        // never has a row that coincides with one of root's own rows, so
        // the splice above never finds it -- which silently dropped an
        // entire region of a real letterform's fill (confirmed against a
        // user's logo: roughly a third of a "B" went unstitched). Appending
        // it here isn't always the shortest possible connector, but
        // guaranteed full coverage matters far more than routing elegance
        // for a case rare enough that root-based splicing alone can't
        // reach it — see CHANGELOG.md. A leftover chain that starts
        // *before* root's own first row belongs at the very front, not the
        // very back -- root's first-placed piece starts right where such a
        // chain tends to end (it's what root took over from), so this is a
        // much shorter connector than appending after everything, even
        // though it's still not a fully general shortest-path placement.
        let rootFirstRow = chains[rootIndex].first?.rowIndex ?? Int.min
        for (ci, chain) in chains.enumerated() where !placed.contains(ci) {
            if let firstRow = chain.first?.rowIndex, firstRow < rootFirstRow {
                ordered.insert(chain, at: 0)
            } else {
                ordered.append(chain)
            }
        }
        return ordered
    }

    /// Even-odd rule: all edges from all sub-paths (holes included) are
    /// tested against the scanline together; sorted crossing X-values pair
    /// up as [enter, exit, enter, exit, ...].
    private static func scanlineCrossings(polygons: [[Point2D]], y: Double) -> [Double] {
        var xs: [Double] = []
        for poly in polygons {
            guard poly.count > 1 else { continue }
            for i in 0..<poly.count {
                let a = poly[i]
                let b = poly[(i + 1) % poly.count] // treat every fill sub-path as implicitly closed
                let (lo, hi) = a.y < b.y ? (a, b) : (b, a)
                guard y >= lo.y, y < hi.y, hi.y > lo.y else { continue } // half-open avoids double-counting at shared vertices
                let t = (y - lo.y) / (hi.y - lo.y)
                xs.append(lo.x + t * (hi.x - lo.x))
            }
        }
        return xs.sorted()
    }

    /// Resamples one row's interval at approximately `stitchLength`,
    /// starting the first interior stitch at the staggered `phase` offset
    /// (preserving the anti-grid benefit of staggering — see this type's
    /// own doc comment on why rows are staggered at all), but then evenly
    /// redistributing the *remaining* distance to `xEnd` across a whole
    /// number of steps close to `stitchLength`, rather than stepping by a
    /// fixed `stitchLength` and appending one final "catch-up" point
    /// wherever that happens to land. A fixed step leaves that catch-up
    /// segment anywhere from ~0 to a full `stitchLength` long; evening out
    /// the remainder keeps every row landing exactly on the true edge with
    /// a uniform final step instead — a small cleanliness improvement, not
    /// a fix for any specific visible defect (a dramatic-looking
    /// criss-cross pattern initially suspected to be caused by this turned
    /// out, on direct inspection, to be the ordinary tie-in/tie-off anchor
    /// stitches — see CHANGELOG.md).
    private static func resampleRun(y: Double, xStart: Double, xEnd: Double, stitchLength: Double, phase: Double) -> [Point2D] {
        var points: [Point2D] = [Point2D(xStart, y)]
        let firstOffset = phase > 0 ? phase : stitchLength
        let firstInterior = xStart + firstOffset
        guard firstInterior < xEnd else {
            if xEnd - xStart > 0.01 { points.append(Point2D(xEnd, y)) }
            return points
        }
        let remaining = xEnd - firstInterior
        let stepCount = max(1, Int((remaining / stitchLength).rounded()))
        let step = remaining / Double(stepCount)
        for i in 0...stepCount {
            points.append(Point2D(firstInterior + step * Double(i), y))
        }
        return points
    }
}
