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
    /// Below this, a section of a column is too narrow to zigzag reliably
    /// (thread bunching, not enough fabric width for a stable satin
    /// crossing) and sews as a triple-run (bean-stitch) line instead — the
    /// narrow-width mirror of `maxSatinWidthMM`. `StitchTypeClassifier`
    /// checks this same value against a shape's *average* width up front
    /// (so a uniformly hairline shape never becomes `.satin` in the first
    /// place); `SatinColumnGenerator.generatePartial` checks it again
    /// per-crossing, since a column whose average is fine can still narrow
    /// below this in one section (e.g. a tapering stroke) without the
    /// classifier's single average ever seeing it.
    public var minSatinWidthMM: Double = 1.5

    // Phase 2 — tatami fill
    public var fillSpacingMM: Double = 0.4
    /// `nil` = automatic (see `FillAngleSelector`) — do not always fall
    /// back to a single fixed angle. Set explicitly to override.
    public var fillAngleDegrees: Double? = nil
    public var fillRowStaggerMM: Double = 1.2

    // Phase 3 — underlay (spec §16)
    /// `nil` = automatic (the engine picks a sensible default per stitch
    /// type — see `UnderlayGenerator`). Professional users can override.
    public var underlayType: UnderlayType? = nil
    public var underlayStitchLengthMM: Double = 3.0
    /// How far a center-run underlay's endpoints fall short of the
    /// column's true end caps, and how far an edge-run/zigzag underlay
    /// insets from the shape boundary — keeps underlay from poking out
    /// past the final satin/fill coverage.
    public var underlayInsetMM: Double = 1.0
    /// Row spacing for zigzag underlay — the "German underlay" technique
    /// (contour-walk + a wider, inset zigzag) used automatically for wider
    /// satin columns, sourced from studying Ink/Stitch's satin underlay —
    /// see EMBROIDERY_ALGORITHM_REFERENCE.md. Deliberately coarser than
    /// `satinDensityMM`: this is a lighter stabilizing base layer, not a
    /// second satin pass.
    public var zigzagUnderlaySpacingMM: Double = 1.2
    /// Satin columns averaging wider than this get zigzag underlay instead
    /// of plain center-run — a single centerline pass isn't enough to
    /// stabilize fabric across a wide zigzag, only a narrow one.
    public var zigzagUnderlayWidthThresholdMM: Double = 4.0

    // Phase 3 — pull compensation (spec §17)
    /// `nil` = automatic (see `PullCompensationCalculator`). Only applies
    /// to satin/fill; running stitch has no "width" to compensate.
    public var pullCompensationMM: Double? = nil

    /// Push compensation: fabric pushes apart *along* the stitching
    /// direction (as opposed to pull, which narrows a design perpendicular
    /// to it), so satin/fill sews slightly longer than digitized unless
    /// shortened first. `nil` = automatic (see
    /// `PullCompensationCalculator.estimatePush`). Only applies to
    /// satin/fill, same as pull.
    public var pushCompensationMM: Double? = nil

    // Phase 3 — reserved for object overlap / inset-outset (next).

    public init() {}
}

public enum UnderlayType: String, Codable, Sendable, CaseIterable {
    case none
    case centerRun
    case edgeRun
    /// A wider-spaced, inset zigzag beneath satin — see `zigzagUnderlaySpacingMM`.
    case zigzag
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
    /// True once the user has explicitly picked a stitch type for this
    /// object (e.g. in the Object Inspector) rather than it coming from
    /// auto-classification. Operations that re-derive `stitchType` from
    /// geometry (such as resizing the whole design) must leave this object
    /// alone once set, so a user's choice survives edits made afterward.
    public var stitchTypeIsManualOverride: Bool = false

    public init(id: UUID = UUID(), name: String, shape: VectorShape, stitchType: StitchType,
                threadColor: ThreadColor, parameters: StitchGenerationParameters = StitchGenerationParameters(),
                stitchTypeIsManualOverride: Bool = false) {
        self.id = id
        self.name = name
        self.shape = shape
        self.stitchType = stitchType
        self.threadColor = threadColor
        self.parameters = parameters
        self.stitchTypeIsManualOverride = stitchTypeIsManualOverride
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, shape, stitchType, threadColor, parameters, stitchTypeIsManualOverride
    }

    /// Custom decoding so older `.stitchpilot` documents saved before
    /// `stitchTypeIsManualOverride` existed keep loading (missing key
    /// defaults to `false`, matching pre-existing objects that were all
    /// auto-classified).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        shape = try container.decode(VectorShape.self, forKey: .shape)
        stitchType = try container.decode(StitchType.self, forKey: .stitchType)
        threadColor = try container.decode(ThreadColor.self, forKey: .threadColor)
        parameters = try container.decode(StitchGenerationParameters.self, forKey: .parameters)
        stitchTypeIsManualOverride = try container.decodeIfPresent(Bool.self, forKey: .stitchTypeIsManualOverride) ?? false
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
