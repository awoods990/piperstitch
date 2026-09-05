import Testing
import Foundation
@testable import StitchPilotCore

/// Validates StitchPilot's format *readers* against real-world files
/// authored by a completely different codebase (EmbroidePy/samples, MIT
/// license — see Fixtures/ThirdPartySamples/README.md), not just against
/// StitchPilot's own writer's output. Every other round-trip test in this
/// suite proves "our reader can parse what our writer produces," which
/// can't catch a bug both sides happen to share; these tests are the one
/// place checking against files this project had no hand in creating,
/// per spec §18.
struct ThirdPartySampleTests {
    private func fixtureURL(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/ThirdPartySamples")!
    }

    @Test func readsRealWorldDSTFile() throws {
        let data = try Data(contentsOf: fixtureURL("random1-ew.dst"))
        let decoded = try DSTFormat.read(data)
        let stitchCount = decoded.commands.filter { if case .stitch = $0 { return true }; return false }.count
        #expect(stitchCount > 0, "a real DST file from another project should decode to at least some stitches")

        let points = decoded.commands.compactMap { $0.point }
        let box = BoundingBox(points: points)
        #expect(box.width > 0 && box.width < 500, "sanity: a real design's width should be a plausible physical size, not garbage from a parsing error")
        #expect(box.height > 0 && box.height < 500)
    }

    @Test func readsRealWorldPESFile() throws {
        let data = try Data(contentsOf: fixtureURL("random1-ew.pes"))
        let decoded = try PESFormat.read(data)
        let stitchCount = decoded.commands.filter { if case .stitch = $0 { return true }; return false }.count
        #expect(stitchCount > 0, "a real PES file from another project should decode to at least some stitches")

        let points = decoded.commands.compactMap { $0.point }
        let box = BoundingBox(points: points)
        #expect(box.width > 0 && box.width < 500)
        #expect(box.height > 0 && box.height < 500)
    }

    /// Both files are the same underlying "random1" design exported to two
    /// different formats by EmbroidePy/samples -- their stitch counts
    /// should be in the same ballpark (not identical: format-specific
    /// quantization, trim conventions, and defensive records differ, as
    /// documented in FORMATS.md) if both of StitchPilot's readers are
    /// decoding real content rather than garbage.
    @Test func dstAndPESAgreeOnRoughDesignSize() throws {
        let dstData = try Data(contentsOf: fixtureURL("random1-ew.dst"))
        let pesData = try Data(contentsOf: fixtureURL("random1-ew.pes"))

        let dstDecoded = try DSTFormat.read(dstData)
        let pesDecoded = try PESFormat.read(pesData)

        let dstStitches = dstDecoded.commands.filter { if case .stitch = $0 { return true }; return false }.count
        let pesStitches = pesDecoded.commands.filter { if case .stitch = $0 { return true }; return false }.count

        #expect(dstStitches > 0 && pesStitches > 0)
        let ratio = Double(max(dstStitches, pesStitches)) / Double(min(dstStitches, pesStitches))
        #expect(ratio < 2.0, "the same design in two formats shouldn't have wildly different stitch counts (DST: \(dstStitches), PES: \(pesStitches))")
    }
}
