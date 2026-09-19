// Mirrors of the Swift model types that cross the wire as plain JSON
// (StitchPilotCore's Codable types) and the server's own wire structs
// (server/Sources/StitchPilotServer/Wire.swift). Field names must match
// the Swift side exactly.

export interface Point2D { x: number; y: number }
export interface SubPath { points: Point2D[]; closed: boolean }
export interface VectorShape { subPaths: SubPath[] }
export interface BoundingBox { minX: number; minY: number; maxX: number; maxY: number }
export interface RGBColor { r: number; g: number; b: number }

export interface ThreadColor {
  id: string;
  name: string;
  brand?: string | null;
  catalogNumber?: string | null;
  rgb: RGBColor;
}

export type StitchType = "runningStitch" | "tripleRun" | "satin" | "tatamiFill";
export type FillPattern = "rows" | "crossHatch" | "basketWeave";
export type UnderlayType = "none" | "centerRun" | "edgeRun" | "zigzag" | "tatami" | "doubleTatami";
export type FabricType =
  | "standard" | "stableWoven" | "knit" | "stretchKnit" | "terry" | "leatherOrVinyl"
  | "structuredCap" | "unstructuredCap" | "beanie";
export type ColorPresetId = "preserveArtwork" | "normalEmbroidery" | "productionEfficient" | "minimalColors";

export interface StitchGenerationParameters {
  stitchLengthMM: number;
  minStitchLengthMM: number;
  maxStitchLengthMM: number;
  satinDensityMM: number;
  maxSatinWidthMM: number;
  minSatinWidthMM: number;
  fillSpacingMM: number;
  fillAngleDegrees?: number | null;
  fillRowStaggerMM: number;
  fillPattern: FillPattern;
  underlayType?: UnderlayType | null;
  underlayStitchLengthMM: number;
  underlayInsetMM: number;
  zigzagUnderlaySpacingMM: number;
  zigzagUnderlayWidthThresholdMM: number;
  pullCompensationMM?: number | null;
  pushCompensationMM?: number | null;
  fabricType: FabricType;
  /** Thread weight; the engine offsets satin density and fill spacing by it (40 wt is the reference). */
  threadWeight?: ThreadWeight;
  /** Random shift of tatami interior penetrations as a fraction of stitch length (0 = off). */
  fillJitterFraction?: number;
  [key: string]: unknown;
}

export type ThreadWeight = "wt30" | "wt40" | "wt60" | "wt80";
export const THREAD_WEIGHTS: { id: ThreadWeight; title: string; subtitle: string }[] = [
  { id: "wt40", title: "Standard (40 wt)", subtitle: "the usual weight — works for almost everything" },
  { id: "wt60", title: "Fine (60 wt)", subtitle: "thinner thread — small lettering, delicate detail" },
  { id: "wt30", title: "Heavy (30 wt)", subtitle: "thicker thread — bold, textured work" },
  { id: "wt80", title: "Very fine (80 wt)", subtitle: "micro lettering; spacing tightens most" },
];

export interface EmbroideryObject {
  id: string;
  name: string;
  shape: VectorShape;
  stitchType: StitchType;
  threadColor: ThreadColor;
  parameters: StitchGenerationParameters;
  stitchTypeIsManualOverride: boolean;
  isApplique: boolean;
  /** Pre-digitized satin columns (a library glyph), in mm. Move and scale them with the shape -- see `transformObject`. */
  satinColumns?: SatinColumn[] | null;
}

export interface SatinColumn { a: Point2D[]; b: Point2D[]; t?: boolean }

export interface StitchDocument {
  schemaVersion: number;
  name: string;
  physicalWidthMM: number;
  physicalHeightMM: number;
  objects: EmbroideryObject[];
  /** Begin and end the file at the design centre (hoop centre) -- on for caps. */
  startAndEndAtCenter?: boolean;
  /** A light open fill sewn first under the whole design to flatten a napped fabric's pile (towels, fleece). */
  laydown?: LaydownSettings | null;
}

export interface LaydownSettings {
  threadColor: ThreadColor;
  marginMM: number;
  spacingMM: number;
  stitchLengthMM: number;
  twoLayers: boolean;
  coverHoles: boolean;
}

export interface ImportedSource {
  shapes: VectorShape[];
  fillColors: (RGBColor | null)[];
  bounds: BoundingBox;
  pixelWidth: number;
  pixelHeight: number;
}

/** Whether an image is a reasonable candidate for digitizing at all (engine `CandidateAssessment`). */
export interface CandidateAssessment {
  verdict: "good" | "caution" | "poor";
  reasons: { code: string; message: string }[];
}

export interface ImportResponse {
  source: ImportedSource;
  recommendedWidthMM: number;
  recommendedHeightMM: number;
  aspectRatio: number;
  /** The artwork's page or card colour when it is a real colour (navy, grey, red): the fabric is drawn in it so white thread shows. */
  backgroundColor?: RGBColor | null;
  /** Lines of text found by their geometry, in artwork pixels; the Text step asks what they say. */
  textLines?: TextLine[];
  candidate?: CandidateAssessment | null;
}

/** A run of letter-sized shapes the importer found in a line (see TextLineFinder). Pixel space. */
export interface TextLine {
  shapeIndices: number[];
  boundingBoxPixels: BoundingBox;
  rotationDegrees: number;
  capHeightPixels: number;
  inkFraction: number;
  curved: boolean;
  arcRadiusPixels?: number | null;
  color?: RGBColor | null;
  /** Letters of two heights: mixed case rather than all capitals. */
  mixedCase?: boolean;
  /** Median letter width over cap height: ~0.5 condensed, ~0.75 normal, >0.9 wide. */
  letterAspect?: number;
}

export type TextAction = "retype" | "drop" | "keep";

/** What to do with one detected text line when the design is built. */
export interface TextDecision {
  action: TextAction;
  text: string;
  fontID: string;
}

/** [code, x, y] per command; codes 0 stitch, 1 jump, 2 color change, 3 trim, 4 stop, 5 end. */
export type WireCommand = [number, number, number];

export interface DigitizeResponse {
  plan: { commands: WireCommand[] };
  colors: ThreadColor[];
  report: { score: number; isReadyToSew: boolean; issues: { severity: string; message: string; scorePenalty: number }[] };
  candidate?: CandidateAssessment | null;
  stats: {
    stitchCount: number; colorChangeCount: number; trimCount: number;
    maxStitchLengthMM: number; totalThreadMM: number; bounds: BoundingBox;
    estimatedRunSeconds: number;
  };
  elapsedMS: number;
}

export interface CatalogSize { name: string; widthMM: number; heightMM: number }
export interface CatalogFabric { id: FabricType; displayName: string; shortName: string; isHeadwear: boolean; stabilizer: string }

export interface Catalog {
  hoops: CatalogSize[];
  garmentPresets: CatalogSize[];
  fabrics: CatalogFabric[];
  colorPresets: { id: ColorPresetId; maxColors: number }[];
  threadPalette: ThreadColor[];
  stitchTypes: StitchType[];
  fillPatterns: { id: FillPattern; displayName: string }[];
  underlayTypes: UnderlayType[];
  exportFormats: string[];
  defaultParameters: StitchGenerationParameters;
}

// --- accounts (server/Sources/StitchPilotServer/Auth.swift) ---

export interface AccountState {
  customer_id: number;
  email: string;
  name: string;
  /** 'active' | 'trialing' | 'past_due' | 'comp' | 'none' | 'ended' */
  status: string;
  entitled: boolean;
  valid_until: string | null;
  period_end: string | null;
  cancel_at_period_end: boolean;
  has_billing: boolean;
  price_cents: number;
  currency: string;
  proofs?: ProofsState | null;
  trial_days: number;
}

/** PiperStitch Proofs on the same account: subscribed, or the free trial
 *  (`free_used` of `free_granted` proofs sent). `url` is where it lives. */
export interface ProofsState {
  subscribed: boolean;
  status: string;
  free_granted: number;
  free_used: number;
  free_left: number;
  can_send: boolean;
  has_billing: boolean;
  price_cents: number;
  url: string;
}

export interface MeResponse {
  authEnabled: boolean;
  signedIn: boolean;
  account?: AccountState | null;
  proofsURL?: string;
}

export interface ProjectSummary {
  id: string;
  name: string;
  widthMM: number;
  heightMM: number;
  objectCount: number;
  createdAt: string;
  updatedAt: string;
}

export interface PromoValidation {
  valid: boolean;
  code?: string;
  percent_off?: number;
  duration_months?: number | null;
  description?: string;
  error?: string;
  message?: string;
}
