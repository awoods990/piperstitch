import { useEffect, useRef, useState } from "react";
import type { CatalogSize, DigitizeResponse, EmbroideryObject, Point2D, StitchDocument } from "../types";
import { PAPER, drawFabric, drawPlan, fitView, type View } from "../render";
import { boxContains, boxIsEmpty, objectAt, selectionBounds, shapeBounds } from "../geometry";
import { rgbCSS } from "../prefs";
import type { RGBColor } from "../types";
import { COARSE_QUERY, useMediaQuery } from "../useMediaQuery";

export type Tool = "select" | "pan" | "paint" | "erase";

interface Props {
  document: StitchDocument;
  digitized: DigitizeResponse | null;
  hoop: CatalogSize | null;
  stale: boolean;
  showJumps: boolean;
  /** The fabric colour to draw under the stitches; the paper default when absent. */
  fabricColor?: RGBColor | null;
  /** Original artwork, drawn faintly under the stitches when nothing is digitized yet. */
  tool: Tool;
  selectedIDs: Set<string>;
  brushRadiusMM: number;
  paintColor: RGBColor;
  onSelect: (ids: string[], additive: boolean) => void;
  onTranslate: (dxMM: number, dyMM: number) => void;
  onScale: (scale: number, anchorMM: Point2D) => void;
  onStroke: (points: Point2D[], radiusMM: number) => void;
}

type Drag =
  | { kind: "pan"; x: number; y: number; ox: number; oy: number }
  | { kind: "band"; start: Point2D; end: Point2D; additive: boolean }
  | { kind: "move"; start: Point2D; last: Point2D; moved: boolean }
  | { kind: "scale"; anchor: Point2D; corner: Point2D; scale: number }
  | { kind: "stroke"; points: Point2D[] }
  /** Two fingers down: zoom about their midpoint and pan with it. */
  | { kind: "pinch"; dist: number; midX: number; midY: number; scale: number; ox: number; oy: number };

const HANDLE_PX = 8;
/** Fingers are wider than a cursor; a resize handle has to be findable by one. */
const TOUCH_HANDLE_PX = 16;
const DOUBLE_TAP_MS = 320;

/** The design view: stitches, selection, and every canvas tool. */
export default function StitchCanvas(p: Props) {
  const { document: doc, digitized, hoop, tool, selectedIDs } = p;
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const wrapRef = useRef<HTMLDivElement>(null);
  const [view, setView] = useState<View | null>(null);
  const [size, setSize] = useState({ w: 0, h: 0 });
  const [fitNonce, setFitNonce] = useState(0);
  const [drag, setDrag] = useState<Drag | null>(null);
  const [spaceHeld, setSpaceHeld] = useState(false);
  const dragRef = useRef<Drag | null>(null);
  dragRef.current = drag;
  // Touch devices get the gesture hint on the canvas itself, until the
  // first touch shows they've found it.
  const touchDevice = useMediaQuery(COARSE_QUERY);
  const [gestureHintSeen, setGestureHintSeen] = useState(false);
  /** Every finger/pointer currently down, for pinch detection. */
  const pointers = useRef(new Map<number, { x: number; y: number }>());
  const lastTap = useRef<{ t: number; x: number; y: number } | null>(null);

  useEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    const ro = new ResizeObserver(([entry]) => setSize({ w: Math.floor(entry.contentRect.width), h: Math.floor(entry.contentRect.height) }));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  useEffect(() => {
    const down = (e: KeyboardEvent) => { if (e.code === "Space" && !(e.target instanceof HTMLInputElement)) setSpaceHeld(true); };
    const up = (e: KeyboardEvent) => { if (e.code === "Space") setSpaceHeld(false); };
    window.addEventListener("keydown", down); window.addEventListener("keyup", up);
    return () => { window.removeEventListener("keydown", down); window.removeEventListener("keyup", up); };
  }, []);

  const fitKey = `${size.w}x${size.h}:${doc.physicalWidthMM}x${doc.physicalHeightMM}:${hoop?.name ?? ""}:${fitNonce}`;
  useEffect(() => {
    if (size.w === 0 || size.h === 0) return;
    const w = hoop ? Math.max(hoop.widthMM, doc.physicalWidthMM) : doc.physicalWidthMM;
    const h = hoop ? Math.max(hoop.heightMM, doc.physicalHeightMM) : doc.physicalHeightMM;
    const v = fitView(size.w, size.h, w, h);
    v.offsetX += ((w - doc.physicalWidthMM) / 2) * v.scale;
    v.offsetY += ((h - doc.physicalHeightMM) / 2) * v.scale;
    setView(v);
  }, [fitKey]); // eslint-disable-line react-hooks/exhaustive-deps

  const toMM = (clientX: number, clientY: number): Point2D => {
    const rect = wrapRef.current!.getBoundingClientRect();
    const v = view!;
    return { x: (clientX - rect.left - v.offsetX) / v.scale, y: (clientY - rect.top - v.offsetY) / v.scale };
  };
  const toPx = (m: Point2D) => ({ x: view!.offsetX + m.x * view!.scale, y: view!.offsetY + m.y * view!.scale });

  // Live preview of an in-progress move/scale: the transform applied to selected shapes while dragging.
  const previewTransform = (): ((pt: Point2D) => Point2D) | null => {
    if (drag?.kind === "move" && drag.moved) { const dx = drag.last.x - drag.start.x, dy = drag.last.y - drag.start.y; return (pt) => ({ x: pt.x + dx, y: pt.y + dy }); }
    if (drag?.kind === "scale") { const { anchor, scale } = drag; return (pt) => ({ x: anchor.x + (pt.x - anchor.x) * scale, y: anchor.y + (pt.y - anchor.y) * scale }); }
    return null;
  };

  // --- drawing -----------------------------------------------------------
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || !view || size.w === 0) return;
    // Supersample: draw at twice the device resolution and let the browser
    // downscale to the CSS size. Thread edges and the sub-pixel highlight
    // lines come out clean instead of aliased, which matters most at
    // fit-to-window zoom where a stitch is only a pixel or two wide. Capped
    // so a huge canvas on a 3x display can't ask for a backing store the
    // GPU refuses.
    const dpr = window.devicePixelRatio || 1;
    const ss = size.w * size.h * dpr * dpr * 4 <= 24_000_000 ? 2 : 1;
    const res = dpr * ss;
    canvas.width = Math.floor(size.w * res); canvas.height = Math.floor(size.h * res);
    const ctx = canvas.getContext("2d")!;
    ctx.setTransform(res, 0, 0, res, 0, 0);
    ctx.fillStyle = PAPER; ctx.fillRect(0, 0, size.w, size.h);
    const { scale, offsetX, offsetY } = view;
    if (p.fabricColor) {
      // The artwork came on a coloured ground (a navy card, a grey field):
      // draw the fabric that colour, so a white design for a dark shirt
      // is not white on white.
      ctx.fillStyle = `rgb(${p.fabricColor.r},${p.fabricColor.g},${p.fabricColor.b})`;
      ctx.fillRect(offsetX, offsetY, doc.physicalWidthMM * scale, doc.physicalHeightMM * scale);
    }
    drawFabric(ctx, view, doc.physicalWidthMM, doc.physicalHeightMM);

    if (hoop) {
      const hx = offsetX + ((doc.physicalWidthMM - hoop.widthMM) / 2) * scale, hy = offsetY + ((doc.physicalHeightMM - hoop.heightMM) / 2) * scale;
      ctx.strokeStyle = "rgba(26,111,209,0.35)"; ctx.lineWidth = 1.5; ctx.setLineDash([6, 5]);
      ctx.strokeRect(hx, hy, hoop.widthMM * scale, hoop.heightMM * scale); ctx.setLineDash([]);
      // Label inside the top-left corner, not above it: fit-to-window puts
      // the hoop's top edge at the canvas margin, where a label above the
      // line is clipped (the longer Mighty Hoop / Durkee names made this
      // obvious).
      ctx.fillStyle = "rgba(26,111,209,0.7)"; ctx.font = "12px system-ui, sans-serif"; ctx.textBaseline = "top";
      ctx.fillText(hoop.name, hx + 6, hy + 5); ctx.textBaseline = "alphabetic";
    }
    ctx.strokeStyle = "rgba(0,0,0,0.12)"; ctx.lineWidth = 1;
    ctx.strokeRect(offsetX, offsetY, doc.physicalWidthMM * scale, doc.physicalHeightMM * scale);

    if (digitized) drawPlan(ctx, digitized.plan.commands, digitized.colors, view, { showJumps: p.showJumps });

    // Selection: outlines of selected shapes (with any live drag preview) and the handles box.
    const xf = previewTransform();
    const selected = doc.objects.filter((o) => selectedIDs.has(o.id));
    if (selected.length > 0) {
      ctx.strokeStyle = "rgba(26,111,209,0.95)"; ctx.lineWidth = 1.5; ctx.setLineDash([]);
      for (const o of selected) {
        for (const sp of o.shape.subPaths) {
          ctx.beginPath();
          sp.points.forEach((pt, i) => { const q = toPx(xf ? xf(pt) : pt); i ? ctx.lineTo(q.x, q.y) : ctx.moveTo(q.x, q.y); });
          ctx.closePath(); ctx.stroke();
        }
      }
      const b = selectionBounds(selected.map((o) => xf ? { ...o, shape: { subPaths: o.shape.subPaths.map((sp) => ({ ...sp, points: sp.points.map(xf) })) } } : o), new Set(selected.map((o) => o.id)));
      if (!boxIsEmpty(b)) {
        const a = toPx({ x: b.minX, y: b.minY }), c = toPx({ x: b.maxX, y: b.maxY });
        ctx.strokeStyle = "rgba(26,111,209,0.6)"; ctx.setLineDash([4, 3]); ctx.lineWidth = 1;
        ctx.strokeRect(a.x, a.y, c.x - a.x, c.y - a.y); ctx.setLineDash([]);
        if (tool === "select") {
          ctx.fillStyle = "#fff"; ctx.strokeStyle = "rgba(26,111,209,1)";
          for (const [hx, hy] of [[a.x, a.y], [c.x, a.y], [a.x, c.y], [c.x, c.y]]) {
            ctx.fillRect(hx - HANDLE_PX / 2, hy - HANDLE_PX / 2, HANDLE_PX, HANDLE_PX); ctx.strokeRect(hx - HANDLE_PX / 2, hy - HANDLE_PX / 2, HANDLE_PX, HANDLE_PX);
          }
        }
      }
    }
    if (drag?.kind === "band") {
      const a = toPx(drag.start), c = toPx(drag.end);
      ctx.fillStyle = "rgba(26,111,209,0.08)"; ctx.strokeStyle = "rgba(26,111,209,0.8)"; ctx.setLineDash([3, 3]);
      ctx.fillRect(a.x, a.y, c.x - a.x, c.y - a.y); ctx.strokeRect(a.x, a.y, c.x - a.x, c.y - a.y); ctx.setLineDash([]);
    }
    if (drag?.kind === "stroke" && drag.points.length > 0) {
      ctx.lineCap = "round"; ctx.lineJoin = "round"; ctx.lineWidth = p.brushRadiusMM * 2 * scale;
      ctx.strokeStyle = tool === "erase" ? "rgba(220,60,50,0.5)" : rgbCSS(p.paintColor).replace("rgb", "rgba").replace(")", ",0.6)");
      ctx.beginPath(); drag.points.forEach((pt, i) => { const q = toPx(pt); i ? ctx.lineTo(q.x, q.y) : ctx.moveTo(q.x, q.y); }); ctx.stroke();
      if (drag.points.length === 1) { const q = toPx(drag.points[0]); ctx.beginPath(); ctx.arc(q.x, q.y, p.brushRadiusMM * scale, 0, Math.PI * 2); ctx.fillStyle = ctx.strokeStyle; ctx.fill(); }
    }
  }, [view, size, digitized, hoop, doc, selectedIDs, drag, tool, p.showJumps, p.fabricColor, p.brushRadiusMM, p.paintColor]); // eslint-disable-line react-hooks/exhaustive-deps

  // --- interaction --------------------------------------------------------
  const handleAt = (px: number, py: number, touch: boolean): { anchor: Point2D; corner: Point2D } | null => {
    if (tool !== "select" || selectedIDs.size === 0) return null;
    const reach = touch ? TOUCH_HANDLE_PX : HANDLE_PX;
    const b = selectionBounds(doc.objects, selectedIDs);
    if (boxIsEmpty(b)) return null;
    const corners = [[b.minX, b.minY, b.maxX, b.maxY], [b.maxX, b.minY, b.minX, b.maxY], [b.minX, b.maxY, b.maxX, b.minY], [b.maxX, b.maxY, b.minX, b.minY]];
    for (const [cx, cy, ax, ay] of corners) {
      const q = toPx({ x: cx, y: cy });
      if (Math.abs(q.x - px) <= reach && Math.abs(q.y - py) <= reach) return { corner: { x: cx, y: cy }, anchor: { x: ax, y: ay } };
    }
    return null;
  };

  const pinchFrom = (v: View): Drag => {
    const [a, b] = [...pointers.current.values()];
    return { kind: "pinch", dist: Math.hypot(b.x - a.x, b.y - a.y), midX: (a.x + b.x) / 2, midY: (a.y + b.y) / 2, scale: v.scale, ox: v.offsetX, oy: v.offsetY };
  };

  const onPointerDown = (e: React.PointerEvent) => {
    if (!view) return;
    try { (e.target as Element).setPointerCapture(e.pointerId); } catch { /* synthetic events have no capture */ }
    const rect = wrapRef.current!.getBoundingClientRect();
    const px = e.clientX - rect.left, py = e.clientY - rect.top;
    const touch = e.pointerType === "touch";
    if (touch && !gestureHintSeen) setGestureHintSeen(true);
    pointers.current.set(e.pointerId, { x: px, y: py });
    // A second finger turns whatever was happening into a pinch. Any
    // half-done move/stroke is dropped rather than committed -- the first
    // finger was on its way to a zoom, not an edit.
    if (pointers.current.size === 2) { setDrag(pinchFrom(view)); return; }
    if (pointers.current.size > 2) return;
    const m = toMM(e.clientX, e.clientY);
    const additive = e.shiftKey || e.metaKey || e.ctrlKey;
    if (tool === "pan" || spaceHeld || e.button === 1 || e.button === 2) { setDrag({ kind: "pan", x: e.clientX, y: e.clientY, ox: view.offsetX, oy: view.offsetY }); return; }
    if (tool === "paint" || tool === "erase") { setDrag({ kind: "stroke", points: [m] }); return; }
    const handle = handleAt(px, py, touch);
    if (handle) { setDrag({ kind: "scale", anchor: handle.anchor, corner: handle.corner, scale: 1 }); return; }
    const hit = objectAt(doc.objects, m);
    if (hit) {
      if (!selectedIDs.has(hit.id)) p.onSelect([hit.id], additive);
      else if (additive) { p.onSelect([hit.id], true); return; }
      setDrag({ kind: "move", start: m, last: m, moved: false });
      return;
    }
    // A finger on empty canvas pans -- that's what every touch app does,
    // and a rubberband needs a modifier key a phone doesn't have. A plain
    // tap still clears the selection (see onPointerUp).
    if (touch) { setDrag({ kind: "pan", x: e.clientX, y: e.clientY, ox: view.offsetX, oy: view.offsetY }); return; }
    setDrag({ kind: "band", start: m, end: m, additive });
  };

  const onPointerMove = (e: React.PointerEvent) => {
    const d = dragRef.current;
    if (!d || !view) return;
    if (pointers.current.has(e.pointerId)) {
      const rect = wrapRef.current!.getBoundingClientRect();
      pointers.current.set(e.pointerId, { x: e.clientX - rect.left, y: e.clientY - rect.top });
    }
    if (d.kind === "pinch") {
      if (pointers.current.size < 2) return;
      const [a, b] = [...pointers.current.values()];
      const dist = Math.hypot(b.x - a.x, b.y - a.y);
      const scale = Math.min(Math.max(d.scale * (d.dist > 0 ? dist / d.dist : 1), 0.2), 200);
      const k = scale / d.scale;
      const midX = (a.x + b.x) / 2, midY = (a.y + b.y) / 2;
      // Keep the point under the original midpoint under the new midpoint.
      setView({ scale, offsetX: midX - (d.midX - d.ox) * k, offsetY: midY - (d.midY - d.oy) * k });
      return;
    }
    const m = toMM(e.clientX, e.clientY);
    switch (d.kind) {
      case "pan": setView({ ...view, offsetX: d.ox + e.clientX - d.x, offsetY: d.oy + e.clientY - d.y }); break;
      case "band": setDrag({ ...d, end: m }); break;
      case "move": setDrag({ ...d, last: m, moved: d.moved || Math.hypot(m.x - d.start.x, m.y - d.start.y) * view.scale > 3 }); break;
      case "scale": {
        const dist = (q: Point2D) => Math.hypot(q.x - d.anchor.x, q.y - d.anchor.y);
        const base = dist(d.corner);
        setDrag({ ...d, scale: base > 0 ? Math.max(0.05, dist(m) / base) : 1 });
        break;
      }
      case "stroke": {
        const last = d.points[d.points.length - 1];
        if (Math.hypot(m.x - last.x, m.y - last.y) * view.scale >= 2) setDrag({ ...d, points: [...d.points, m] });
        break;
      }
    }
  };

  const onPointerUp = (e: React.PointerEvent) => {
    const d = dragRef.current;
    pointers.current.delete(e.pointerId);
    if (d?.kind === "pinch") {
      // Lifting one finger ends the pinch; the remaining finger starts
      // nothing new (it'd be a surprise pan from a stale origin).
      if (pointers.current.size === 0) setDrag(null);
      return;
    }
    setDrag(null);
    if (!d) return;
    if (e.pointerType === "touch") {
      // Double-tap to fit, and a plain tap on empty canvas clears the
      // selection -- the touch pan above replaced the band that used to.
      const rect = wrapRef.current!.getBoundingClientRect();
      const px = e.clientX - rect.left, py = e.clientY - rect.top;
      const now = performance.now(), prev = lastTap.current;
      const stationary = d.kind === "pan" && Math.hypot(e.clientX - d.x, e.clientY - d.y) < 8;
      if (prev && now - prev.t < DOUBLE_TAP_MS && Math.hypot(px - prev.x, py - prev.y) < 30) {
        lastTap.current = null;
        setFitNonce((n) => n + 1);
        return;
      }
      lastTap.current = { t: now, x: px, y: py };
      if (stationary && tool === "select" && !spaceHeld) { p.onSelect([], false); return; }
    }
    switch (d.kind) {
      case "band": {
        const box = { minX: Math.min(d.start.x, d.end.x), minY: Math.min(d.start.y, d.end.y), maxX: Math.max(d.start.x, d.end.x), maxY: Math.max(d.start.y, d.end.y) };
        const dragged = view && Math.hypot(d.end.x - d.start.x, d.end.y - d.start.y) * view.scale > 3;
        if (!dragged) { if (!d.additive) p.onSelect([], false); return; }
        // Only objects the band fully encloses -- a band that merely
        // clips the edge of a big neighbor shouldn't grab it.
        p.onSelect(doc.objects.filter((o) => boxContains(box, shapeBounds(o.shape))).map((o) => o.id), d.additive);
        break;
      }
      case "move": if (d.moved) p.onTranslate(d.last.x - d.start.x, d.last.y - d.start.y); break;
      case "scale": if (Math.abs(d.scale - 1) > 0.001) p.onScale(d.scale, d.anchor); break;
      case "stroke": p.onStroke(d.points, p.brushRadiusMM); break;
    }
  };

  const onWheel = (e: React.WheelEvent) => {
    if (!view) return;
    e.preventDefault();
    const rect = wrapRef.current!.getBoundingClientRect();
    const mx = e.clientX - rect.left, my = e.clientY - rect.top;
    const scale = Math.min(Math.max(view.scale * Math.exp(-e.deltaY * 0.0015), 0.2), 200);
    const k = scale / view.scale;
    setView({ scale, offsetX: mx - (mx - view.offsetX) * k, offsetY: my - (my - view.offsetY) * k });
  };

  const onPointerCancel = (e: React.PointerEvent) => { pointers.current.delete(e.pointerId); if (pointers.current.size === 0) setDrag(null); };

  const cursor = drag?.kind === "pan" || drag?.kind === "pinch" ? "grabbing" : tool === "pan" || spaceHeld ? "grab" : tool === "paint" || tool === "erase" ? "crosshair" : "default";

  return (
    <div ref={wrapRef} className={"canvas-wrap" + (p.stale ? " stale" : "")} style={{ cursor }}
      onWheel={onWheel} onPointerDown={onPointerDown} onPointerMove={onPointerMove} onPointerUp={onPointerUp} onPointerCancel={onPointerCancel}
      onContextMenu={(e) => e.preventDefault()} onDoubleClick={() => setFitNonce((n) => n + 1)}>
      <canvas ref={canvasRef} style={{ width: size.w, height: size.h }} />
      {p.stale && <div className="canvas-hint">Refreshing preview…</div>}
      {!digitized && !p.stale && <div className="canvas-hint">No stitches yet</div>}
      {digitized && !p.stale && touchDevice && !gestureHintSeen && <div className="canvas-hint">Pinch to zoom · drag to move · double-tap to fit</div>}
    </div>
  );
}

export type { EmbroideryObject };
