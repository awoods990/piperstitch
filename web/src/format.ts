/** Millimeters as centimeters the way the Mac app shows them: "10" or "11.4". */
export function cm(mm: number): string {
  const v = mm / 10;
  return Number.isInteger(v) ? v.toFixed(0) : v.toFixed(1);
}

export function inches(mm: number): string {
  return (mm / 25.4).toFixed(2).replace(/\.?0+$/, "");
}

export const approx = (a: number, b: number) => Math.abs(a - b) < 0.5;
