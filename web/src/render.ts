// Draws a stitch plan on a <canvas> the way StitchRenderer does on the
// Mac: every stitch stroked at real thread width with round caps,
// alternating a darker/lighter shade so stitches read as separate
// threads, then a thin highlight offset perpendicular to each stitch so
// the thread reads as round. Jumps are hidden (trimmed jumps leave no
// thread; see HiddenTravelRouter). The plan is in design millimeters;
// `view` maps mm to canvas pixels.

import type { RGBColor, ThreadColor, WireCommand } from "./types";

export const THREAD_WIDTH_MM = 0.35;
export const PAPER = "#f7f3ec";

export interface View {
  /** Canvas pixels per design mm. */
  scale: number;
  /** Canvas pixel position of design (0,0). */
  offsetX: number;
  offsetY: number;
}

const rgb = (c: RGBColor, k = 1, add = 0) =>
  `rgb(${clamp(c.r * k + add)},${clamp(c.g * k + add)},${clamp(c.b * k + add)})`;
const clamp = (v: number) => Math.max(0, Math.min(255, Math.round(v)));

export function drawPlan(
  ctx: CanvasRenderingContext2D,
  commands: WireCommand[],
  colors: ThreadColor[],
  view: View,
  options: { showJumps?: boolean } = {},
) {
  const { scale, offsetX, offsetY } = view;
  const threadPx = Math.max(0.75, THREAD_WIDTH_MM * scale);
  const hlOffset = THREAD_WIDTH_MM * 0.2 * scale;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";

  let colorIndex = 0;
  let dark = new Path2D(), light = new Path2D(), highlight = new Path2D(), jumps = new Path2D();
  let parity = false;
  let hasSegment = false;
  let last: [number, number] | null = null;

  const flush = () => {
    if (hasSegment) {
      const c = (colors[Math.min(colorIndex, colors.length - 1)] ?? colors[0])?.rgb ?? { r: 40, g: 40, b: 40 };
      ctx.lineWidth = threadPx;
      ctx.strokeStyle = rgb(c, 0.88);
      ctx.stroke(dark);
      ctx.strokeStyle = rgb(c, 1.08, 5);
      ctx.stroke(light);
      ctx.lineWidth = threadPx * 0.35;
      ctx.strokeStyle = "rgba(255,255,255,0.4)";
      ctx.stroke(highlight);
    }
    dark = new Path2D(); light = new Path2D(); highlight = new Path2D();
    hasSegment = false;
  };

  for (const [code, mx, my] of commands) {
    const x = offsetX + mx * scale, y = offsetY + my * scale;
    if (code === 0) {
      if (last) {
        const p = parity ? light : dark;
        p.moveTo(last[0], last[1]); p.lineTo(x, y);
        parity = !parity;
        const dx = x - last[0], dy = y - last[1];
        const len = Math.hypot(dx, dy);
        if (len > 0.01) {
          const nx = -dy / len, ny = dx / len;
          highlight.moveTo(last[0] + nx * hlOffset, last[1] + ny * hlOffset);
          highlight.lineTo(x + nx * hlOffset, y + ny * hlOffset);
        }
        hasSegment = true;
      }
      last = [x, y];
    } else if (code === 1) {
      if (last && options.showJumps) { jumps.moveTo(last[0], last[1]); jumps.lineTo(x, y); }
      last = [x, y];
    } else if (code === 2) {
      flush();
      colorIndex += 1;
      last = null;
    } else if (code === 3 || code === 4) {
      last = null;
    }
  }
  flush();

  if (options.showJumps) {
    ctx.lineWidth = Math.max(0.5, threadPx * 0.2);
    ctx.strokeStyle = "rgba(128,128,128,0.6)";
    ctx.setLineDash([4, 4]);
    ctx.stroke(jumps);
    ctx.setLineDash([]);
  }
}

/** A view that centers `widthMM` x `heightMM` in a canvas with a margin. */
export function fitView(canvasW: number, canvasH: number, widthMM: number, heightMM: number, marginPx = 32): View {
  const scale = Math.min((canvasW - marginPx * 2) / widthMM, (canvasH - marginPx * 2) / heightMM);
  return {
    scale,
    offsetX: (canvasW - widthMM * scale) / 2,
    offsetY: (canvasH - heightMM * scale) / 2,
  };
}
