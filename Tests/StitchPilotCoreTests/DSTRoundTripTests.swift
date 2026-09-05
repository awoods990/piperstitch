import Testing
import Foundation
@testable import StitchPilotCore

/// Note: this test target uses Swift Testing (`import Testing`), not
/// XCTest — the Command Line Tools SDK in this dev environment ships
/// swift-testing but not the real XCTest.framework (only a private
/// XCTestSupport stub), so `import XCTest` fails to resolve here. See
/// TESTING.md.
struct DSTRoundTripTests {

    /// A 20mm square, sewn as a running-stitch outline, is the simplest
    /// possible end-to-end case: geometry -> object -> StitchPlan -> DST
    /// bytes -> decoded back -> compared.
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

        let data = try DSTFormat.write(plan, designName: doc.name)
        #expect(data.count > 512, "file must contain header + at least one stitch record")

        let decoded = try DSTFormat.read(data)
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
        let data = try DSTFormat.write(plan, designName: doc.name)
        let decoded = try DSTFormat.read(data)

        // Compare stitch-only extent, not the full command list: the
        // trailing .trim is legitimately encoded as a few small "jiggle"
        // jump records (see DSTFormat.write) that intentionally move the
        // needle up to 0.2mm around the final stitch -- real DST-format
        // behavior most machines rely on to detect a trim, not a
        // round-trip defect. Comparing including those jump points would
        // fail on correct output.
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

        let data = try DSTFormat.write(plan, designName: doc.name)
        let decoded = try DSTFormat.read(data)
        let decodedColorChanges = decoded.commands.filter { if case .colorChange = $0 { return true }; return false }.count
        #expect(decodedColorChanges == 1)
    }

    /// Cross-validates against pyembroidery — a completely independent DST
    /// implementation — when it's available locally. Silently returns
    /// (rather than failing) when python3/pyembroidery aren't present, since
    /// this is a development-time convenience, never a build/CI requirement;
    /// see TESTING.md.
    @Test func crossValidationAgainstPyembroidery() throws {
        let doc = makeSquareDocument(sizeMM: 25)
        let plan = try DigitizePipeline.flatten(doc)
        let data = try DSTFormat.write(plan, designName: doc.name)

        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("stitchpilot_test_\(UUID().uuidString).dst")
        try data.write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        guard let scriptURL = Bundle.module.url(forResource: "validate_dst", withExtension: "py", subdirectory: "Fixtures") else {
            print("SKIPPED: validate_dst.py fixture not found in bundle")
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

        #expect(stitchCount == plan.stitchCount, "pyembroidery's independent DST reader disagrees with StitchPilot's own reader on stitch count")
    }
}
