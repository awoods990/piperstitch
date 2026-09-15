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

/// A tatami fill's stitch texture -- `TatamiFillGenerator` picks the
/// generation strategy from this, not a separate `StitchType` case, since
/// both patterns fill the exact same kind of region (even-odd across every
/// sub-path, same hole handling) and only differ in HOW the rows
/// themselves are laid out; keeping them under one `StitchType` avoids
/// touching every `switch` over `StitchType` elsewhere in the engine just
/// to add a texture variant.
public enum FillPattern: String, Codable, Sendable, CaseIterable {
    /// Parallel rows at one angle -- this engine's original, only fill
    /// texture until this case was added.
    case rows
    /// Two overlapping row passes at right angles to each other, each at
    /// half the requested density (so the combined coverage is
    /// comparable in weight to a single `.rows` pass, not roughly double
    /// it) -- a lattice/cross-hatch texture rather than parallel rows,
    /// useful for a large flat area where plain rows can show a faint
    /// directional "grain" or sheen. What commercial digitizing software
    /// usually calls an E-stitch/lattice fill.
    case crossHatch
    /// A checkerboard of cells, each filled at one of two alternating
    /// angles 90° apart -- the basket-weave technique real digitizing
    /// software uses on a large flat area to break up the faint
    /// directional "grain"/sheen plain rows (or even cross-hatch, whose
    /// own two angles are still uniform across the whole shape) can show.
    /// Most useful on a genuinely large region (a background fill, a
    /// bold block letter) -- on a small or narrow shape, the cell grid
    /// itself becomes the more visible artifact instead.
    case basketWeave

    public var displayName: String {
        switch self {
        case .rows: return "Rows"
        case .crossHatch: return "Cross-Hatch"
        case .basketWeave: return "Basket Weave"
        }
    }
}

/// The fabric a design is meant to be sewn on -- affects how much
/// `PullCompensationCalculator`'s automatic pull/push estimate should
/// apply, since a stretchier material distorts more during stitching and
/// needs more compensation to end up the intended size; a stable, rigid
/// material needs less than the engine's baseline (tuned for a typical
/// cotton twill). `.standard` makes no adjustment at all -- today's
/// existing behavior, unchanged.
///
/// Only ever affects the AUTOMATIC estimate: an object's own explicit
/// `pullCompensationMM`/`pushCompensationMM`, when set, always wins
/// regardless of fabric type, the same as any other manual override this
/// engine already respects (spec's general "auto by default, explicit
/// wins" pattern).
public enum FabricType: String, Codable, Sendable, CaseIterable {
    case standard
    case stableWoven
    case knit
    case stretchKnit
    case terry
    case leatherOrVinyl
    // Headwear. Caps are their own world in embroidery: a structured cap's
    // buckram-backed front panel is one of the most stable surfaces there
    // is (little pull, but the curved panel and the seam make registration
    // the real risk), an unstructured/dad cap is a soft, lightly-stretching
    // cotton that behaves like a loose woven, and a knit beanie stretches
    // like an athletic knit and needs the most compensation of anything.
    case structuredCap
    case unstructuredCap
    case beanie

    public var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .stableWoven: return "Stable Woven (twill, canvas, denim)"
        case .knit: return "Knit (t-shirt, polo)"
        case .stretchKnit: return "Stretch Knit (athletic, spandex blend)"
        case .terry: return "Terry / Plush (towel, fleece)"
        case .leatherOrVinyl: return "Leather / Vinyl"
        case .structuredCap: return "Structured Cap (buckram front)"
        case .unstructuredCap: return "Unstructured Cap / Dad Hat"
        case .beanie: return "Knit Beanie / Winter Hat"
        }
    }

    /// True for the cap/hat fabrics -- the setup flow groups these
    /// together and leads with them when the design is a cap front.
    public var isHeadwear: Bool {
        switch self {
        case .structuredCap, .unstructuredCap, .beanie: return true
        default: return false
        }
    }

    /// A short label for a space-constrained toolbar button -- `displayName`
    /// is the fuller, self-explanatory version used in the picker's own menu.
    public var shortName: String {
        switch self {
        case .standard: return "Standard"
        case .stableWoven: return "Stable Woven"
        case .knit: return "Knit"
        case .stretchKnit: return "Stretch Knit"
        case .terry: return "Terry/Plush"
        case .leatherOrVinyl: return "Leather/Vinyl"
        case .structuredCap: return "Structured Cap"
        case .unstructuredCap: return "Soft Cap"
        case .beanie: return "Beanie"
        }
    }

    /// Multiplies `PullCompensationCalculator`'s base pull/push estimate.
    /// Directional guidance only (this engine has no calibrated per-
    /// fabric sew-out data yet -- see that type's own doc comment on why
    /// its whole estimate is a heuristic, not a physical model): a low-
    /// stretch, dimensionally stable material needs less correction than
    /// the baseline, a stretchy knit needs meaningfully more, and terry/
    /// plush needs a moderate bump for its own pile-related distortion.
    public var compensationMultiplier: Double {
        switch self {
        case .standard: return 1.0
        case .stableWoven: return 0.7
        case .knit: return 1.3
        case .stretchKnit: return 1.8
        case .terry: return 1.4
        case .leatherOrVinyl: return 0.6
        case .structuredCap: return 0.8
        case .unstructuredCap: return 1.1
        case .beanie: return 1.7
        }
    }
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
    // Tightened from an original 0.4mm default: a real Brother-machine
    // sew-out of this exact default showed visibly under-filled block
    // letters -- individual crossings distinguishable as separate ridges
    // rather than reading as one solid fill, on a design with no other
    // red flag (standard fabric, no tiny/challenging detail). Real-world
    // thread lay, machine tension, and registration drift all eat into
    // the same nominal spacing a flat on-screen render represents
    // perfectly; a denser default has more margin against that gap
    // between digitized geometry and actual sewn coverage. See
    // CHANGELOG.md.
    public var satinDensityMM: Double = 0.32     // spacing between satin crossings
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
    // Same tightening, and for the same reason, as `satinDensityMM` above.
    public var fillSpacingMM: Double = 0.32
    /// `nil` = automatic (see `FillAngleSelector`) — do not always fall
    /// back to a single fixed angle. Set explicitly to override.
    public var fillAngleDegrees: Double? = nil
    public var fillRowStaggerMM: Double = 1.2
    /// The fill texture -- see `FillPattern`'s own doc comment. `.rows`
    /// (the default) is this engine's original, only fill texture;
    /// unchanged unless set explicitly.
    public var fillPattern: FillPattern = .rows

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

    /// Adjusts the automatic pull/push compensation estimate for the
    /// fabric this design is meant to be sewn on -- see `FabricType`'s own
    /// doc comment. `.standard` (the default) makes no adjustment at all,
    /// so existing designs/documents are unaffected unless this is set
    /// explicitly.
    public var fabricType: FabricType = .standard

    /// Opts a shape into `SatinColumnGenerator.canRepresentAsBranchingSatinColumn`/
    /// `generateBranching` — decomposing a genuinely branching outline (a
    /// letter like "A," "B," "R," "H") into stroke segments and rail-
    /// fitting each independently, rather than falling back to tatami
    /// fill the moment `canRepresentAsSingleSatinColumn` rejects the whole
    /// shape as one column. Defaults to `true`: real-file verification
    /// (Amerus, LIBBi, the Boston Red Sox "B") and a visual review of the
    /// rendered output were the gate for this, not a code change alone —
    /// see DIGITIZING_ENGINE.md's branching-letter satin entries. Purely
    /// additive regardless: a shape that can't be rail-fit as branching
    /// satin (`SatinColumnGenerator.canRepresentAsBranchingSatinColumn`
    /// returning `false`) falls straight through to the exact same
    /// tatami-fill behavior this engine always had, so turning this on
    /// can only add real satin coverage somewhere it wasn't possible
    /// before, never take away working output. See
    /// `StitchTypeClassifier.classify` and `DigitizePipeline`'s `.satin`
    /// case for where this is actually consulted.
    public var allowBranchingSatin: Bool = true

    // Phase 3 — reserved for object overlap / inset-outset (next).

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case stitchLengthMM, minStitchLengthMM, maxStitchLengthMM
        case satinDensityMM, maxSatinWidthMM, minSatinWidthMM
        case fillSpacingMM, fillAngleDegrees, fillRowStaggerMM, fillPattern
        case underlayType, underlayStitchLengthMM, underlayInsetMM, zigzagUnderlaySpacingMM, zigzagUnderlayWidthThresholdMM
        case pullCompensationMM, pushCompensationMM, fabricType, allowBranchingSatin
    }

    /// A field added here with a non-`Optional` type and a default value
    /// (most of this struct's fields, including every one added before
    /// this initializer existed) is NOT actually given that default by
    /// Swift's synthesized `Decodable` when its key is missing --
    /// synthesis only special-cases `Optional` properties that way. Every
    /// non-optional field here was, until this initializer, silently
    /// relying on `decodeIfPresent`-like behavior this engine's own
    /// comments claimed but Swift doesn't actually provide -- a
    /// `.stitchpilot` file saved before a given phase's fields existed
    /// would throw `keyNotFound` decoding it today. This explicit
    /// decoder actually delivers what those comments always described:
    /// every field defaults when its key is missing, keeping old project
    /// files loading regardless of which phase they were saved under.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = StitchGenerationParameters()
        stitchLengthMM = try c.decodeIfPresent(Double.self, forKey: .stitchLengthMM) ?? defaults.stitchLengthMM
        minStitchLengthMM = try c.decodeIfPresent(Double.self, forKey: .minStitchLengthMM) ?? defaults.minStitchLengthMM
        maxStitchLengthMM = try c.decodeIfPresent(Double.self, forKey: .maxStitchLengthMM) ?? defaults.maxStitchLengthMM
        satinDensityMM = try c.decodeIfPresent(Double.self, forKey: .satinDensityMM) ?? defaults.satinDensityMM
        maxSatinWidthMM = try c.decodeIfPresent(Double.self, forKey: .maxSatinWidthMM) ?? defaults.maxSatinWidthMM
        minSatinWidthMM = try c.decodeIfPresent(Double.self, forKey: .minSatinWidthMM) ?? defaults.minSatinWidthMM
        fillSpacingMM = try c.decodeIfPresent(Double.self, forKey: .fillSpacingMM) ?? defaults.fillSpacingMM
        fillAngleDegrees = try c.decodeIfPresent(Double.self, forKey: .fillAngleDegrees)
        fillRowStaggerMM = try c.decodeIfPresent(Double.self, forKey: .fillRowStaggerMM) ?? defaults.fillRowStaggerMM
        fillPattern = try c.decodeIfPresent(FillPattern.self, forKey: .fillPattern) ?? defaults.fillPattern
        underlayType = try c.decodeIfPresent(UnderlayType.self, forKey: .underlayType)
        underlayStitchLengthMM = try c.decodeIfPresent(Double.self, forKey: .underlayStitchLengthMM) ?? defaults.underlayStitchLengthMM
        underlayInsetMM = try c.decodeIfPresent(Double.self, forKey: .underlayInsetMM) ?? defaults.underlayInsetMM
        zigzagUnderlaySpacingMM = try c.decodeIfPresent(Double.self, forKey: .zigzagUnderlaySpacingMM) ?? defaults.zigzagUnderlaySpacingMM
        zigzagUnderlayWidthThresholdMM = try c.decodeIfPresent(Double.self, forKey: .zigzagUnderlayWidthThresholdMM) ?? defaults.zigzagUnderlayWidthThresholdMM
        pullCompensationMM = try c.decodeIfPresent(Double.self, forKey: .pullCompensationMM)
        pushCompensationMM = try c.decodeIfPresent(Double.self, forKey: .pushCompensationMM)
        fabricType = try c.decodeIfPresent(FabricType.self, forKey: .fabricType) ?? defaults.fabricType
        allowBranchingSatin = try c.decodeIfPresent(Bool.self, forKey: .allowBranchingSatin) ?? defaults.allowBranchingSatin
    }
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
    /// True for an applique piece: `DigitizePipeline` sews a placement
    /// outline (trace the shape once, guiding where to lay the fabric)
    /// and a tack-down outline (trace it again, slightly inset, securing
    /// the fabric's raw edge) before this object's own normal
    /// `stitchType` stitching, which then covers both the tack-down line
    /// and the fabric edge as the finished decorative border/fill. Does
    /// NOT change `stitchType` itself -- an applique piece still gets
    /// classified/generated as satin, fill, or a running outline exactly
    /// like any other object; this only adds the two outline passes
    /// before it.
    public var isApplique: Bool = false

    public init(id: UUID = UUID(), name: String, shape: VectorShape, stitchType: StitchType,
                threadColor: ThreadColor, parameters: StitchGenerationParameters = StitchGenerationParameters(),
                stitchTypeIsManualOverride: Bool = false, isApplique: Bool = false) {
        self.id = id
        self.name = name
        self.shape = shape
        self.stitchType = stitchType
        self.threadColor = threadColor
        self.parameters = parameters
        self.stitchTypeIsManualOverride = stitchTypeIsManualOverride
        self.isApplique = isApplique
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, shape, stitchType, threadColor, parameters, stitchTypeIsManualOverride, isApplique
    }

    /// Custom decoding so older `.stitchpilot` documents saved before
    /// `stitchTypeIsManualOverride`/`isApplique` existed keep loading
    /// (missing key defaults to `false` for both, matching pre-existing
    /// objects, which were all auto-classified, non-applique).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        shape = try container.decode(VectorShape.self, forKey: .shape)
        stitchType = try container.decode(StitchType.self, forKey: .stitchType)
        threadColor = try container.decode(ThreadColor.self, forKey: .threadColor)
        parameters = try container.decode(StitchGenerationParameters.self, forKey: .parameters)
        stitchTypeIsManualOverride = try container.decodeIfPresent(Bool.self, forKey: .stitchTypeIsManualOverride) ?? false
        isApplique = try container.decodeIfPresent(Bool.self, forKey: .isApplique) ?? false
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
