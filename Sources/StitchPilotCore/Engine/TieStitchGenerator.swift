import Foundation

/// Generates small lock stitches that anchor a thread end without a visible
/// knot (spec §27). A tie-in goes at the start of a new thread engagement
/// (the first object after a color change, or the very first object in the
/// design); a tie-off goes at the end, right before the trim that follows.
///
/// Technique: a short "there and back" — step a small distance in the
/// direction the real stitching is about to go (tie-in) or just came from
/// (tie-off), then return to the anchor point — before/after the real
/// stitch sequence. Under tension this locks the thread end the same way a
/// human hand-sewer's back-stitch does, without needing a physical knot.
public enum TieStitchGenerator {
    private static let lockStitchLengthMM = 0.5

    /// Prepends a tie-in to `points` (which must already be the real,
    /// generated stitch sequence for the run this tie-in anchors). No-op if
    /// there are fewer than 2 points to determine a direction from.
    ///
    /// The "there and back" only needs to add the "there" (`forward`) point
    /// explicitly -- the "back" leg's destination is `start`, which is
    /// already `points[0]` by construction, so appending it again here
    /// would land two identical points back to back: a genuine zero-length
    /// stitch, not a real one, and invisible to `StitchFilter`'s own
    /// minimum-length merge since tie stitches are added after that pass
    /// runs. Found as the reason this exact one extra stitch (matching the
    /// count of color engagements, i.e. present in every design regardless
    /// of its actual artwork or settings) always showed up in "stitches
    /// under 0.15mm" quality warnings that no amount of editing ever
    /// cleared. See CHANGELOG.md.
    public static func applyTieIn(to points: [Point2D]) -> [Point2D] {
        guard points.count >= 2 else { return points }
        let start = points[0]
        guard let dir = normalized(points[1], minus: start) else { return points }
        let forward = Point2D(start.x + dir.x * lockStitchLengthMM, start.y + dir.y * lockStitchLengthMM)
        return [start, forward] + points
    }

    /// Appends a tie-off to `points`.
    public static func applyTieOff(to points: [Point2D]) -> [Point2D] {
        guard points.count >= 2 else { return points }
        let end = points[points.count - 1]
        let previous = points[points.count - 2]
        guard let dir = normalized(end, minus: previous) else { return points }
        let overshoot = Point2D(end.x + dir.x * lockStitchLengthMM, end.y + dir.y * lockStitchLengthMM)
        return points + [overshoot, end]
    }

    private static func normalized(_ a: Point2D, minus b: Point2D) -> Point2D? {
        let dx = a.x - b.x, dy = a.y - b.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0.0001 else { return nil }
        return Point2D(dx / len, dy / len)
    }
}
