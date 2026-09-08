import Testing
@testable import StitchPilotCore

struct LetteringGeneratorTests {
    @Test func generatesOneShapePerLetter() throws {
        let spec = LetteringSpec(text: "AB", fontPostScriptName: "Helvetica-Bold", fontSizeMM: 20)
        let shapes = try LetteringGenerator.generateShapes(spec: spec)
        #expect(shapes.count == 2, "one VectorShape per glyph, not one shape for the whole string")
    }

    @Test func lettersWithCountersGetAHoleSubpath() throws {
        // "O" has a genuine enclosed counter -- its outline should come
        // back as an outer subpath plus an inner hole subpath, matching
        // this engine's even-odd multi-subpath convention (the same one
        // ImageImporter/SVGImporter already use for a letterform counter).
        let spec = LetteringSpec(text: "O", fontPostScriptName: "Helvetica-Bold", fontSizeMM: 20)
        let shapes = try LetteringGenerator.generateShapes(spec: spec)
        #expect(shapes.count == 1)
        #expect(shapes[0].subPaths.count == 2, "an O needs an outer contour and one hole")
    }

    @Test func lettersWithoutCountersHaveNoHoleSubpath() throws {
        let spec = LetteringSpec(text: "L", fontPostScriptName: "Helvetica-Bold", fontSizeMM: 20)
        let shapes = try LetteringGenerator.generateShapes(spec: spec)
        #expect(shapes.count == 1)
        #expect(shapes[0].subPaths.count == 1, "an L has no enclosed counter")
    }

    @Test func capHeightMatchesRequestedSizeApproximately() throws {
        let spec = LetteringSpec(text: "H", fontPostScriptName: "Helvetica-Bold", fontSizeMM: 25)
        let shapes = try LetteringGenerator.generateShapes(spec: spec)
        let box = shapes[0].boundingBox
        // "H" has no ascender/descender beyond the cap height, so its own
        // bounding-box height should land close to the requested cap height.
        #expect(abs(box.height - 25) < 1.5, "an H's own height should closely match the requested cap height, got \(box.height)")
    }

    @Test func widerTextProducesAWiderOverallBoundingBox() throws {
        let shortSpec = LetteringSpec(text: "I", fontPostScriptName: "Helvetica-Bold", fontSizeMM: 20)
        let longSpec = LetteringSpec(text: "IIIII", fontPostScriptName: "Helvetica-Bold", fontSizeMM: 20)
        let shortShapes = try LetteringGenerator.generateShapes(spec: shortSpec)
        let longShapes = try LetteringGenerator.generateShapes(spec: longSpec)

        func combinedBox(_ shapes: [VectorShape]) -> BoundingBox {
            var box = BoundingBox.empty
            for s in shapes { box = box.union(s.boundingBox) }
            return box
        }
        #expect(combinedBox(longShapes).width > combinedBox(shortShapes).width * 3)
    }

    @Test func extraLetterSpacingWidensTheLayout() throws {
        let tight = LetteringSpec(text: "II", fontPostScriptName: "Helvetica-Bold", fontSizeMM: 20, letterSpacingMM: 0)
        let spaced = LetteringSpec(text: "II", fontPostScriptName: "Helvetica-Bold", fontSizeMM: 20, letterSpacingMM: 10)
        let tightShapes = try LetteringGenerator.generateShapes(spec: tight)
        let spacedShapes = try LetteringGenerator.generateShapes(spec: spaced)
        // The second letter should have moved further right with extra spacing.
        let tightSecondX = tightShapes[1].boundingBox.minX
        let spacedSecondX = spacedShapes[1].boundingBox.minX
        #expect(spacedSecondX > tightSecondX + 5)
    }

    @Test func arcBaselineCurvesTextAwayFromAStraightLine() throws {
        let straightSpec = LetteringSpec(text: "SARASOTA", fontPostScriptName: "Helvetica-Bold", fontSizeMM: 10, baseline: .straight)
        let arcSpec = LetteringSpec(text: "SARASOTA", fontPostScriptName: "Helvetica-Bold", fontSizeMM: 10, baseline: .arc(radiusMM: 40))
        let straightShapes = try LetteringGenerator.generateShapes(spec: straightSpec)
        let arcShapes = try LetteringGenerator.generateShapes(spec: arcSpec)

        // On a straight baseline every glyph's own bottom edge sits at
        // (roughly) the same Y. On an arc, the outer letters should sit
        // measurably lower (curving away from the topmost, centered letter).
        let straightYs = straightShapes.map { $0.boundingBox.maxY }
        let arcYs = arcShapes.map { $0.boundingBox.maxY }
        #expect(straightYs.max()! - straightYs.min()! < 0.5, "a straight baseline keeps every letter's baseline level")
        #expect(arcYs.max()! - arcYs.min()! > 2.0, "an arc baseline should visibly drop the outer letters relative to the center")
    }

    @Test func centeredLetterOnAnArcStaysNearItsStraightPosition() throws {
        // The middle letter of a centered arc sits at theta≈0, where the
        // arc's own tangent is horizontal -- it should barely move
        // relative to the straight layout, unlike the letters toward
        // either end. Uses a narrow glyph ("I") specifically -- a wide one
        // (e.g. "M") has its own left/right edges far enough from its own
        // center that *their* theta is no longer ≈0, which would make a
        // wide glyph's bounding box drop measurably even while its own
        // center stays put; that's a property of the glyph's width, not a
        // bug in the arc math.
        let text = "III"
        let straight = try LetteringGenerator.generateShapes(spec: LetteringSpec(text: text, fontPostScriptName: "Helvetica-Bold", fontSizeMM: 10, baseline: .straight))
        let arc = try LetteringGenerator.generateShapes(spec: LetteringSpec(text: text, fontPostScriptName: "Helvetica-Bold", fontSizeMM: 10, baseline: .arc(radiusMM: 60)))
        let middleStraightY = straight[1].boundingBox.maxY
        let middleArcY = arc[1].boundingBox.maxY
        #expect(abs(middleStraightY - middleArcY) < 0.3)
    }

    @Test func emptyTextThrows() {
        #expect(throws: LetteringGenerationError.self) {
            _ = try LetteringGenerator.generateShapes(spec: LetteringSpec(text: "", fontPostScriptName: "Helvetica-Bold"))
        }
    }

    @Test func unknownFontThrows() {
        #expect(throws: LetteringGenerationError.self) {
            _ = try LetteringGenerator.generateShapes(spec: LetteringSpec(text: "Hi", fontPostScriptName: "ThisFontDefinitelyDoesNotExist12345"))
        }
    }

    @Test func generatedLetteringIntegratesWithTheDigitizePipeline() throws {
        // The whole point of generating real vector shapes is that they
        // flow through the exact same classify-and-stitch pipeline as any
        // other imported shape -- no special-casing needed downstream.
        let spec = LetteringSpec(text: "HI", fontPostScriptName: "Helvetica-Bold", fontSizeMM: 15)
        let shapes = try LetteringGenerator.generateShapes(spec: spec)
        let objects = shapes.enumerated().map { i, shape in
            EmbroideryObject(name: "Letter \(i)", shape: shape,
                              stitchType: StitchTypeClassifier.classify(shape: shape, parameters: StitchGenerationParameters()),
                              threadColor: .generic(RGBColor(hex: 0x000000)))
        }
        #expect(objects.allSatisfy { $0.stitchType == .satin }, "normal bold letters at a real size should classify as satin")
        let doc = StitchDocument(name: "Lettering", physicalWidthMM: 40, physicalHeightMM: 20, objects: objects)
        let plan = try DigitizePipeline.flatten(doc)
        #expect(plan.stitchCount > 0)
    }
}
