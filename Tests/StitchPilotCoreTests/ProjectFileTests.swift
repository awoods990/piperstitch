import Testing
import Foundation
@testable import StitchPilotCore

struct ProjectFileTests {
    func makeDocument() -> StitchDocument {
        // A 20x3mm column -- narrow enough to be valid satin content,
        // unlike a full square (which would legitimately exceed the
        // default max satin width and throw, as any real satin generator
        // should for content that isn't actually a column).
        let shape = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(20, 0), Point2D(20, 3), Point2D(0, 3)], closed: true)])
        var params = StitchGenerationParameters()
        params.satinDensityMM = 0.35
        params.underlayType = .centerRun
        let object = EmbroideryObject(name: "Column", shape: shape, stitchType: .satin,
                                       threadColor: ThreadColor(name: "Custom Blue", brand: "Test", catalogNumber: "42", rgb: RGBColor(hex: 0x1144FF)),
                                       parameters: params)
        return StitchDocument(name: "RoundTripProject", physicalWidthMM: 20, physicalHeightMM: 3, objects: [object])
    }

    @Test func roundTripPreservesEverything() throws {
        let original = makeDocument()
        let data = try ProjectFileFormat.write(original)
        let loaded = try ProjectFileFormat.read(data)

        #expect(loaded.name == original.name)
        #expect(loaded.physicalWidthMM == original.physicalWidthMM)
        #expect(loaded.objects.count == 1)
        #expect(loaded.objects[0].stitchType == .satin)
        #expect(loaded.objects[0].parameters.satinDensityMM == 0.35)
        #expect(loaded.objects[0].parameters.underlayType == .centerRun)
        #expect(loaded.objects[0].threadColor.name == "Custom Blue")
        #expect(loaded.objects[0].threadColor.catalogNumber == "42")
        #expect(loaded.objects[0].threadColor.rgb == RGBColor(hex: 0x1144FF))
        #expect(loaded.objects[0].shape.subPaths[0].points.count == 4)
    }

    @Test func loadedDocumentFlattensSuccessfully() throws {
        let data = try ProjectFileFormat.write(makeDocument())
        let loaded = try ProjectFileFormat.read(data)
        let plan = try DigitizePipeline.flatten(loaded)
        #expect(plan.stitchCount > 0)
    }

    @Test func futureFormatVersionThrows() throws {
        var project = ProjectFile(document: makeDocument())
        project.formatVersion = ProjectFile.currentFormatVersion + 1
        let encoder = JSONEncoder()
        let data = try encoder.encode(project)
        #expect(throws: ProjectFileError.self) {
            _ = try ProjectFileFormat.read(data)
        }
    }

    @Test func corruptDataThrows() {
        #expect(throws: (any Error).self) {
            _ = try ProjectFileFormat.read("not json".data(using: .utf8)!)
        }
    }
}
