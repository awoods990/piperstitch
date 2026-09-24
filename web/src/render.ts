// Draws a stitch plan on a <canvas> the way StitchRenderer does on the
// Mac, plus what makes a real sew-out look the way it does: every stitch
// is stroked at real thread width with round caps, over a soft shadow
// that gives it depth against the fabric, shaded by its DIRECTION -- a
// thread is a cylinder, so a run of parallel stitches catches the light
// or falls into shade depending on which way it runs (this is the sheen
// that makes satin read as satin), and finally a thin bright highlight
// offset perpendicular to the stitch so each one reads as round rather
// than a flat painted stripe. Jumps are hidden (trimmed jumps leave no
// thread; see HiddenTravelRouter). The plan is in design millimeters;
// `view` maps mm to canvas pixels.

import type { RGBColor, ThreadColor, WireCommand } from "./types";

export const THREAD_WIDTH_MM = 0.35;
export const PAPER = "#fbf9f5";

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

/** Light comes from the upper left, as on the Mac. A stitch running
 *  perpendicular to that direction presents its side to the light and
 *  reads brightest; one running along it reads darkest. */
const LIGHT_ANGLE = -Math.PI / 4;
/** How many brightness steps the sheen is quantized into -- enough that
 *  a fan of stitches grades smoothly, few enough that each color is still
 *  drawn as a handful of batched paths rather than one stroke per stitch. */
const SHEEN_LEVELS = 8;
const SHEEN_MIN = 0.86, SHEEN_MAX = 1.1;

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
  const shadowOffset = THREAD_WIDTH_MM * 0.18 * scale;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";

  let colorIndex = 0;
  let bodies: Path2D[] = Array.from({ length: SHEEN_LEVELS }, () => new Path2D());
  let shadow = new Path2D(), highlight = new Path2D(), jumps = new Path2D();
  let parity = false;
  let hasSegment = false;
  let last: [number, number] | null = null;

  const flush = () => {
    if (hasSegment) {
      const c = (colors[Math.min(colorIndex, colors.length - 1)] ?? colors[0])?.rgb ?? { r: 40, g: 40, b: 40 };
      // Shadow first, under everything of this color: a touch wider and
      // offset away from the light, so each stitch stands off the fabric.
      ctx.lineWidth = threadPx * 1.15;
      ctx.strokeStyle = "rgba(20,14,8,0.22)";
      ctx.stroke(shadow);
      for (let i = 0; i < SHEEN_LEVELS; i++) {
        const k = SHEEN_MIN + ((SHEEN_MAX - SHEEN_MIN) * i) / (SHEEN_LEVELS - 1);
        ctx.lineWidth = threadPx;
        ctx.strokeStyle = rgb(c, k, k > 1 ? 4 : 0);
        ctx.stroke(bodies[i]);
      }
      ctx.lineWidth = threadPx * 0.35;
      ctx.strokeStyle = "rgba(255,255,255,0.42)";
      ctx.stroke(highlight);
    }
    bodies = Array.from({ length: SHEEN_LEVELS }, () => new Path2D());
    shadow = new Path2D(); highlight = new Path2D();
    hasSegment = false;
  };

  for (const [code, mx, my] of commands) {
    const x = offsetX + mx * scale, y = offsetY + my * scale;
    if (code === 0) {
      if (last) {
        const dx = x - last[0], dy = y - last[1];
        const len = Math.hypot(dx, dy);
        // Sheen from the stitch's own direction: |sin| of the angle to the
        // light, so a thread across the light is bright and one along it
        // is dark; the alternating parity nudge keeps neighbors reading as
        // separate threads even in a run at one angle.
        const angle = Math.atan2(dy, dx);
        const sheen = Math.abs(Math.sin(angle - LIGHT_ANGLE));
        const level = Math.max(0, Math.min(SHEEN_LEVELS - 1, Math.round(sheen * (SHEEN_LEVELS - 1) + (parity ? 0.4 : -0.4))));
        parity = !parity;
        bodies[level].moveTo(last[0], last[1]); bodies[level].lineTo(x, y);
        shadow.moveTo(last[0] + shadowOffset, last[1] + shadowOffset); shadow.lineTo(x + shadowOffset, y + shadowOffset);
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

/** A faint woven texture over the design area, so stitches sit on
 *  something that reads as fabric rather than blank paper. Drawn at a
 *  fixed pitch in design mm so it zooms with the stitches. */
export function drawFabric(ctx: CanvasRenderingContext2D, view: View, widthMM: number, heightMM: number) {
  const pitchPx = 0.5 * view.scale;
  if (pitchPx < 2) return; // too fine to show at this zoom -- skip rather than moiré
  const x0 = view.offsetX, y0 = view.offsetY, w = widthMM * view.scale, h = heightMM * view.scale;
  ctx.save();
  ctx.beginPath(); ctx.rect(x0, y0, w, h); ctx.clip();
  ctx.strokeStyle = "rgba(90,70,40,0.045)";
  ctx.lineWidth = Math.max(0.5, pitchPx * 0.35);
  ctx.beginPath();
  for (let x = x0; x <= x0 + w; x += pitchPx) { ctx.moveTo(x, y0); ctx.lineTo(x, y0 + h); }
  for (let y = y0; y <= y0 + h; y += pitchPx) { ctx.moveTo(x0, y); ctx.lineTo(x0 + w, y); }
  ctx.stroke();
  ctx.restore();
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


/** A small picture of the stitched design, for the project list.
 *
 *  Drawn from the very commands the canvas paints, so what someone sees in
 *  the picker is what they were looking at when they saved -- not a
 *  re-render that might disagree.
 *
 *  WebP, measured rather than assumed: the same 240px picture is 3-17 KB as
 *  WebP and 21-67 KB as PNG, and the sparse designs are the expensive ones
 *  because anti-aliased thread over open fabric gives PNG nothing to work
 *  with. Browsers that cannot encode WebP quietly hand back a PNG, which is
 *  still accepted.
 */
/** Where a PNG has to stand in for WebP, at a size whose PNG still fits
 *  inside what License Admin will store. */
const PNG_FALLBACK_EDGE = 160;

export function thumbnailDataURL(
  commands: WireCommand[],
  colors: ThreadColor[],
  widthMM: number,
  heightMM: number,
  maxEdge = 240,
): string | null {
  if (!commands.length || !(widthMM > 0) || !(heightMM > 0)) return null;
  const ratio = widthMM / heightMM;

  const paint = (edge: number): HTMLCanvasElement | null => {
    const w = Math.max(24, Math.round(ratio >= 1 ? edge : edge * ratio));
    const h = Math.max(24, Math.round(ratio >= 1 ? edge / ratio : edge));
    const canvas = globalThis.document?.createElement("canvas");
    const ctx = canvas?.getContext("2d");
    if (!canvas || !ctx) return null;
    canvas.width = w;
    canvas.height = h;
    ctx.fillStyle = PAPER;
    ctx.fillRect(0, 0, w, h);
    drawPlan(ctx, commands, colors, fitView(w, h, widthMM, heightMM, 6));
    return canvas;
  };

  const canvas = paint(maxEdge);
  if (!canvas) return null;
  try {
    const webp = canvas.toDataURL("image/webp", 0.82);
    if (webp.startsWith("data:image/webp")) return webp;
    // Safari cannot encode WebP from a canvas (checked on 18.6) and hands
    // back a PNG instead. A PNG of this picture runs to 67 KB where the
    // WebP was 17 KB, which is over what the server will store -- so the
    // fallback is drawn smaller rather than sent and quietly dropped. At
    // 160px a PNG measures 10-32 KB and the box it fills is 56x42.
    const smaller = maxEdge > PNG_FALLBACK_EDGE ? paint(PNG_FALLBACK_EDGE) : null;
    return (smaller ?? canvas).toDataURL("image/png");
  } catch {
    return null;                        // a tainted canvas, in theory; never fail a save over a picture
  }
}
