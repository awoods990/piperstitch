// Piper, drawn live -- a TypeScript port of the character rig
// (PiperStitch General Files/Piper Character Rig/piper-rig.html), the same
// geometry, palette and poses as the promo films and the marketing site's
// helper (website/piper.js). Used wherever the app shows him moving.
/* eslint-disable @typescript-eslint/no-explicit-any */
export interface PiperPose { wing?: number; wing2?: number | null; span?: number; head?: number; eye?: string; brow?: number; beak?: number; tail?: number; hop?: number; blink?: number; smile?: number; sx?: number; sy?: number; tilt?: number; flip?: boolean; }
/* ── the rig (ported from piper-rig.html) ─────────────────────────── */
export const C = { rust: "#AA6334", rustD: "#7E4424", rustL: "#C98954", cream: "#F8F2E7", navy: "#112949",
          white: "#FFFFFF", blue: "#2B86E8", blueL: "#A2CEFA", sun: "#F2A93B", sea: "#3FB5A8", mouth: "#963C3E" };
export const BW = 300, BH = 250, ST = 4.5, FOOT = 224 / BH;
const R = function (d: number) { return d * Math.PI / 180; };
function poly(x: any, p: number[][]) { x.beginPath(); x.moveTo(p[0][0], p[0][1]); for (let i = 1; i < p.length; i++) x.lineTo(p[i][0], p[i][1]); x.closePath(); }
function fatPoly(x: any, p: number[][], col: string, grow: number) { poly(x, p); x.fillStyle = col; x.fill(); if (grow) { x.strokeStyle = col; x.lineWidth = grow * 2; x.lineJoin = "round"; x.lineCap = "round"; x.stroke(); } }
function ell(x: any, cx: number, cy: number, rx: number, ry: number, col: string, grow?: number) { x.beginPath(); x.ellipse(cx, cy, rx + (grow || 0), ry + (grow || 0), 0, 0, 6.2832); x.fillStyle = col; x.fill(); }
function line(x: any, p: number[][], col: string, w: number) { x.beginPath(); x.moveTo(p[0][0], p[0][1]); for (let i = 1; i < p.length; i++) x.lineTo(p[i][0], p[i][1]); x.strokeStyle = col; x.lineWidth = w; x.lineJoin = "round"; x.lineCap = "round"; x.stroke(); }
function wingPts(px: number, py: number, span: number, drop: number) {
  return [[px, py], [px + span * .30, py - 7], [px + span * .62, py - 5], [px + span * .88, py + 4], [px + span, py + 14],
          [px + span * .72, py + drop * .72], [px + span * .40, py + drop], [px + span * .14, py + drop * .82]];
}
const DEF: Required<Omit<PiperPose, 'sx' | 'sy' | 'tilt' | 'flip'>> = { wing: -14, wing2: null, span: 76, head: 0, eye: "normal", brow: 0, beak: 0, tail: 0, hop: 0, blink: 0, smile: 1 };
export const POSE: Record<string, PiperPose> = {
  idle: {}, curious: { wing: -16, head: 18, eye: "wide", beak: .2 }, think: { wing: -16, head: 16 },
  point: { wing: -2, span: 106 }, proud: { wing: -10, head: -8, eye: "happy", tail: 20, beak: .35 },
  tuck: { wing: -22, head: -6 }, gasp: { wing: 76, wing2: 92, eye: "wide", beak: 1, head: -10, tail: 14 },
  flap: { wing: 62, wing2: -18, hop: .9 }, cheer: { wing: 110, wing2: 128, hop: 1, eye: "happy", beak: 1, tail: 22 }
};
export function drawPiper(x: any, o: PiperPose) {
  const p: any = { ...DEF }; for (const k in o) if ((o as any)[k] !== undefined) p[k] = (o as any)[k];
  let lift = p.hop * 14, by = -lift;
  [86, 118].forEach((lx, i) => {
    let fy = 224 - (i ? lift * .55 : lift), kx = lx - 5 + i * 4, tipX = kx + 2 + i * 6;
    line(x, [[lx, 152 + by], [kx, 184], [tipX, fy]], C.navy, 5.5);
    [-12, -1, 10].forEach((tx) => { line(x, [[tipX, fy], [tipX + tx, fy + 8]], C.navy, 4.5); });
  });
  let ta = R(p.tail), tl = 44, tx0 = 48, ty0 = 116 + by;
  let tailP = [[tx0, ty0 - 6], [tx0 - tl * Math.cos(ta) + 2, ty0 - tl * Math.sin(ta) - 22], [tx0 - tl * Math.cos(ta) - 6, ty0 - tl * Math.sin(ta) - 10],
               [tx0 - tl * Math.cos(ta) + 4, ty0 - tl * Math.sin(ta) + 8], [tx0 + 2, ty0 + 18]];
  let neckP = [[120, 92 + by], [150, 100 + by], [168, 108 + by], [126, 116 + by]];
  const body = (col: string, grow: number) => { fatPoly(x, tailP, col, grow); ell(x, 100, 122 + by, 62, 49, col, grow); ell(x, 156, 70 + by, 41, 39, col, grow); fatPoly(x, neckP, col, grow); };
  body(C.navy, ST); body(C.cream, 0);
  x.save(); x.beginPath();
  x.moveTo(tailP[0][0], tailP[0][1]); for (let i = 1; i < tailP.length; i++) x.lineTo(tailP[i][0], tailP[i][1]); x.closePath();
  x.ellipse(100, 122 + by, 62, 49, 0, 0, 6.2832); x.ellipse(156, 70 + by, 41, 39, 0, 0, 6.2832);
  x.moveTo(neckP[0][0], neckP[0][1]); for (let i = 1; i < neckP.length; i++) x.lineTo(neckP[i][0], neckP[i][1]); x.closePath(); x.clip();
  fatPoly(x, [[30, 116 + by], [52, 82 + by], [92, 66 + by], [134, 74 + by], [158, 92 + by], [150, 104 + by], [112, 88 + by], [70, 96 + by], [44, 124 + by]], C.rust, 0);
  fatPoly(x, [[120, 44 + by], [140, 28 + by], [168, 26 + by], [192, 40 + by], [196, 58 + by], [172, 44 + by], [140, 44 + by]], C.rust, 0);
  line(x, [[58, 104 + by], [94, 92 + by], [128, 94 + by]], C.rustD, 3.5);
  line(x, [[52, 116 + by], [88, 104 + by], [124, 106 + by]], C.rustL, 3);
  x.restore();
  const wing = (ang: number, col: string, px: number, py: number, span: number, drop: number) => {
    x.save(); x.translate(px, py + by); x.rotate(-R(ang)); x.translate(-px, -(py + by));
    let pts = wingPts(px, py + by, span, drop);
    fatPoly(x, pts, C.navy, ST * .8); fatPoly(x, pts, col, 0);
    line(x, [[px + span * .30, py + by + 6], [px + span * .62, py + by + 9], [px + span * .84, py + by + 16]], col === C.rust ? C.rustD : C.rust, 2.5);
    x.restore();
  };
  if (p.wing2 !== null && p.wing2 !== undefined) wing(p.wing2, C.rustD, 96, 100, 70, 27);
  wing(p.wing, C.rust, 100, 104, p.span, 30);
  let hx = 156, hy = 70 + by, bo = p.beak * 13;
  x.save(); x.translate(hx - 30, hy + 26); x.rotate(-R(p.head)); x.translate(-(hx - 30), -(hy + 26));
  x.save(); x.translate(hx + 32, hy + 4); x.rotate(-R(bo * .45)); x.translate(-(hx + 32), -(hy + 4));
  fatPoly(x, [[hx + 32, hy - 5], [hx + 112, hy + 7], [hx + 108, hy + 11], [hx + 32, hy + 5]], C.navy, 0); x.restore();
  x.save(); x.translate(hx + 32, hy + 4); x.rotate(R(bo)); x.translate(-(hx + 32), -(hy + 4));
  fatPoly(x, [[hx + 32, hy + 5], [hx + 106, hy + 11], [hx + 102, hy + 15], [hx + 32, hy + 13]], C.navy, 0); x.restore();
  if (p.beak > .25) fatPoly(x, [[hx + 34, hy + 1], [hx + 62, hy + 2 + bo * .5], [hx + 34, hy + 9]], C.mouth, 0);
  let ex = hx + 15, ey = hy - 9, eye = p.blink > .5 ? "closed" : p.eye;
  if (eye === "closed") line(x, [[ex - 10, ey], [ex + 10, ey]], C.navy, 4);
  else if (eye === "happy") line(x, [[ex - 11, ey + 4], [ex - 4, ey - 7], [ex + 3, ey - 8], [ex + 11, ey + 2]], C.navy, 5);
  else if (eye === "wide") { ell(x, ex + 1, ey - 1, 16.5, 16.5, C.navy); ell(x, ex + 1, ey - 1, 14, 14, C.white); ell(x, ex + 3, ey + 1, 8, 8, C.navy); ell(x, ex + 5.5, ey - 2, 3, 3, C.white); }
  else { ell(x, ex, ey, 11, 11, C.navy); ell(x, ex + 4, ey - 4, 4, 4, C.white); ell(x, ex - 3.5, ey + 4, 1.9, 1.9, C.white); }
  if (Math.abs(p.brow) > .05) line(x, [[ex - 12, ey - 19 + p.brow * 7], [ex + 11, ey - 19 - p.brow * 7]], C.navy, 4.5);
  if (p.smile > .02) line(x, [[hx + 2, hy + 16], [hx + 14, hy + 20 + p.smile * 3]], C.rustD, 2.6);
  x.restore();
}
/* Piper with his feet at (fx, fy), h tall, with squash, tilt and facing. */
export function place(x: any, fx: number, fy: number, h: number, o: PiperPose) {
  let s = h / BH;
  x.save(); x.translate(fx, fy - h * (FOOT - .5));      // the bird's centre; feet are h*(FOOT-.5) below it
  if (o.tilt) x.rotate(-R(o.tilt));
  x.scale(s * (o.sx || 1) * (o.flip ? -1 : 1), s * (o.sy || 1)); x.translate(-BW / 2, -BH / 2);
  drawPiper(x, o); x.restore();
}
export function bob(n: number) { return { hop: .26 * (.5 + .5 * Math.sin(n * .11)), head: 2.6 * Math.sin(n * .11 * .63), blink: (n % 97) < 4 ? 1 : 0 }; }
export const settle = function (k: number) { return Math.sin(k * Math.PI * 2) * Math.exp(-k * 3) * .22; };
export const easeOut = function (q: number) { return 1 - Math.pow(1 - q, 3); };
