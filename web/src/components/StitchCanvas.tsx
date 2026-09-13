import { useEffect, useRef, useState } from "react";
import type { CatalogSize, DigitizeResponse, EmbroideryObject, Point2D, StitchDocument } from "../types";
import { PAPER, drawPlan, fitView, type View } from "../render";
import { boxIsEmpty, boxesIntersect, objectAt, selectionBounds, shapeBounds } from "../geometry";
import { rgbCSS } from "../prefs";
import type { RGBColor } from "../types";

export type Tool = "select" | "pan" | "paint" | "erase";

interface Props {
  document: StitchDocument;
  digitized: DigitizeResponse | null;
  hoop: CatalogSize | null;
  stale: boolean;
  showJumps: boolean;
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
  | { kind: "stroke"; points: Point2D[] };

const HANDLE_PX = 8;

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
    const dpr = window.devicePixelRatio || 1;
    canvas.width = Math.floor(size.w * dpr); canvas.height = Math.floor(size.h * dpr);
    const ctx = canvas.getContext("2d")!;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = PAPER; ctx.fillRect(0, 0, size.w, size.h);
    const { scale, offsetX, offsetY } = view;

    if (hoop) {
      const hx = offsetX + ((doc.physicalWidthMM - hoop.widthMM) / 2) * scale, hy = offsetY + ((doc.physicalHeightMM - hoop.heightMM) / 2) * scale;
      ctx.strokeStyle = "rgba(26,111,209,0.35)"; ctx.lineWidth = 1.5; ctx.setLineDash([6, 5]);
      ctx.strokeRect(hx, hy, hoop.widthMM * scale, hoop.heightMM * scale); ctx.setLineDash([]);
      ctx.fillStyle = "rgba(26,111,209,0.7)"; ctx.font = "12px system-ui, sans-serif"; ctx.fillText(hoop.name, hx + 6, hy - 6);
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
  }, [view, size, digitized, hoop, doc, selectedIDs, drag, tool, p.showJumps, p.brushRadiusMM, p.paintColor]); // eslint-disable-line react-hooks/exhaustive-deps

  // --- interaction --------------------------------------------------------
  const handleAt = (px: number, py: number): { anchor: Point2D; corner: Point2D } | null => {
    if (tool !== "select" || selectedIDs.size === 0) return null;
    const b = selectionBounds(doc.objects, selectedIDs);
    if (boxIsEmpty(b)) return null;
    const corners = [[b.minX, b.minY, b.maxX, b.maxY], [b.maxX, b.minY, b.minX, b.maxY], [b.minX, b.maxY, b.maxX, b.minY], [b.maxX, b.maxY, b.minX, b.minY]];
    for (const [cx, cy, ax, ay] of corners) {
      const q = toPx({ x: cx, y: cy });
      if (Math.abs(q.x - px) <= HANDLE_PX && Math.abs(q.y - py) <= HANDLE_PX) return { corner: { x: cx, y: cy }, anchor: { x: ax, y: ay } };
    }
    return null;
  };

  const onPointerDown = (e: React.PointerEvent) => {
    if (!view) return;
    try { (e.target as Element).setPointerCapture(e.pointerId); } catch { /* synthetic events have no capture */ }
    const rect = wrapRef.current!.getBoundingClientRect();
    const px = e.clientX - rect.left, py = e.clientY - rect.top;
    const m = toMM(e.clientX, e.clientY);
    const additive = e.shiftKey || e.metaKey || e.ctrlKey;
    if (tool === "pan" || spaceHeld || e.button === 1 || e.button === 2) { setDrag({ kind: "pan", x: e.clientX, y: e.clientY, ox: view.offsetX, oy: view.offsetY }); return; }
    if (tool === "paint" || tool === "erase") { setDrag({ kind: "stroke", points: [m] }); return; }
    const handle = handleAt(px, py);
    if (handle) { setDrag({ kind: "scale", anchor: handle.anchor, corner: handle.corner, scale: 1 }); return; }
    const hit = objectAt(doc.objects, m);
    if (hit) {
      if (!selectedIDs.has(hit.id)) p.onSelect([hit.id], additive);
      else if (additive) { p.onSelect([hit.id], true); return; }
      setDrag({ kind: "move", start: m, last: m, moved: false });
      return;
    }
    setDrag({ kind: "band", start: m, end: m, additive });
  };

  const onPointerMove = (e: React.PointerEvent) => {
    const d = dragRef.current;
    if (!d || !view) return;
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

  const onPointerUp = () => {
    const d = dragRef.current;
    setDrag(null);
    if (!d) return;
    switch (d.kind) {
      case "band": {
        const box = { minX: Math.min(d.start.x, d.end.x), minY: Math.min(d.start.y, d.end.y), maxX: Math.max(d.start.x, d.end.x), maxY: Math.max(d.start.y, d.end.y) };
        const dragged = view && Math.hypot(d.end.x - d.start.x, d.end.y - d.start.y) * view.scale > 3;
        if (!dragged) { if (!d.additive) p.onSelect([], false); return; }
        p.onSelect(doc.objects.filter((o) => boxesIntersect(shapeBounds(o.shape), box)).map((o) => o.id), d.additive);
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

  const cursor = drag?.kind === "pan" ? "grabbing" : tool === "pan" || spaceHeld ? "grab" : tool === "paint" || tool === "erase" ? "crosshair" : "default";

  return (
    <div ref={wrapRef} className={"canvas-wrap" + (p.stale ? " stale" : "")} style={{ cursor }}
      onWheel={onWheel} onPointerDown={onPointerDown} onPointerMove={onPointerMove} onPointerUp={onPointerUp}
      onContextMenu={(e) => e.preventDefault()} onDoubleClick={() => setFitNonce((n) => n + 1)}>
      <canvas ref={canvasRef} style={{ width: size.w, height: size.h }} />
      {p.stale && <div className="canvas-hint">Refreshing preview…</div>}
      {!digitized && !p.stale && <div className="canvas-hint">No stitches yet</div>}
    </div>
  );
}

export type { EmbroideryObject };
