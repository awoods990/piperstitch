import Foundation
import Vapor
import StitchPilotCore

// JSON shapes the browser and server agree on. The core model types
// (StitchDocument, EmbroideryObject, VectorShape, ThreadColor...) are
// already Codable and cross the wire as-is; only the stitch *plan* and
// the readiness report get a compact form here, since a plan can be tens
// of thousands of commands and the enum's synthesized encoding is verbose.

extension ImportedSource: Content {}
extension StitchDocument: Content {}
extension TextLine: Content {}

struct ImportResponse: Content {
    var source: ImportedSource
    var recommendedWidthMM: Double
    var recommendedHeightMM: Double
    /// Width / height of the artwork, for aspect-locked size editing.
    var aspectRatio: Double
    /// The artwork's page or card colour, when the importer found one and
    /// it is worth previewing on (`StitchRenderer.isPreviewGround`): the
    /// editor draws the fabric that colour so white thread shows.
    var backgroundColor: RGBColor?
    /// Lines of text found by their geometry (`TextLineFinder`), pixel
    /// space, so the setup can ask what they say and whether to re-type,
    /// keep or leave them out.
    var textLines: [TextLine]
}

struct BuildRequest: Content {
    var source: ImportedSource
    var name: String
    var widthMM: Double
    var heightMM: Double
    var matchToThreadLibrary: Bool?
    /// The user's own thread inventory, when they've defined one.
    var palette: [ThreadColor]?
    var fabricType: FabricType?
    var threadWeight: ThreadWeight?
    /// Source shapes to leave out -- the letters of text lines the user
    /// chose to drop or re-type. Passing this (even empty) means the
    /// client has decided about every text line; absent, the server
    /// leaves out any line whose letters are too small to sew at this
    /// size and reports the count on the document.
    var dropShapeIndices: [Int]?
    /// How many text lines the client left out as too small, for the
    /// readiness report (re-typed lines don't count).
    var omittedTextLines: Int?
}

struct ResizeRequest: Content {
    var document: StitchDocument
    var widthMM: Double
    var heightMM: Double
}

struct DocumentResponse: Content {
    var document: StitchDocument
}

struct DigitizeRequest: Content {
    var document: StitchDocument
    var hoopWidthMM: Double?
    var hoopHeightMM: Double?
}

/// One row per command: `[code, x, y]` in design millimeters, rounded to
/// 0.01 mm (the machine formats themselves resolve to 0.1 mm). Codes:
/// 0 stitch, 1 jump, 2 color change, 3 trim, 4 stop, 5 end -- non-movement
/// rows carry the last position so a drawing loop needs no special cases.
struct WirePlan: Content {
    var commands: [[Double]]

    init(_ plan: StitchPlan) {
        var rows: [[Double]] = []
        rows.reserveCapacity(plan.commands.count)
        var lastX = 0.0, lastY = 0.0
        func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        for command in plan.commands {
            let code: Double
            switch command {
            case .stitch(let p): code = 0; lastX = r(p.x); lastY = r(p.y)
            case .jump(let p): code = 1; lastX = r(p.x); lastY = r(p.y)
            case .colorChange: code = 2
            case .trim: code = 3
            case .stop: code = 4
            case .end: code = 5
            }
            rows.append([code, lastX, lastY])
        }
        commands = rows
    }
}

struct WireIssue: Content {
    var severity: String
    var message: String
    var scorePenalty: Int
}

struct WireReport: Content {
    var score: Int
    var isReadyToSew: Bool
    var issues: [WireIssue]

    init(_ report: EmbroideryReadinessReport) {
        score = report.score
        isReadyToSew = report.isReadyToSew
        issues = report.issues.map { WireIssue(severity: $0.severity.rawValue, message: $0.message, scorePenalty: $0.scorePenalty) }
    }
}

struct WireStats: Content {
    var stitchCount: Int
    var colorChangeCount: Int
    var trimCount: Int
    var maxStitchLengthMM: Double
    var totalThreadMM: Double
    var bounds: BoundingBox
    /// `RunTimeEstimator` at its default machine speed (C5).
    var estimatedRunSeconds: Double

    init(_ plan: StitchPlan) {
        stitchCount = plan.stitchCount
        colorChangeCount = plan.colorChangeCount
        trimCount = plan.trimCount
        maxStitchLengthMM = plan.maxStitchLength()
        totalThreadMM = plan.totalStitchLength
        bounds = plan.boundingBox
        estimatedRunSeconds = RunTimeEstimator.estimate(plan).totalSeconds
    }
}

struct DigitizeResponse: Content {
    var plan: WirePlan
    var colors: [ThreadColor]
    var report: WireReport
    var stats: WireStats
    var elapsedMS: Int
}

struct ExportRequest: Content {
    var document: StitchDocument
}

// MARK: - Catalog (the UI's pick-lists, straight from the engine's own tables)

struct CatalogSize: Content { var name: String; var widthMM: Double; var heightMM: Double }
struct CatalogFabric: Content { var id: String; var displayName: String; var shortName: String; var isHeadwear: Bool; var stabilizer: String }
struct CatalogColorPreset: Content { var id: String; var maxColors: Int }
struct CatalogNamed: Content { var id: String; var displayName: String }

struct CatalogResponse: Content {
    var hoops: [CatalogSize]
    var garmentPresets: [CatalogSize]
    var fabrics: [CatalogFabric]
    var colorPresets: [CatalogColorPreset]
    var threadPalette: [ThreadColor]
    var stitchTypes: [String]
    var fillPatterns: [CatalogNamed]
    var underlayTypes: [String]
    var exportFormats: [String]
    var defaultParameters: StitchGenerationParameters
}

extension StitchGenerationParameters: Content {}
extension ThreadColor: Content {}
