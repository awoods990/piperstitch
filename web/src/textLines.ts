// Shared arithmetic for detected text lines: the pixel-to-mm scale the
// server's `fitToPhysicalSize` uses, and the smallest capital that sews as
// lettering by thread weight (`TextLineFinder.minimumCapHeightMM`).

import type { BoundingBox, ThreadWeight } from "./types";

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
