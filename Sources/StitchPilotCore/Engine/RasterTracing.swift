import Foundation

/// Shared raster-to-vector primitives: connected-component labeling and
/// boundary tracing over a boolean pixel mask. Originally part of
/// `ImageImporter` (raster artwork import); factored out here so
/// `ShapeMerger` (merging selected objects, painting in extra coverage)
/// can reuse the exact same, already-hardened tracing logic instead of a
/// second implementation that could drift from it.
public enum RasterTracing {
    public struct Component {
        public var topLeftMost: (x: Int, y: Int)
        public var area: Int
        /// Every pixel of the component, as `y * width + x` indices --
        /// for callers that relabel whole components (`ShapeMerger.
        /// splitThickAndThin`). Costs one Int per pixel, which every
        /// existing caller already paid for in the BFS queue.
        public var pixelIndices: [Int]
    }

    // MARK: - Connected components (8-connectivity, BFS)

    public static func connectedComponents(mask: [Bool], width: Int, height: Int, minAreaPixels: Int = 1) -> [Component] {
        var visited = [Bool](repeating: false, count: width * height)
        var components: [Component] = []
        let neighborOffsets = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                guard mask[idx], !visited[idx] else { continue }

                var queue = [(x, y)]
                visited[idx] = true
                var area = 0
                var topLeftMost = (x: x, y: y)

                var head = 0
                while head < queue.count {
                    let (cx, cy) = queue[head]; head += 1
                    area += 1
                    if cy < topLeftMost.y || (cy == topLeftMost.y && cx < topLeftMost.x) {
                        topLeftMost = (cx, cy)
                    }
                    for (dx, dy) in neighborOffsets {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let nIdx = ny * width + nx
                        if mask[nIdx], !visited[nIdx] {
                            visited[nIdx] = true
                            queue.append((nx, ny))
                        }
                    }
                }

                if area >= minAreaPixels {
                    components.append(Component(topLeftMost: topLeftMost, area: area, pixelIndices: queue.map { $0.1 * width + $0.0 }))
                }
            }
        }
        return components
    }

    /// Clears every 8-connected component of `mask` smaller than
    /// `minAreaPixels`; returns whether anything is left.
    @discardableResult
    public static func removeSmallComponents(_ mask: inout [Bool], width: Int, height: Int, minAreaPixels: Int) -> Bool {
        var visited = [Bool](repeating: false, count: width * height)
        var anyKept = false
        let neighborOffsets = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]
        for start in mask.indices where mask[start] && !visited[start] {
            var queue = [start]
            visited[start] = true
            var head = 0
            while head < queue.count {
                let idx = queue[head]; head += 1
                let cx = idx % width, cy = idx / width
                for (dx, dy) in neighborOffsets {
                    let nx = cx + dx, ny = cy + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let nIdx = ny * width + nx
                    if mask[nIdx], !visited[nIdx] { visited[nIdx] = true; queue.append(nIdx) }
                }
            }
            if queue.count < minAreaPixels {
                for idx in queue { mask[idx] = false }
            } else {
                anyKept = true
            }
        }
        return anyKept
    }

    // MARK: - Moore-neighbor boundary tracing

    /// Compass directions in cyclic order (each adjacent to the next); the
    /// specific starting point / rotation sense doesn't matter as long as
    /// it's a consistent cyclic order — see DIGITIZING_ENGINE.md.
    private static let compass: [(Int, Int)] = [(-1, 0), (-1, 1), (0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1)]

    public static func traceBoundary(mask: [Bool], width: Int, height: Int, start: (x: Int, y: Int)) -> [Point2D]? {
        func isForeground(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            return mask[y * width + x]
        }

        let first = start
        // `first` is the topmost-then-leftmost pixel of its component, so
        // its West neighbor is guaranteed background -- a safe direction to
        // bootstrap the very first neighbor search from. It is *only* a
        // bootstrapping choice, though: it doesn't predict which direction
        // the walk will eventually re-enter `first` from once it comes back
        // around (that depends on the shape), so it must not be reused as
        // the closing test below -- see that comment for why an earlier
        // version of this code got that wrong.
        var backtrack = (x: first.x - 1, y: first.y)
        var current = first
        var boundary: [Point2D] = [Point2D(Double(current.x), Double(current.y))]

        // Single isolated pixel (no foreground neighbors at all) — too small
        // to form a boundary; the caller's area filter already excludes
        // most of these upstream.
        if compass.allSatisfy({ !isForeground(current.x + $0.0, current.y + $0.1) }) {
            return nil
        }

        // Jacob's stopping criterion: the walk is a deterministic function
        // of (current, backtrack), so it closes exactly when that pair
        // repeats -- but the *first* pair it's ever in is (first, an
        // arbitrary bootstrapping backtrack that isn't actually part of the
        // real cycle), not a state the walk will revisit. The first state
        // that genuinely recurs is the one right after the first real step:
        // (secondPoint, first). A previous version of this code compared
        // against (first, west-of-first) instead, which for a plain 40x40
        // test square never once matched -- the trace closes correctly
        // after 156 steps, just re-entering `first` from the *east*, not
        // the assumed west -- so it always ran to `maxSteps` and returned
        // whatever partial, garbled walk it had accumulated as if it were a
        // real boundary. For a well-formed shape that's wastefully
        // redundant (the same correct loop retraced dozens of times over);
        // for a thin or pinch-pointed shape that never actually recurs at
        // all, it's a 126,017-point degenerate "boundary" for a single
        // 39-pixel fragment of `SMA Logo.webp`, which then sent an O(n²)
        // polyline-simplification pass into a multi-minute hang — found via
        // `DigitizeCLI` while investigating a report of a small image
        // producing over a million stitches (see CHANGELOG.md).
        let maxSteps = width * height * 2 + 64
        var steps = 0
        var closed = false
        var secondPoint: (x: Int, y: Int)?
        repeat {
            guard let bIdx = compass.firstIndex(where: { $0.0 == backtrack.x - current.x && $0.1 == backtrack.y - current.y }) else { break }
            var found: (Int, Int)?
            var idx = (bIdx + 1) % 8
            for _ in 0..<8 {
                let nx = current.x + compass[idx].0, ny = current.y + compass[idx].1
                if isForeground(nx, ny) { found = (nx, ny); break }
                idx = (idx + 1) % 8
            }
            guard let next = found else { break }
            backtrack = current
            current = next
            steps += 1
            if let secondPoint, current == secondPoint, backtrack == first {
                closed = true
                break // don't append -- `current` duplicates `secondPoint`, already in `boundary`
            }
            if secondPoint == nil { secondPoint = current }
            boundary.append(Point2D(Double(current.x), Double(current.y)))
        } while steps < maxSteps

        return (closed && boundary.count > 2) ? boundary : nil
    }

    // MARK: - Enclosed-region (hole) detection

    /// Finds every background region fully enclosed within
    /// `foregroundMask`'s foreground and traces each one's boundary, the
    /// same way an outer shape's own boundary is traced. Distinguished
    /// from ordinary background (which touches the mask's own border) via
    /// a flood fill from the border across background pixels only:
    /// anything *not* reached that way is enclosed by foreground on every
    /// side, not touching the outside at all -- the standard "flood-fill
    /// from the edges to find holes" technique. Originally
    /// `ImageImporter`'s own private `findHoleBoundaries`, factored out
    /// here so `ShapeMerger` can find holes the same way instead of
    /// silently losing them: rasterizing-and-retracing a shape that
    /// already had one (a letterform counter, most commonly) without this
    /// step traces only the outer boundary and drops the hole entirely,
    /// turning e.g. an "O" solid.
    public static func findEnclosedRegionBoundaries(foregroundMask: [Bool], width: Int, height: Int, minAreaPixels: Int = 1) -> [[Point2D]] {
        var reachableBackground = [Bool](repeating: false, count: width * height)
        var queue: [Int] = []
        func seed(_ x: Int, _ y: Int) {
            let i = y * width + x
            guard !foregroundMask[i], !reachableBackground[i] else { return }
            reachableBackground[i] = true
            queue.append(i)
        }
        for x in 0..<width { seed(x, 0); seed(x, height - 1) }
        for y in 0..<height { seed(0, y); seed(width - 1, y) }

        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            let x = i % width, y = i / width
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                let ni = ny * width + nx
                guard !foregroundMask[ni], !reachableBackground[ni] else { continue }
                reachableBackground[ni] = true
                queue.append(ni)
            }
        }

        var holeMask = [Bool](repeating: false, count: width * height)
        for i in 0..<(width * height) where !foregroundMask[i] && !reachableBackground[i] {
            holeMask[i] = true
        }

        let holeComponents = connectedComponents(mask: holeMask, width: width, height: height, minAreaPixels: minAreaPixels)
        var boundaries: [[Point2D]] = []
        for hole in holeComponents {
            guard let boundary = traceBoundary(mask: holeMask, width: width, height: height, start: hole.topLeftMost) else { continue }
            boundaries.append(boundary)
        }
        return boundaries
    }
}

private func == (a: (x: Int, y: Int), b: (x: Int, y: Int)) -> Bool { a.x == b.x && a.y == b.y }
