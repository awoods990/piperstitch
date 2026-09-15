/** Millimeters as centimeters the way the Mac app shows them: "10" or "11.4". */
export function cm(mm: number): string {
  const v = mm / 10;
  return Number.isInteger(v) ? v.toFixed(0) : v.toFixed(1);
}

export function inches(mm: number): string {
  return (mm / 25.4).toFixed(2).replace(/\.?0+$/, "");
}

export const approx = (a: number, b: number) => Math.abs(a - b) < 0.5;

/** "4 min 20 s", "1 h 12 min", "45 s" -- mirrors RunTimeEstimator.format. */
export function formatRunTime(seconds: number): string {
  const total = Math.round(seconds);
  const h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60), s = total % 60;
  if (h > 0) return `${h} h ${m} min`;
  if (m > 0) return s > 0 ? `${m} min ${s} s` : `${m} min`;
  return `${s} s`;
}
