// Per-user preferences. Kept in the browser (localStorage) so they apply
// instantly and survive reloads; mirrored to the account on the server
// when signed in, so they follow the user between browsers.

import type { ColorPresetId, FabricType, RGBColor, ThreadColor } from "./types";

/** What guided setup collected about the business. Shared with PiperStitch
 *  Proofs through the account's mirrored preferences (`business.*`). */
export interface BusinessProfile {
  name: string;
  contactName: string;
  phone: string;
  website: string;
  city: string;
  /** One of `BUSINESS_TYPES` in onboarding.ts. */
  type: string;
  /** Machine brand ids from `MACHINE_BRANDS` in onboarding.ts. */
  machineBrands: string[];
  machineNotes: string;
}

/** PiperStitch Proofs' own account settings, as guided setup collects them
 *  (`proofsDefaults.*`). Proofs applies these to its Account on the next
 *  sign-in from here, once per completed setup -- see proofs/app/auth.py
 *  `apply_core_setup` in the Proofs repository. Field names mirror that
 *  Account: shop_name, reply_to_email, default_response_window_days,
 *  reminders_enabled, release_gate_policy. */
export interface ProofsDefaults {
  shopName: string;
  replyTo: string;
  /** Days a customer has to respond before the proof is overdue (1-60). */
  responseWindowDays: number;
  /** Chase the customer automatically (email/SMS cadence lives in Proofs). */
  remindersEnabled: boolean;
  /** "soft" (downloadable, stamped unapproved) | "hard" (withheld until approved) | "off". */
  releaseGate: "soft" | "hard" | "off";
}

export interface OnboardingRecord {
  version: number;
  completedAt: string | null;
  skippedAt: string | null;
  products: ("core" | "proofs")[];
}

export type ExportFormat = "dst" | "pes" | "jef" | "exp" | "vp3";
export type Units = "cm" | "in";

export interface Preferences {
  defaultHoopName: string | null;
  /** Hoops the business actually owns (catalog names); shown first everywhere. */
  ownedHoopNames: string[];
  /** The Download menu's first choice -- what their machine reads. */
  defaultExportFormat: ExportFormat;
  units: Units;
  business: BusinessProfile;
  proofsDefaults: ProofsDefaults;
  onboarding: OnboardingRecord | null;
  /** The start screen's "before your first design" tips were dismissed. */
  startTipsDismissed: boolean;
  defaultFabric: FabricType;
  defaultColorPreset: ColorPresetId;
  matchToThreadLibrary: boolean;
  /** "Push past normal limits" for the density sliders. */
  allowExtendedDensity: boolean;
  paintBrushRadiusMM: number;
  paintColor: RGBColor;
  /** The user's own thread inventory; empty = the built-in palette. */
  threadLibrary: ThreadColor[];
  /** Which manufacturer(s) the user actually sews with -- reference only
   *  (see threadSuppliers.ts), shown alongside threadLibrary above. Ids
   *  from THREAD_SUPPLIERS, not a color source. */
  threadSuppliers: string[];
  showJumps: boolean;
}

export const EMPTY_BUSINESS: BusinessProfile = { name: "", contactName: "", phone: "", website: "", city: "", type: "", machineBrands: [], machineNotes: "" };
export const EMPTY_PROOFS_DEFAULTS: ProofsDefaults = { shopName: "", replyTo: "", responseWindowDays: 7, remindersEnabled: true, releaseGate: "soft" };

export const DEFAULT_PREFS: Preferences = {
  defaultHoopName: "6\" × 10\"",
  ownedHoopNames: [],
  defaultExportFormat: "dst",
  units: "cm",
  business: EMPTY_BUSINESS,
  proofsDefaults: EMPTY_PROOFS_DEFAULTS,
  onboarding: null,
  startTipsDismissed: false,
  defaultFabric: "standard",
  defaultColorPreset: "normalEmbroidery",
  matchToThreadLibrary: true,
  allowExtendedDensity: false,
  paintBrushRadiusMM: 1.5,
  paintColor: { r: 0, g: 0, b: 0 },
  threadLibrary: [],
  threadSuppliers: [],
  showJumps: false,
};

const KEY = "piperstitch.preferences";

export function loadPrefs(): Preferences {
  try {
    const raw = localStorage.getItem(KEY);
    if (raw) return withDefaults(JSON.parse(raw));
  } catch { /* fall through */ }
  return { ...DEFAULT_PREFS };
}

/** Fills in any field a stored copy predates (nested objects too). */
export function withDefaults(stored: Partial<Preferences>): Preferences {
  return {
    ...DEFAULT_PREFS, ...stored,
    business: { ...EMPTY_BUSINESS, ...(stored.business ?? {}) },
    proofsDefaults: { ...EMPTY_PROOFS_DEFAULTS, ...(stored.proofsDefaults ?? {}) },
  };
}

export function savePrefs(p: Preferences) {
  try { localStorage.setItem(KEY, JSON.stringify(p)); localStorage.setItem(KEY + ".savedAt", String(Date.now())); } catch { /* private mode etc. */ }
}

export const rgbHex = (c: RGBColor) => "#" + [c.r, c.g, c.b].map((v) => v.toString(16).padStart(2, "0")).join("");
export const hexRGB = (hex: string): RGBColor => {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex.trim());
  if (!m) return { r: 0, g: 0, b: 0 };
  const n = parseInt(m[1], 16);
  return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 };
};
export const rgbCSS = (c: RGBColor) => `rgb(${c.r},${c.g},${c.b})`;
