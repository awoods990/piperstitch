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

    /// Same design, two formats, so the two readers must place the stitches
    /// in the *same orientation* -- a coarse occupancy grid of each,
    /// normalised to its own bounding box, has to match. A reader that gets
    /// the Y sign wrong decodes a top-to-bottom mirror image, which passes
    /// every size and count check above and is exactly the bug this guards
    /// against: DST/EXP/JEF store Y pointing up, PES/VP3 pointing down, and
    /// for a long time the DST/EXP/JEF writers (and readers) applied no flip
    /// because pyembroidery's internal model was assumed to be Y-up. Every
    /// exported DST sewed upside-down until a professionally digitized
    /// design supplied as both DST and PES showed the two readers
    /// disagreeing. Guards against a same-sign mistake in either reader,
    /// since the writers are checked against the readers by round trip.
    private func occupancyGrid(_ commands: [StitchCommand], cells: Int) -> [Double] {
        let points = commands.compactMap { if case .stitch(let p) = $0 { return p } else { return nil } }
        let box = BoundingBox(points: points)
        var grid = [Double](repeating: 0, count: cells * cells)
        for p in points {
            let cx = min(cells - 1, Int((p.x - box.minX) / max(box.width, 1e-9) * Double(cells)))
            let cy = min(cells - 1, Int((p.y - box.minY) / max(box.height, 1e-9) * Double(cells)))
            grid[cy * cells + cx] += 1
        }
        let total = max(1, Double(points.count))
        return grid.map { $0 / total }
    }

    private func assertSameOrientation(dst: String, pes: String) throws {
        let a = occupancyGrid(try DSTFormat.read(Data(contentsOf: fixtureURL(dst))).commands, cells: 6)
        let b = occupancyGrid(try PESFormat.read(Data(contentsOf: fixtureURL(pes))).commands, cells: 6)
        let flipped = (0..<6).flatMap { row in (0..<6).map { col in b[(5 - row) * 6 + col] } }
        func distance(_ x: [Double], _ y: [Double]) -> Double { zip(x, y).reduce(0) { $0 + abs($1.0 - $1.1) } }
        let same = distance(a, b), mirrored = distance(a, flipped)
        #expect(same < mirrored, "\(dst) vs \(pes): the two readers decode the same design mirrored top-to-bottom (distance as-is \(same), distance to the vertical mirror \(mirrored)) -- one of them has the Y sign wrong")
        #expect(same < 0.25, "\(dst) vs \(pes): stitch distribution should broadly agree between formats (distance \(same))")
    }

    @Test func dstAndPESDecodeTheSameDesignInTheSameOrientation() throws {
        try assertSameOrientation(dst: "scene.dst", pes: "scene.pes")
        try assertSameOrientation(dst: "random1-ew.dst", pes: "random1-ew.pes")
    }
}
