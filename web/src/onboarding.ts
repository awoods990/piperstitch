// Guided setup: the reference data the steps draw on, and the mapping from
// what a business tells us to the settings both apps then use. The
// component itself is components/Onboarding.tsx.

import type { ExportFormat } from "./prefs";

export type Product = "core" | "proofs";

/** Machine brands, what file they read, and the hoops that come with them
 *  (catalog names -- see HoopProfile.commonHoops in the engine). A brand's
 *  suggested hoops are pre-ticked in the hoops step; the user corrects. */
export interface MachineBrand {
  id: string;
  name: string;
  format: ExportFormat;
  formatLabel: string;
  hoops: string[];
  commercial: boolean;
}

export const MACHINE_BRANDS: MachineBrand[] = [
  { id: "brother", name: "Brother", format: "pes", formatLabel: ".pes", hoops: ["4\" × 4\"", "5\" × 7\"", "6\" × 10\""], commercial: false },
  { id: "babylock", name: "Baby Lock", format: "pes", formatLabel: ".pes", hoops: ["4\" × 4\"", "5\" × 7\"", "6\" × 10\""], commercial: false },
  { id: "janome", name: "Janome", format: "jef", formatLabel: ".jef", hoops: ["4\" × 4\"", "5\" × 7\"", "8\" × 8\""], commercial: false },
  { id: "bernina", name: "Bernina", format: "exp", formatLabel: ".exp", hoops: ["4\" × 4\"", "5\" × 7\"", "6\" × 10\""], commercial: false },
  { id: "husqvarna", name: "Husqvarna Viking / Pfaff", format: "vp3", formatLabel: ".vp3", hoops: ["4\" × 4\"", "5\" × 7\"", "6\" × 10\""], commercial: false },
  { id: "singer", name: "Singer", format: "dst", formatLabel: ".dst", hoops: ["4\" × 4\"", "5\" × 7\""], commercial: false },
  { id: "melco", name: "Melco", format: "exp", formatLabel: ".exp", hoops: ["4\" × 4\"", "5\" × 7\"", "8\" × 8\"", "Cap/Hat Hoop"], commercial: true },
  { id: "tajima", name: "Tajima", format: "dst", formatLabel: ".dst", hoops: ["4\" × 4\"", "5\" × 7\"", "8\" × 8\"", "9\" × 9\"", "Cap/Hat Hoop"], commercial: true },
  { id: "barudan", name: "Barudan", format: "dst", formatLabel: ".dst", hoops: ["4\" × 4\"", "5\" × 7\"", "8\" × 8\"", "9\" × 9\"", "Cap/Hat Hoop"], commercial: true },
  { id: "ricoma", name: "Ricoma", format: "dst", formatLabel: ".dst", hoops: ["4\" × 4\"", "5\" × 7\"", "8\" × 8\"", "Cap/Hat Hoop"], commercial: true },
  { id: "swf", name: "SWF / Happy / ZSK", format: "dst", formatLabel: ".dst", hoops: ["4\" × 4\"", "5\" × 7\"", "8\" × 8\"", "9\" × 9\"", "Cap/Hat Hoop"], commercial: true },
  { id: "other", name: "Other / not sure", format: "dst", formatLabel: ".dst (read by most machines)", hoops: ["4\" × 4\"", "5\" × 7\""], commercial: false },
];

export const EXPORT_FORMAT_LABELS: Record<ExportFormat, string> = {
  dst: "Tajima .dst", pes: "Brother / Baby Lock .pes", jef: "Janome .jef", exp: "Melco / Bernina .exp", vp3: "Husqvarna Viking / Pfaff .vp3",
};

/** The file format for the first brand chosen; a shop with a Brother and a
 *  Tajima gets whichever they listed first and can change it in Settings. */
export function defaultFormat(brandIds: string[]): ExportFormat {
  for (const id of brandIds) { const b = MACHINE_BRANDS.find((m) => m.id === id); if (b) return b.format; }
  return "dst";
}

/** Union of the chosen brands' hoops, in catalog order. */
export function suggestedHoops(brandIds: string[], catalogNames: string[]): string[] {
  const wanted = new Set<string>();
  for (const id of brandIds) MACHINE_BRANDS.find((m) => m.id === id)?.hoops.forEach((h) => wanted.add(h));
  return catalogNames.filter((n) => wanted.has(n));
}

export const anyCommercial = (brandIds: string[]) => brandIds.some((id) => MACHINE_BRANDS.find((m) => m.id === id)?.commercial);

export const BUSINESS_TYPES: { id: string; name: string; hint: string }[] = [
  { id: "hobby", name: "Home embroidery", hint: "gifts, family, my own projects" },
  { id: "home-business", name: "Home-based business", hint: "orders from customers, one or two machines" },
  { id: "shop", name: "Retail embroidery shop", hint: "walk-in and online customers" },
  { id: "production", name: "Production / contract", hint: "multi-head machines, volume runs" },
  { id: "promo", name: "Promotional products / apparel decorator", hint: "embroidery is one of several services" },
  { id: "team", name: "Uniforms & team wear", hint: "schools, clubs, corporate" },
];

export type StepId = "account" | "products" | "business" | "machine" | "hoops" | "threads" | "defaults" | "proofs" | "tips" | "done";

/** Rough reading-and-clicking time per step, in minutes, for the estimate. */
const STEP_MINUTES: Record<StepId, number> = { account: 1, products: 0.5, business: 1, machine: 0.5, hoops: 1, threads: 1.5, defaults: 0.5, proofs: 1, tips: 0.5, done: 0 };

export function stepsFor(products: Product[], needsAccount = false): StepId[] {
  const steps: StepId[] = needsAccount ? ["account", "products", "business", "machine"] : ["products", "business", "machine"];
  if (products.includes("core")) steps.push("hoops", "threads", "defaults");
  if (products.includes("proofs")) steps.push("proofs");
  steps.push("tips", "done");
  return steps;
}

export function estimateMinutes(products: Product[], needsAccount = false): number {
  return Math.round(stepsFor(products, needsAccount).reduce((sum, s) => sum + STEP_MINUTES[s], 0));
}

export const ONBOARDING_VERSION = 1;
