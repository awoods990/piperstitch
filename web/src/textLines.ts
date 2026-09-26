// Shared arithmetic for detected text lines: the pixel-to-mm scale the
// server's `fitToPhysicalSize` uses, and the smallest capital that sews as
// lettering by thread weight (`TextLineFinder.minimumCapHeightMM`).

import type { BoundingBox, TextLine, ThreadWeight } from "./types";

/**
 * The engine serves these on the catalog; pass them in. The fallback is
 * only for the moment before the catalog has loaded -- this file used to
 * hold the numbers itself, the engine's floor was raised, and for a week
 * the setup promised customers that a 4.5 mm line would sew as traced
 * while the engine had already decided it would not.
 */
export function minimumCapHeightMM(weight: ThreadWeight, fromEngine?: Record<string, number>): number {
  const served = fromEngine?.[weight];
  if (typeof served === "number" && served > 0) return served;
  switch (weight) {
    case "wt30": return 6;
    case "wt60": case "wt80": return 4;
    default: return 5;
  }
}

/** mm per artwork pixel when the shapes' bounds are fitted into widthMM x heightMM. */
export function textLineScale(bounds: BoundingBox, widthMM: number, heightMM: number): number {
  const w = bounds.maxX - bounds.minX, h = bounds.maxY - bounds.minY;
  if (w <= 0 || h <= 0) return 0;
  return Math.min(widthMM / w, heightMM / h);
}

/** The design-space position of an artwork pixel under the same fit. */
export function textLinePoint(bounds: BoundingBox, widthMM: number, heightMM: number, x: number, y: number) {
  const s = textLineScale(bounds, widthMM, heightMM);
  const w = bounds.maxX - bounds.minX, h = bounds.maxY - bounds.minY;
  const offsetX = -bounds.minX * s + (widthMM - w * s) / 2, offsetY = -bounds.minY * s + (heightMM - h * s) / 2;
  return { x: x * s + offsetX, y: y * s + offsetY };
}

/**
 * Which detected text line, if any, a selection on the canvas corresponds
 * to — matched by where it sits, because an object carries no record of
 * the shape it was traced from.
 *
 * Only available while the import is still in memory. Once a saved project
 * is reopened the lines are gone, and the caller falls back to what the
 * selection itself can tell it: where it is, how tall, and what colour.
 */
export function lineUnderSelection(
  lines: TextLine[],
  selection: BoundingBox,
  bounds: BoundingBox,
  widthMM: number,
  heightMM: number,
): TextLine | null {
  let best: { line: TextLine; overlap: number } | null = null;
  for (const line of lines) {
    const box = line.boundingBoxPixels;
    const a = textLinePoint(bounds, widthMM, heightMM, box.minX, box.minY);
    const b = textLinePoint(bounds, widthMM, heightMM, box.maxX, box.maxY);
    const wide = Math.min(b.x, selection.maxX) - Math.max(a.x, selection.minX);
    const tall = Math.min(b.y, selection.maxY) - Math.max(a.y, selection.minY);
    if (wide <= 0 || tall <= 0) continue;
    const overlap = wide * tall;
    // Measured against what was SELECTED, not against the line: one
    // letter covers a ninth of the word it belongs to, and clicking one
    // letter is the whole point.
    const selected = Math.max(1e-6, (selection.maxX - selection.minX) * (selection.maxY - selection.minY));
    if (overlap / selected < 0.6) continue;     // a passing brush, not this line
    if (!best || overlap > best.overlap) best = { line, overlap };
  }
  return best?.line ?? null;
}

/**
 * Whether a set of shapes reads as a row of letters: several of them, of
 * much the same height, sitting on the same baseline. Deliberately plain —
 * it decides whether to *offer* re-typing, and offering it over a row of
 * fence posts costs nothing but a glance.
 */
export function looksLikeALineOfText(boxes: BoundingBox[]): boolean {
  if (boxes.length < 3) return false;
  const heights = boxes.map((b) => b.maxY - b.minY).filter((h) => h > 0);
  if (heights.length !== boxes.length) return false;
  const mean = heights.reduce((a, b) => a + b, 0) / heights.length;
  if (mean <= 0) return false;
  const spread = Math.sqrt(heights.reduce((a, h) => a + (h - mean) ** 2, 0) / heights.length) / mean;
  if (spread > 0.45) return false;
  const baselines = boxes.map((b) => b.maxY);
  const baseMean = baselines.reduce((a, b) => a + b, 0) / baselines.length;
  const onBaseline = baselines.filter((y) => Math.abs(y - baseMean) <= mean * 0.3).length;
  if (onBaseline < boxes.length * 0.7) return false;
  const left = Math.min(...boxes.map((b) => b.minX)), right = Math.max(...boxes.map((b) => b.maxX));
  return right - left > mean;                    // a row, not a stack
}
