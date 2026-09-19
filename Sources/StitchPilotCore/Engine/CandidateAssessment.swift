import Foundation

/// Whether an imported image is a reasonable candidate for digitizing at
/// all -- decided before the customer spends the setup steps on it, and
/// again from the readiness report after the first digitize. PiperStitch
/// handles the great majority of logos and artwork; a photograph of a
/// sew-out, a scan, a screenshot of a gradient illustration are the
/// exceptions, and a plain explanation beats a poor stitch file. Each
/// reason names the measurement it rests on, so the message is specific
/// to this image rather than a generic disclaimer.
public struct CandidateAssessment: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable { case good, caution, poor }
    public struct Reason: Codable, Sendable, Equatable {
        /// A stable key the web app can act on (`photograph`, `fragmented`, `lowResolution`, `poorResult`).
        public var code: String
        /// One or two sentences, plain, with the numbers that led here.
        public var message: String
        public init(code: String, message: String) { self.code = code; self.message = message }
    }
    public var verdict: Verdict
    public var reasons: [Reason]

    public init(verdict: Verdict, reasons: [Reason]) { self.verdict = verdict; self.reasons = reasons }

    /// Continuous tone: the mean Delta-E from each pixel to its assigned
    /// colour, at or above this, says the image is gradients, not flat
    /// colour. Flat logos sit at 1-5; sew-out photographs and scans at
    /// 8-10; shaded illustrations in between.
    public static let photographMeanDistance = 7.5
    /// ...together with this share of pixels sitting between two colours.
    /// Anti-aliasing on a clean logo is 1-10 %; a photograph or a soft
    /// scan is a quarter or more, and there is no edge to follow.
    public static let photographAmbiguousFraction = 0.25
    /// Fragmentation: a trace of at least this many pieces, with at least
    /// `fragmentedTinyShare` of them under 1 % of the design's size, is the
    /// dust of a scan or a textured photograph, not artwork.
    public static let fragmentedMinimumShapes = 150
    public static let fragmentedTinyShare = 0.5
    /// A short side under this many pixels, on an image whose edges are
    /// already soft, cannot hold its detail at embroidery size.
    public static let lowResolutionPixels = 200
    public static let lowResolutionAmbiguousFraction = 0.15
    /// After digitizing: a readiness score under this is not a result to
    /// hand over without a word.
    public static let poorResultScore = 55

    /// From what the importer found. `imageWidth`/`imageHeight` are the
    /// decoded pixel dimensions.
    public static func assess(importResult result: ImageImportResult) -> CandidateAssessment {
        var reasons: [Reason] = []
        var verdict = Verdict.good
        let st = result.colorStatistics
        let shapes = result.shapes
        var box = BoundingBox.empty
        for shape in shapes { box = box.union(shape.boundingBox) }
        let designExtent = max(box.width, box.height)
        let tiny = shapes.filter { let b = $0.boundingBox; return max(b.width, b.height) < designExtent * 0.01 }.count

        if st.meanColorDistance >= photographMeanDistance && st.ambiguousFraction >= photographAmbiguousFraction {
            verdict = .poor
            reasons.append(Reason(code: "photograph", message: String(format:
                "It reads as a photograph or a scan rather than artwork: %.0f%% of its pixels sit between colours instead of on one, and the colours vary continuously. Embroidery is flat thread colours with a clean edge to follow, and this image has neither.",
                st.ambiguousFraction * 100)))
        }
        if shapes.count >= fragmentedMinimumShapes, Double(tiny) / Double(shapes.count) >= fragmentedTinyShare {
            verdict = .poor
            reasons.append(Reason(code: "fragmented", message:
                "Tracing it produced \(shapes.count) separate pieces, \(tiny) of them under 1% of the design's size -- the grain of a scan or a textured photograph, not the shapes of a logo. Sewn, that is thousands of specks and trims."))
        }
        let shortSide = min(result.pixelWidth, result.pixelHeight)
        if shortSide < lowResolutionPixels, st.ambiguousFraction >= lowResolutionAmbiguousFraction, shapes.count >= 8 {
            if verdict == .good { verdict = .caution }
            reasons.append(Reason(code: "lowResolution", message:
                "It is only \(shortSide) pixels on its short side and its edges are already soft (\(Int((st.ambiguousFraction * 100).rounded()))% of pixels are blended). At embroidery size each pixel is close to a millimetre, so every edge will be stepped and the fine detail will not survive."))
        }
        return CandidateAssessment(verdict: verdict, reasons: reasons)
    }

    /// From the readiness report after the first digitize: the score and
    /// the issues that cost the most.
    public static func assess(report: EmbroideryReadinessReport) -> CandidateAssessment {
        guard report.score < poorResultScore else { return CandidateAssessment(verdict: .good, reasons: []) }
        let worst = report.issues.filter { $0.severity != .info }.sorted { $0.scorePenalty > $1.scorePenalty }.prefix(3)
        var reasons = [Reason(code: "poorResult", message:
            "Digitized, it scores \(report.score) out of 100 for embroidery readiness. The largest problems:")]
        reasons += worst.map { Reason(code: "issue", message: $0.message) }
        return CandidateAssessment(verdict: .poor, reasons: reasons)
    }
}
