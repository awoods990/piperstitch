// Per-user preferences. Kept in the browser (localStorage) so they apply
// instantly and survive reloads; mirrored to the account on the server
// when signed in, so they follow the user between browsers.

import type { ColorPresetId, FabricType, RGBColor, ThreadColor } from "./types";

export interface Preferences {
  defaultHoopName: string | null;
  defaultFabric: FabricType;
  defaultColorPreset: ColorPresetId;
  matchToThreadLibrary: boolean;
  /** "Push past normal limits" for the density sliders. */
  allowExtendedDensity: boolean;
  paintBrushRadiusMM: number;
  paintColor: RGBColor;
  /** The user's own thread inventory; empty = the built-in palette. */
  threadLibrary: ThreadColor[];
  showJumps: boolean;
}

export const DEFAULT_PREFS: Preferences = {
  defaultHoopName: "6\" × 10\"",
  defaultFabric: "standard",
  defaultColorPreset: "normalEmbroidery",
  matchToThreadLibrary: true,
  allowExtendedDensity: false,
  paintBrushRadiusMM: 1.5,
  paintColor: { r: 0, g: 0, b: 0 },
  threadLibrary: [],
  showJumps: false,
};

const KEY = "piperstitch.preferences";

export function loadPrefs(): Preferences {
  try {
    const raw = localStorage.getItem(KEY);
    if (raw) return { ...DEFAULT_PREFS, ...JSON.parse(raw) };
  } catch { /* fall through */ }
  return { ...DEFAULT_PREFS };
}

export function savePrefs(p: Preferences) {
  try { localStorage.setItem(KEY, JSON.stringify(p)); } catch { /* private mode etc. */ }
}

export const rgbHex = (c: RGBColor) => "#" + [c.r, c.g, c.b].map((v) => v.toString(16).padStart(2, "0")).join("");
export const hexRGB = (hex: string): RGBColor => {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex.trim());
  if (!m) return { r: 0, g: 0, b: 0 };
  const n = parseInt(m[1], 16);
  return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 };
};
export const rgbCSS = (c: RGBColor) => `rgb(${c.r},${c.g},${c.b})`;
