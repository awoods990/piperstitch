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

    @Test func manualStitchTypeOverrideSurvivesRoundTrip() throws {
        var original = makeDocument()
        original.objects[0].stitchTypeIsManualOverride = true
        let data = try ProjectFileFormat.write(original)
        let loaded = try ProjectFileFormat.read(data)
        #expect(loaded.objects[0].stitchTypeIsManualOverride == true)
    }

    /// A `.stitchpilot` file saved before `stitchTypeIsManualOverride`
    /// existed has no such key in its JSON -- must still decode, treating
    /// the object as not manually overridden (matching every object saved
    /// under the old format, which were all auto-classified).
    @Test func oldProjectFileWithoutManualOverrideKeyStillDecodes() throws {
        let data = try ProjectFileFormat.write(makeDocument())
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var document = try #require(json["document"] as? [String: Any])
        var objects = try #require(document["objects"] as? [[String: Any]])
        objects[0].removeValue(forKey: "stitchTypeIsManualOverride")
        document["objects"] = objects
        json["document"] = document
        let strippedData = try JSONSerialization.data(withJSONObject: json)

        let loaded = try ProjectFileFormat.read(strippedData)
        #expect(loaded.objects[0].stitchTypeIsManualOverride == false)
        #expect(loaded.objects[0].stitchType == .satin)
    }

    /// A genuinely old `.stitchpilot` file predates every "Phase 3+"
    /// parameter field -- underlay, compensation, `zigzagUnderlay*`,
    /// `fabricType` -- not just the newest one. Every one of those fields
    /// is declared non-`Optional` with a default value, which Swift's
    /// *synthesized* `Decodable` does NOT actually honor for a missing key
    /// (only `Optional` properties get that treatment automatically) --
    /// confirmed directly: a bare `Codable` struct with a non-optional
    /// `Double = 1.0` field throws `keyNotFound` decoding JSON missing
    /// that key, it doesn't silently use the default. Without
    /// `StitchGenerationParameters`'s own explicit `init(from:)`, a file
    /// saved before ANY of these fields existed would fail to open at
    /// all. Strips every phase-3+ key to simulate that.
    @Test func veryOldProjectFileMissingEveryPhase3ParameterFieldStillDecodes() throws {
        let data = try ProjectFileFormat.write(makeDocument())
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var document = try #require(json["document"] as? [String: Any])
        var objects = try #require(document["objects"] as? [[String: Any]])
        var parameters = try #require(objects[0]["parameters"] as? [String: Any])
        for key in ["maxStitchLengthMM", "maxSatinWidthMM", "minSatinWidthMM", "fillRowStaggerMM",
                    "underlayStitchLengthMM", "underlayInsetMM", "zigzagUnderlaySpacingMM", "zigzagUnderlayWidthThresholdMM",
                    "underlayType", "pullCompensationMM", "pushCompensationMM", "fabricType"] {
            parameters.removeValue(forKey: key)
        }
        objects[0]["parameters"] = parameters
        document["objects"] = objects
        json["document"] = document
        let strippedData = try JSONSerialization.data(withJSONObject: json)

        let loaded = try ProjectFileFormat.read(strippedData)
        let defaults = StitchGenerationParameters()
        #expect(loaded.objects[0].parameters.maxSatinWidthMM == defaults.maxSatinWidthMM)
        #expect(loaded.objects[0].parameters.zigzagUnderlaySpacingMM == defaults.zigzagUnderlaySpacingMM)
        #expect(loaded.objects[0].parameters.underlayType == nil)
        #expect(loaded.objects[0].parameters.pullCompensationMM == nil)
        #expect(loaded.objects[0].parameters.fabricType == .standard)
        // satinDensityMM was explicitly set (0.35) and its own key is
        // still present -- must survive untouched, not get overwritten
        // by the default just because OTHER keys were stripped.
        #expect(loaded.objects[0].parameters.satinDensityMM == 0.35)
        let plan = try DigitizePipeline.flatten(loaded)
        #expect(plan.stitchCount > 0)
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
