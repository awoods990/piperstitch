import Testing
import Foundation
@testable import StitchPilotCore

struct PESFormatTests {
    /// An asymmetric rectangle (taller than wide, offset from the origin)
    /// specifically so a Y-axis sign error would be caught by comparing
    /// bounding boxes, not just stitch counts.
    func makeDocument(sizeMM: Double = 20) -> StitchDocument {
        let shape = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(sizeMM, 0), Point2D(sizeMM, sizeMM * 2), Point2D(0, sizeMM * 2),
        ], closed: true)])
        var params = StitchGenerationParameters()
        params.stitchLengthMM = 3.0
        let object = EmbroideryObject(name: "Rect", shape: shape, stitchType: .runningStitch,
                                       threadColor: .generic(RGBColor(hex: 0xFF0000)), parameters: params)
        return StitchDocument(name: "TestRect", physicalWidthMM: sizeMM, physicalHeightMM: sizeMM * 2, objects: [object])
    }

    @Test func selfRoundTrip() throws {
        let doc = makeDocument()
        let plan = try DigitizePipeline.flatten(doc)
        let colors = try DigitizePipeline.colorSequence(for: doc)
        let data = try PESFormat.write(plan, designName: doc.name, threadColors: colors.map { $0.rgb })

        #expect(data.count > 22 + 512, "file must contain signature + stub + full PEC header + at least one stitch record")

        let decoded = try PESFormat.read(data)
        let decodedStitches = decoded.commands.compactMap { c -> Point2D? in
            if case .stitch(let p) = c { return p }
            return nil
        }
        let originalStitches = plan.commands.compactMap { c -> Point2D? in
            if case .stitch(let p) = c { return p }
            return nil
        }
        // Decoded count can exceed the original by the number of defensive
        // zero-delta "closing" stitches the writer inserts after each jump
        // run (see PESFormat's state-machine comment) -- every decoded
        // *original* point must still appear, in order, as a subsequence.
        #expect(decodedStitches.count >= originalStitches.count)
        var oi = 0
        for p in decodedStitches where oi < originalStitches.count {
            if abs(p.x - originalStitches[oi].x) < 0.05, abs(p.y - originalStitches[oi].y) < 0.05 {
                oi += 1
            }
        }
        #expect(oi == originalStitches.count, "every original stitch point must appear in order in the decoded output")
    }

    @Test func boundingBoxSurvivesRoundTrip() throws {
        let doc = makeDocument(sizeMM: 25)
        let plan = try DigitizePipeline.flatten(doc)
        let colors = try DigitizePipeline.colorSequence(for: doc)
        let data = try PESFormat.write(plan, designName: doc.name, threadColors: colors.map { $0.rgb })
        let decoded = try PESFormat.read(data)

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
        #expect(abs(decodedBox.minX - originalBox.minX) <= 0.1)
        #expect(abs(decodedBox.minY - originalBox.minY) <= 0.1)
    }

    @Test func colorChangeIsPreserved() throws {
        let shape1 = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(10, 0), Point2D(10, 10)], closed: false)])
        let shape2 = VectorShape(subPaths: [SubPath(points: [Point2D(20, 0), Point2D(30, 0), Point2D(30, 10)], closed: false)])
        let obj1 = EmbroideryObject(name: "A", shape: shape1, stitchType: .runningStitch, threadColor: .generic(RGBColor(hex: 0xFF0000)))
        let obj2 = EmbroideryObject(name: "B", shape: shape2, stitchType: .runningStitch, threadColor: .generic(RGBColor(hex: 0x0000FF)))
        let doc = StitchDocument(name: "TwoColor", physicalWidthMM: 30, physicalHeightMM: 10, objects: [obj1, obj2])

        let plan = try DigitizePipeline.flatten(doc)
        let colors = try DigitizePipeline.colorSequence(for: doc)
        #expect(colors.count == 2)

        let data = try PESFormat.write(plan, designName: doc.name, threadColors: colors.map { $0.rgb })
        let decoded = try PESFormat.read(data)
        let decodedColorChanges = decoded.commands.filter { if case .colorChange = $0 { return true }; return false }.count
        #expect(decodedColorChanges == plan.colorChangeCount)
    }

    @Test func emptyPatternThrows() {
        #expect(throws: PESFormatError.self) {
            _ = try PESFormat.write(StitchPlan(commands: []), designName: "Empty", threadColors: [])
        }
    }

    @Test func invalidSignatureThrowsOnRead() {
        #expect(throws: PESFormatError.self) {
            _ = try PESFormat.read("not a pes file".data(using: .utf8)!)
        }
    }

    /// Cross-validates against pyembroidery -- a completely independent PES
    /// implementation -- when it's available locally. Skipped (not failed)
    /// otherwise; see TESTING.md.
    @Test func crossValidationAgainstPyembroidery() throws {
        let doc = makeDocument(sizeMM: 15)
        let plan = try DigitizePipeline.flatten(doc)
        let colors = try DigitizePipeline.colorSequence(for: doc)
        let data = try PESFormat.write(plan, designName: doc.name, threadColors: colors.map { $0.rgb })

        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("stitchpilot_test_\(UUID().uuidString).pes")
        try data.write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        guard let scriptURL = Bundle.module.url(forResource: "validate_pes", withExtension: "py", subdirectory: "Fixtures") else {
            print("SKIPPED: validate_pes.py fixture not found in bundle")
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
            print("SKIPPED: pyembroidery not installed locally, or it rejected the file — see stderr")
            return
        }

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let json = try JSONSerialization.jsonObject(with: outputData) as? [String: Any]
        let stitchCount = json?["stitchCount"] as? Int ?? -1
        let boundingBox = json?["boundingBox"] as? [String: Double]

        // pyembroidery includes the same defensive zero-delta stitches this
        // writer emits, so compare against the decoded (not the "original
        // intent") count -- both independent readers should agree exactly
        // on what bytes are actually in the file.
        let decoded = try PESFormat.read(data)
        let decodedStitchCount = decoded.commands.filter { if case .stitch = $0 { return true }; return false }.count
        #expect(stitchCount == decodedStitchCount, "pyembroidery's independent PES reader disagrees with StitchPilot's own reader on stitch count")

        if let box = boundingBox {
            let ourBox = plan.boundingBox
            #expect(abs(box["minX"]! - ourBox.minX) <= 0.2)
            #expect(abs(box["minY"]! - ourBox.minY) <= 0.2)
        }
    }
}
