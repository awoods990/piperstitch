import Foundation

/// Text too small to sew, grown just enough to sew.
///
/// A line of lettering whose capitals come out under about 4 mm cannot be
/// made in thread at all: the satin columns end up narrower than the
/// thread is thick, and what reaches the fabric is a smear. So the engine
/// leaves such a line out whole — honest, and the alternative (sewing
/// readable fragments of half-letters) is worse, but from where the
/// customer sits their tagline simply vanished.
///
/// Most of the time the line misses by very little. A logo laid out for
/// a left chest at 89 mm puts "COFFEE CO." at about 3 mm, and a fifth
/// larger clears the floor. So a line that can be grown into range is
/// grown — in place, about its own centre, so the rest of the artwork
/// stays where the designer put it — and only a line that would have to
/// grow out of all proportion, or that has nowhere to grow into without
/// touching its neighbours, is left out as it was before.
public enum SmallTextRescue {
    /// Past this the line is no longer the artwork anybody handed us. A
    /// tagline a fifth larger reads as the same logo; one half again as
    /// large is a redesign, and that is the customer's to make.
    public static let maximumGrowth = 1.4

    /// Clear space to keep around a grown line, in its own cap heights.
    /// Letters that come to rest against their neighbours read as a blot
    /// however well each one is sewn.
    public static let clearanceFraction = 0.05

    public struct Plan: Equatable {
        /// Shape index -> how much to grow it, about `centre`.
        public var growth: [Int: Double] = [:]
        public var centre: [Int: Point2D] = [:]
        /// Lines that still cannot be sewn, and are left out as before.
        public var dropped: Set<Int> = []
        public var grownLines = 0
        public var omittedLines = 0

        public init() {}

        public var isEmpty: Bool { growth.isEmpty && dropped.isEmpty }
    }

    /// `scaleToMM` converts the imported pixel space to finished
    /// millimetres — the same factor the caller uses to fit the design.
    public static func plan(lines: [TextLine], shapes: [VectorShape], scaleToMM: Double,
                            minimumCapHeightMM: Double) -> Plan {
        var plan = Plan()
        guard scaleToMM > 0 else { return plan }
        for line in lines {
            let capMM = line.capHeightPixels * scaleToMM
            guard capMM > 0, capMM < minimumCapHeightMM else { continue }
            let needed = minimumCapHeightMM / capMM
            let indices = Set(line.shapeIndices)
            // Grow by what is needed if there is room for it, and
            // otherwise by as much as there is room for -- but only when
            // that still clears the floor. Half the growth a line needs
            // leaves it just as unsewable and no longer the right size
            // either, so a line that cannot get all the way there is
            // better left out and re-typed.
            var chosen: (scale: Double, centre: Point2D)?
            if needed <= maximumGrowth {
                for step in stride(from: needed, through: min(maximumGrowth, needed * 1.2), by: 0.02) {
                    if let centre = fits(line: line, grownBy: step, shapes: shapes, excluding: indices) {
                        chosen = (step, centre)
                        break
                    }
                }
            }
            if let chosen = chosen {
                for index in line.shapeIndices { plan.growth[index] = chosen.scale; plan.centre[index] = chosen.centre }
                plan.grownLines += 1
            } else if line.dropsWhenTooSmall {
                plan.dropped.formUnion(indices)
                plan.omittedLines += 1
            }
        }
        return plan
    }

    /// The centre to grow about, or nil when the grown line would come to
    /// rest against something else. Growing about the line's own centre
    /// keeps it where the designer put it; the check is against everything
    /// that is not part of the line.
    private static func fits(line: TextLine, grownBy scale: Double, shapes: [VectorShape],
                             excluding indices: Set<Int>) -> Point2D? {
        var box = BoundingBox.empty
        for index in line.shapeIndices where index >= 0 && index < shapes.count {
            box = box.union(shapes[index].boundingBox)
        }
        guard box.width > 0 || box.height > 0 else { return nil }
        let centre = Point2D((box.minX + box.maxX) / 2, (box.minY + box.maxY) / 2)
        let clearance = line.capHeightPixels * clearanceFraction
        let halfWidth = box.width * scale / 2 + clearance, halfHeight = box.height * scale / 2 + clearance
        let grown = BoundingBox(minX: centre.x - halfWidth, minY: centre.y - halfHeight,
                                maxX: centre.x + halfWidth, maxY: centre.y + halfHeight)
        for (index, shape) in shapes.enumerated() where !indices.contains(index) {
            let other = shape.boundingBox
            guard other.width > 0 || other.height > 0 else { continue }
            let apart = grown.maxX < other.minX || other.maxX < grown.minX
                || grown.maxY < other.minY || other.maxY < grown.minY
            if !apart { return nil }
        }
        return centre
    }

    /// The finished width at which every line of text in this artwork
    /// could be sewn, or nil when they all already can.
    ///
    /// Growing a line in place turns out to help rarely, and the corpus
    /// says why: text that is too small is usually too small by a lot. A
    /// logo's fine print wants to be four millimetres and is two — that is
    /// not a nudge, it is twice the size, and a line grown to twice the
    /// size is somebody else's logo. Where it is close, it is close
    /// because the designer packed it in, and there is nothing to grow
    /// into.
    ///
    /// What does move every line at once is the finished size. This is the
    /// width at which the smallest line that would otherwise be left out
    /// clears the floor, so the answer to "my tagline vanished" can be a
    /// number rather than an apology.
    public static func widthThatSewsAllText(lines: [TextLine], currentWidthMM: Double, scaleToMM: Double,
                                            minimumCapHeightMM: Double) -> Double? {
        guard currentWidthMM > 0, scaleToMM > 0 else { return nil }
        var worst = 1.0
        for line in lines where line.dropsWhenTooSmall {
            let capMM = line.capHeightPixels * scaleToMM
            guard capMM > 0, capMM < minimumCapHeightMM else { continue }
            worst = max(worst, minimumCapHeightMM / capMM)
        }
        guard worst > 1.0 else { return nil }
        return (currentWidthMM * worst * 10).rounded(.up) / 10
    }

    public static func grown(_ shape: VectorShape, by scale: Double, about centre: Point2D) -> VectorShape {
        VectorShape(subPaths: shape.subPaths.map { subPath in
            var copy = subPath
            copy.points = subPath.points.map {
                Point2D(centre.x + ($0.x - centre.x) * scale, centre.y + ($0.y - centre.y) * scale)
            }
            return copy
        })
    }
}
