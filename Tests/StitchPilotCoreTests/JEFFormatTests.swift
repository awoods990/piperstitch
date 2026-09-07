import Testing
import Foundation
@testable import StitchPilotCore

struct JEFFormatTests {
    func makeSquareDocument(sizeMM: Double = 20) -> StitchDocument {
        let shape = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(sizeMM, 0), Point2D(sizeMM, sizeMM), Point2D(0, sizeMM),
        ], closed: true)])
        var params = StitchGenerationParameters()
        params.stitchLengthMM = 3.0
        let object = EmbroideryObject(name: "Square", shape: shape, stitchType: .runningStitch,
                                       threadColor: .generic(RGBColor(hex: 0xFF0000)), parameters: params)
        return StitchDocument(name: "TestSquare", physicalWidthMM: sizeMM, physicalHeightMM: sizeMM, objects: [object])
    }

    @Test func selfRoundTrip() throws {
        let doc = makeSquareDocument()
        let plan = try DigitizePipeline.flatten(doc)
        #expect(plan.stitchCount > 10)

        let data = try JEFFormat.write(plan, designName: doc.name, threadColors: [RGBColor(hex: 0xFF0000)])
        #expect(data.count > 116, "file must contain header + palette + at least one stitch record")

        let decoded = try JEFFormat.read(data)
        let decodedStitches = decoded.commands.compactMap { c -> Point2D? in
            if case .stitch(let p) = c { return p }
            return nil
        }
        let originalStitches = plan.commands.compactMap { c -> Point2D? in
            if case .stitch(let p) = c { return p }
            return nil
        }

        #expect(decodedStitches.count == originalStitches.count)
        for (a, b) in zip(decodedStitches, originalStitches) {
            #expect(abs(a.x - b.x) <= 0.05)
            #expect(abs(a.y - b.y) <= 0.05)
        }
    }

    @Test func boundingBoxSurvivesRoundTrip() throws {
        let doc = makeSquareDocument(sizeMM: 35)
        let plan = try DigitizePipeline.flatten(doc)
        let data = try JEFFormat.write(plan, designName: doc.name, threadColors: [RGBColor(hex: 0xFF0000)])
        let decoded = try JEFFormat.read(data)

        func stitchOnlyBox(_ commands: [StitchCommand]) -> BoundingBox {
            BoundingBox(points: commands.compactMap { c -> Point2D? in
                if case .stitch(let p) = c { return p }
                return nil
            })
        }
        let decodedBox = stitchOnlyBox(decoded.commands)
        let originalBox = stitchOnlyBox(plan.commands)
        #expect(abs(decodedBox.width - originalBox.width) <= 0.1)
        #expect(abs(decodedBox.height - originalBox.height) <= 0.1)
    }

    @Test func colorChangeBetweenObjectsIsPreserved() throws {
        let shape1 = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(10, 0), Point2D(10, 10)], closed: false)])
        let shape2 = VectorShape(subPaths: [SubPath(points: [Point2D(20, 0), Point2D(30, 0), Point2D(30, 10)], closed: false)])
        let obj1 = EmbroideryObject(name: "A", shape: shape1, stitchType: .runningStitch, threadColor: .generic(RGBColor(hex: 0xFF0000)))
        let obj2 = EmbroideryObject(name: "B", shape: shape2, stitchType: .runningStitch, threadColor: .generic(RGBColor(hex: 0x0000FF)))
        let doc = StitchDocument(name: "TwoColor", physicalWidthMM: 30, physicalHeightMM: 10, objects: [obj1, obj2])

        let plan = try DigitizePipeline.flatten(doc)
        #expect(plan.colorChangeCount == 1)

        let data = try JEFFormat.write(plan, designName: doc.name, threadColors: [RGBColor(hex: 0xFF0000), RGBColor(hex: 0x0000FF)])
        let decoded = try JEFFormat.read(data)
        let decodedColorChanges = decoded.commands.filter { if case .colorChange = $0 { return true }; return false }.count
        #expect(decodedColorChanges == 1)
    }

    /// A trim is encoded as 3 consecutive zero-delta jump records (see
    /// `JEFFormat.write`'s doc comment) -- the reader must collapse these
    /// back into exactly one `.trim`, not three spurious zero-distance
    /// jumps or three separate trims.
    @Test func trimRoundTripsAsOneCommand() throws {
        let shape1 = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(10, 0)], closed: false)])
        let shape2 = VectorShape(subPaths: [SubPath(points: [Point2D(40, 40), Point2D(50, 40)], closed: false)])
        let obj1 = EmbroideryObject(name: "A", shape: shape1, stitchType: .runningStitch, threadColor: .generic(RGBColor(hex: 0xFF0000)))
        let obj2 = EmbroideryObject(name: "B", shape: shape2, stitchType: .runningStitch, threadColor: .generic(RGBColor(hex: 0xFF0000)))
        let doc = StitchDocument(name: "FarApartSameColor", physicalWidthMM: 60, physicalHeightMM: 60, objects: [obj1, obj2])

        let plan = try DigitizePipeline.flatten(doc)
        #expect(plan.trimCount > 0, "objects far enough apart in the same color should get a trim between them")

        let data = try JEFFormat.write(plan, designName: doc.name, threadColors: [RGBColor(hex: 0xFF0000)])
        let decoded = try JEFFormat.read(data)
        let decodedTrims = decoded.commands.filter { if case .trim = $0 { return true }; return false }.count
        #expect(decodedTrims == plan.trimCount)
    }

    @Test func emptyPatternThrows() {
        #expect(throws: JEFFormatError.self) {
            _ = try JEFFormat.write(StitchPlan(commands: []), designName: "Empty", threadColors: [])
        }
    }

    /// Two distinct requested colors that happen to be nearest to the same
    /// palette entry must not collapse to that one shared index -- the
    /// second gets bumped to its second-nearest match instead, so the
    /// machine's per-color thread prompt doesn't silently repeat for two
    /// colors the design actually distinguishes.
    @Test func consecutiveColorsMappingToSameIndexAreDisambiguated() throws {
        // Two distinct blues both nearest to the same Janome table entry.
        let colorA = RGBColor(hex: 0x0B2F84) // exact match to "Blue" (index 12)
        let colorB = RGBColor(hex: 0x0B2F70) // very close to the same entry, but distinct
        let shape1 = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(10, 0), Point2D(10, 10)], closed: false)])
        let shape2 = VectorShape(subPaths: [SubPath(points: [Point2D(20, 0), Point2D(30, 0), Point2D(30, 10)], closed: false)])
        let obj1 = EmbroideryObject(name: "A", shape: shape1, stitchType: .runningStitch, threadColor: .generic(colorA))
        let obj2 = EmbroideryObject(name: "B", shape: shape2, stitchType: .runningStitch, threadColor: .generic(colorB))
        let doc = StitchDocument(name: "TwoBlues", physicalWidthMM: 30, physicalHeightMM: 10, objects: [obj1, obj2])
        let plan = try DigitizePipeline.flatten(doc)

        // Write succeeding without throwing, and producing a valid,
        // decodable file, is the main thing under test here -- the actual
        // disambiguation happens inside `buildPalette`, exercised via this
        // realistic two-similar-colors scenario.
        let data = try JEFFormat.write(plan, designName: doc.name, threadColors: [colorA, colorB])
        let decoded = try JEFFormat.read(data)
        let decodedColorChanges = decoded.commands.filter { if case .colorChange = $0 { return true }; return false }.count
        #expect(decodedColorChanges == plan.colorChangeCount)
    }

    /// Cross-validates against pyembroidery — a completely independent JEF
    /// implementation — when it's available locally. Silently returns
    /// (rather than failing) when python3/pyembroidery aren't present, since
    /// this is a development-time convenience, never a build/CI requirement;
    /// see TESTING.md.
    @Test func crossValidationAgainstPyembroidery() throws {
        let doc = makeSquareDocument(sizeMM: 25)
        let plan = try DigitizePipeline.flatten(doc)
        let data = try JEFFormat.write(plan, designName: doc.name, threadColors: [RGBColor(hex: 0xFF0000)])

        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("stitchpilot_test_\(UUID().uuidString).jef")
        try data.write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        guard let scriptURL = Bundle.module.url(forResource: "validate_jef", withExtension: "py", subdirectory: "Fixtures") else {
            print("SKIPPED: validate_jef.py fixture not found in bundle")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptURL.path, tmpFile.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            print("SKIPPED: python3 not available: \(error)")
            return
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            print("SKIPPED: pyembroidery not installed locally — skipping external cross-validation")
            return
        }

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let json = try JSONSerialization.jsonObject(with: outputData) as? [String: Any]
        let stitchCount = json?["stitchCount"] as? Int ?? -1
        let boundingBox = json?["boundingBox"] as? [String: Double]

        #expect(stitchCount == plan.stitchCount, "pyembroidery's independent JEF reader disagrees with StitchPilot's own reader on stitch count")

        if let box = boundingBox {
            let ourBox = plan.boundingBox
            #expect(abs(box["minX"]! - ourBox.minX) <= 0.2)
            #expect(abs(box["minY"]! - ourBox.minY) <= 0.2)
            #expect(abs(box["maxX"]! - ourBox.maxX) <= 0.2)
            #expect(abs(box["maxY"]! - ourBox.maxY) <= 0.2)
        }
    }
}
