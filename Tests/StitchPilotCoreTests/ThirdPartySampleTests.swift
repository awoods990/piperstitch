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

    private func stitchCount(_ commands: [StitchCommand]) -> Int {
        commands.filter { if case .stitch = $0 { return true }; return false }.count
    }

    /// A sane, non-garbage decode: at least some real stitches, and a
    /// physically plausible design size -- not a crash, and not silently
    /// "succeeding" with nonsense from a parsing error.
    private func assertSaneDecode(_ commands: [StitchCommand], file: String) {
        let count = stitchCount(commands)
        #expect(count > 0, "\(file): a real file from another project should decode to at least some stitches")
        let box = BoundingBox(points: commands.compactMap { $0.point })
        #expect(box.width > 0 && box.width < 500, "\(file): plausible physical width, not garbage from a parsing error")
        #expect(box.height > 0 && box.height < 500, "\(file): plausible physical height, not garbage from a parsing error")
    }

    @Test func readsRealWorldDSTFile() throws {
        let decoded = try DSTFormat.read(Data(contentsOf: fixtureURL("random1-ew.dst")))
        assertSaneDecode(decoded.commands, file: "random1-ew.dst")
    }

    @Test func readsRealWorldPESFile() throws {
        let decoded = try PESFormat.read(Data(contentsOf: fixtureURL("random1-ew.pes")))
        assertSaneDecode(decoded.commands, file: "random1-ew.pes")
    }

    /// The same "random1" design, but from a *different* originating
    /// software (Wilcom's own DST writer, not EmbroidePy's) -- catches a
    /// bug that happens to only affect one exporter's particular encoding
    /// conventions, which `random1-ew.dst` alone wouldn't.
    @Test func readsRealWorldDSTFileFromADifferentExporter() throws {
        let decoded = try DSTFormat.read(Data(contentsOf: fixtureURL("random1-wilcom.dst")))
        assertSaneDecode(decoded.commands, file: "random1-wilcom.dst")
    }

    /// Same idea for PES: Brother's own writer (v6), not EmbroidePy's.
    @Test func readsRealWorldPESFileFromADifferentExporter() throws {
        let decoded = try PESFormat.read(Data(contentsOf: fixtureURL("random1-brother-v6.pes")))
        assertSaneDecode(decoded.commands, file: "random1-brother-v6.pes")
    }

    /// A different design entirely ("scene", not "random1") -- guards
    /// against a reader that happens to work only for the one design shape
    /// already covered above.
    @Test func readsADifferentRealWorldDesign() throws {
        let dstDecoded = try DSTFormat.read(Data(contentsOf: fixtureURL("scene.dst")))
        let pesDecoded = try PESFormat.read(Data(contentsOf: fixtureURL("scene.pes")))
        assertSaneDecode(dstDecoded.commands, file: "scene.dst")
        assertSaneDecode(pesDecoded.commands, file: "scene.pes")
    }

    /// Both files are the same underlying design exported to two different
    /// formats by EmbroidePy/samples -- their stitch counts should be in
    /// the same ballpark (not identical: format-specific quantization, trim
    /// conventions, and defensive records differ, as documented in
    /// FORMATS.md) if both of StitchPilot's readers are decoding real
    /// content rather than garbage.
    private func assertRoughlyAgree(dst: String, pes: String) throws {
        let dstStitches = stitchCount(try DSTFormat.read(Data(contentsOf: fixtureURL(dst))).commands)
        let pesStitches = stitchCount(try PESFormat.read(Data(contentsOf: fixtureURL(pes))).commands)
        #expect(dstStitches > 0 && pesStitches > 0)
        let ratio = Double(max(dstStitches, pesStitches)) / Double(min(dstStitches, pesStitches))
        #expect(ratio < 2.0, "\(dst) vs \(pes): the same design in two formats shouldn't have wildly different stitch counts (DST: \(dstStitches), PES: \(pesStitches))")
    }

    @Test func dstAndPESAgreeOnRoughDesignSize() throws {
        try assertRoughlyAgree(dst: "random1-ew.dst", pes: "random1-ew.pes")
    }

    @Test func dstAndPESAgreeOnRoughDesignSizeForADifferentDesign() throws {
        try assertRoughlyAgree(dst: "scene.dst", pes: "scene.pes")
    }
}
