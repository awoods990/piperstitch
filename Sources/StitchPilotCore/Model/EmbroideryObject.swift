import Foundation

/// The embroidery technique used to sew one object. See DIGITIZING_ENGINE.md
/// for the selection rules; this is deliberately a closed, small set at
/// Phase 1 and grows through the phases in the project spec (§11).
public enum StitchType: String, Codable, Sendable, CaseIterable {
    case runningStitch
    case tripleRun
    case satin
    case tatamiFill
}

/// Per-object embroidery-generation parameters. Every object carries its own
/// copy (spec §10: "Every object should contain its own embroidery
/// parameters") — there is no single global density/underlay/compensation.
/// Fields are grouped by phase; later phases add fields rather than replace
/// this type, so old `.stitchpilot` documents keep decoding (Codable
/// defaults via `decodeIfPresent` as fields are added).
public struct StitchGenerationParameters: Codable, Hashable, Sendable {
    // Phase 1/2 — running stitch
    public var stitchLengthMM: Double = 3.0
    public var minStitchLengthMM: Double = 0.4
    // Phase 3 — general stitch filtering (spec §30), applied to every
    // object's generated points regardless of stitch type.
    public var maxStitchLengthMM: Double = 12.0

    // Phase 2 — satin
    public var satinDensityMM: Double = 0.4      // spacing between satin crossings
    public var maxSatinWidthMM: Double = 12.0    // beyond this, split or convert to fill

    // Phase 2 — tatami fill
    public var fillSpacingMM: Double = 0.4
    public var fillAngleDegrees: Double = 0.0
    public var fillRowStaggerMM: Double = 1.2

    // Phase 3 — underlay (spec §16)
    /// `nil` = automatic (the engine picks a sensible default per stitch
    /// type — see `UnderlayGenerator`). Professional users can override.
    public var underlayType: UnderlayType? = nil
    public var underlayStitchLengthMM: Double = 3.0
    /// How far a center-run underlay's endpoints fall short of the
    /// column's true end caps, and how far an edge-run underlay insets from
    /// the shape boundary — keeps underlay from poking out past the final
    /// satin/fill coverage.
    public var underlayInsetMM: Double = 1.0

    // Phase 3 — pull compensation (spec §17)
    /// `nil` = automatic (see `PullCompensationCalculator`). Only applies
    /// to satin/fill; running stitch has no "width" to compensate.
    public var pullCompensationMM: Double? = nil

    // Phase 3 — reserved for object overlap / inset-outset (next).

    public init() {}
}

public enum UnderlayType: String, Codable, Sendable, CaseIterable {
    case none
    case centerRun
    case edgeRun
}

/// One embroidery object: a geometric shape plus everything needed to sew
/// it. This — not the flat stitch list — is the neutral master
/// representation (spec §10, §79): the artwork says what the customer wants
/// to see, the object graph says how the machine must sew it, and the
/// flat `StitchPlan` is generated output derived from this, never hand-edited
/// directly.
public struct EmbroideryObject: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var shape: VectorShape
    public var stitchType: StitchType
    public var threadColor: ThreadColor
    public var parameters: StitchGenerationParameters

    public init(id: UUID = UUID(), name: String, shape: VectorShape, stitchType: StitchType,
                threadColor: ThreadColor, parameters: StitchGenerationParameters = StitchGenerationParameters()) {
        self.id = id
        self.name = name
        self.shape = shape
        self.stitchType = stitchType
        self.threadColor = threadColor
        self.parameters = parameters
    }
}

/// The root editable project document — the ".stitchpilot" master format
/// (spec §6). Machine files (.dst, .pes, ...) are generated FROM this; they
/// are manufacturing output, not the source of truth, and are never read
/// back into this model except through the lossy best-effort "import
/// existing embroidery" path (spec §40).
public struct StitchDocument: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var name: String
    /// Design's finished physical size, in millimeters. All object geometry
    /// is authored/stored relative to this — resizing regenerates stitches
    /// from geometry rather than scaling stitch coordinates (spec §39).
    public var physicalWidthMM: Double
    public var physicalHeightMM: Double
    /// Sewing order == array order.
    public var objects: [EmbroideryObject]

    public init(name: String, physicalWidthMM: Double, physicalHeightMM: Double, objects: [EmbroideryObject] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.name = name
        self.physicalWidthMM = physicalWidthMM
        self.physicalHeightMM = physicalHeightMM
        self.objects = objects
    }

    public var boundingBox: BoundingBox {
        var box = BoundingBox.empty
        for obj in objects { box = box.union(obj.shape.boundingBox) }
        return box
    }
}
