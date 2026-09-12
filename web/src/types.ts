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
export type UnderlayType = "none" | "centerRun" | "edgeRun" | "zigzag";
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
  [key: string]: unknown;
}

export interface EmbroideryObject {
  id: string;
  name: string;
  shape: VectorShape;
  stitchType: StitchType;
  threadColor: ThreadColor;
  parameters: StitchGenerationParameters;
  stitchTypeIsManualOverride: boolean;
  isApplique: boolean;
}

export interface StitchDocument {
  schemaVersion: number;
  name: string;
  physicalWidthMM: number;
  physicalHeightMM: number;
  objects: EmbroideryObject[];
}

export interface ImportedSource {
  shapes: VectorShape[];
  fillColors: (RGBColor | null)[];
  bounds: BoundingBox;
  pixelWidth: number;
  pixelHeight: number;
}

export interface ImportResponse {
  source: ImportedSource;
  recommendedWidthMM: number;
  recommendedHeightMM: number;
  aspectRatio: number;
}

/** [code, x, y] per command; codes 0 stitch, 1 jump, 2 color change, 3 trim, 4 stop, 5 end. */
export type WireCommand = [number, number, number];

export interface DigitizeResponse {
  plan: { commands: WireCommand[] };
  colors: ThreadColor[];
  report: { score: number; isReadyToSew: boolean; issues: { severity: string; message: string; scorePenalty: number }[] };
  stats: {
    stitchCount: number; colorChangeCount: number; trimCount: number;
    maxStitchLengthMM: number; totalThreadMM: number; bounds: BoundingBox;
  };
  elapsedMS: number;
}

export interface CatalogSize { name: string; widthMM: number; heightMM: number }
export interface CatalogFabric { id: FabricType; displayName: string; shortName: string; isHeadwear: boolean }

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
