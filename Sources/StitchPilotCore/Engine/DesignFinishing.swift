import Foundation

/// Whole-design operations from the Wilcom review: overlap removal on
/// vector import (C2) and the one-click finishing touches its
/// auto-digitizer offers (C7) -- an outline around every colour area and
/// a satin border around the design.
public enum DesignFinishing {
    // MARK: - C2 remove overlaps

    /// Kept under a cover's edge so the cover has stitching to land on
    /// if the fabric shifts (Wilcom: 1–2 mm).
    public static let keepOverlapMM = 1.5
    /// A leftover smaller than this is dropped rather than becoming its
    /// own tiny object.
    public static let minFragmentAreaMM2 = 4.0

    /// Vector artwork is drawn back to front: a later filled shape
    /// covers whatever earlier shape it overlaps, and sewing both in
    /// full stitches the covered part twice (a thick, stiff patch under
    /// the top colour). Removes the covered part of every earlier shape
    /// except the registration band; a shape covered entirely comes
    /// back as nil. `opaque[i]` false means shape i doesn't cover
    /// anything (an unfilled outline). Shapes whose boxes don't overlap
    /// a later one are returned untouched -- exact vector geometry. Each
    /// entry is the pieces the shape became (a shape cut in two is two
    /// pieces; a shape covered entirely is none).
    public static func removeOverlaps(_ shapes: [VectorShape], opaque: [Bool]) -> [[VectorShape]] {
        let boxes = shapes.map { $0.boundingBox }
        return shapes.indices.map { i in
            var covers: [VectorShape] = []
            for j in (i + 1)..<shapes.count where j < opaque.count && opaque[j] && boxes[i].intersects(boxes[j]) {
                covers.append(shapes[j])
            }
            guard !covers.isEmpty else { return [shapes[i]] }
            return ShapeMerger.subtractCoverage(of: shapes[i], by: covers, keepOverlapMM: keepOverlapMM, minFragmentAreaMM2: minFragmentAreaMM2)
        }
    }

    // MARK: - C7 outlines and border

    public static let borderWidthMM = 2.5

    /// A running-stitch (bean stitch) outline for every filled object,
    /// in the object's own colour, following its outer edge and every
    /// hole. Sequenced after the object's colour block by the
    /// sequencer's details-last rule. Objects that already are outlines
    /// are skipped, as are ones that already have an outline.
    public static func outlineObjects(for document: StitchDocument) -> [EmbroideryObject] {
        var added: [EmbroideryObject] = []
        let existing = Set(document.objects.map { $0.name })
        for object in document.objects where object.stitchType == .satin || object.stitchType == .tatamiFill {
            let name = "Outline of \(object.name)"
            guard !existing.contains(name) else { continue }
            let shape = VectorShape(subPaths: object.shape.subPaths.map { SubPath(points: $0.points, closed: true) })
            var parameters = object.parameters
            parameters.underlayType = UnderlayType.none
            parameters.secondUnderlayType = nil
            added.append(EmbroideryObject(name: name, shape: shape, stitchType: .tripleRun, threadColor: object.threadColor,
                                          parameters: parameters, stitchTypeIsManualOverride: true))
        }
        return added
    }

    /// A ring `widthMM` wide around the outside of the whole design (the
    /// union of every object, holes filled), classified like any other
    /// shape -- satin where the ring can be railed, tatami otherwise.
    /// Nil when the design has no area.
    public static func borderObject(for document: StitchDocument, widthMM: Double = borderWidthMM, threadColor: ThreadColor) -> EmbroideryObject? {
        let shapes = document.objects.filter { $0.name != "Border" }.map { $0.shape }
        guard let inner = ShapeMerger.dilatedUnion(shapes, marginMM: 0, fillHoles: true),
              let outer = ShapeMerger.dilatedUnion(shapes, marginMM: widthMM, fillHoles: true) else { return nil }
        // The ring: outer boundary plus the inner boundary as a hole.
        // (Only the outer boundary of each; an island's own holes were
        // filled above.)
        let outerPaths = outer.subPaths.filter { abs(PolygonGeometry.signedArea($0.points)) > 1 }
        let innerPaths = inner.subPaths.filter { abs(PolygonGeometry.signedArea($0.points)) > 1 }
        guard !outerPaths.isEmpty, !innerPaths.isEmpty else { return nil }
        let ring = VectorShape(subPaths: outerPaths + innerPaths)
        var parameters = document.objects.first?.parameters ?? StitchGenerationParameters()
        parameters.pullCompensationMM = nil
        parameters.pushCompensationMM = nil
        let stitchType = StitchTypeClassifier.classify(shape: ring, parameters: parameters)
        return EmbroideryObject(name: "Border", shape: ring, stitchType: stitchType, threadColor: threadColor, parameters: parameters)
    }
}
