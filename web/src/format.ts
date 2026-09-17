/** Millimeters as centimeters the way the Mac app shows them: "10" or "11.4". */
export function cm(mm: number): string {
  const v = mm / 10;
  return Number.isInteger(v) ? v.toFixed(0) : v.toFixed(1);
}

export function inches(mm: number): string {
  return (mm / 25.4).toFixed(2).replace(/\.?0+$/, "");
}

// The display unit, set from preferences (guided setup asks). A module-level
// setting rather than a prop threaded through every size label.
let displayUnits: "cm" | "in" = "cm";
export function setDisplayUnits(units: "cm" | "in") { displayUnits = units; }
export function displayUnitLabel(): "cm" | "in" { return displayUnits; }
/** A length in the display unit, without the unit: "10.2" or "4". */
export function len(mm: number): string { return displayUnits === "in" ? inches(mm) : cm(mm); }
/** "10.2 × 10.2 cm" / "4 × 4 in". */
export function size(widthMM: number, heightMM: number): string { return `${len(widthMM)} × ${len(heightMM)} ${displayUnits}`; }
/** Value shown in a size input, and its parse back to mm. */
export function toDisplay(mm: number): number { return displayUnits === "in" ? Math.round(mm / 25.4 * 100) / 100 : Math.round(mm) / 10; }
export function fromDisplay(value: number): number { return displayUnits === "in" ? value * 25.4 : value * 10; }

export const approx = (a: number, b: number) => Math.abs(a - b) < 0.5;

/** "4 min 20 s", "1 h 12 min", "45 s" -- mirrors RunTimeEstimator.format. */
export function formatRunTime(seconds: number): string {
  const total = Math.round(seconds);
  const h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60), s = total % 60;
  if (h > 0) return `${h} h ${m} min`;
  if (m > 0) return s > 0 ? `${m} min ${s} s` : `${m} min`;
  return `${s} s`;
}
