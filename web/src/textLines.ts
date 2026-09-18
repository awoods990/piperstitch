// Shared arithmetic for detected text lines: the pixel-to-mm scale the
// server's `fitToPhysicalSize` uses, and the smallest capital that sews as
// lettering by thread weight (`TextLineFinder.minimumCapHeightMM`).

import type { BoundingBox, ThreadWeight } from "./types";

export function minimumCapHeightMM(weight: ThreadWeight): number {
  switch (weight) {
    case "wt30": return 5;
    case "wt60": case "wt80": return 3;
    default: return 4;
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
