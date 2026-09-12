import { useEffect, useRef, useState } from "react";
import type { CatalogSize, DigitizeResponse, StitchDocument } from "../types";
import { PAPER, drawPlan, fitView, type View } from "../render";

interface Props {
  document: StitchDocument;
  digitized: DigitizeResponse | null;
  hoop: CatalogSize | null;
  stale: boolean;
  showJumps: boolean;
}

/** The stitch preview: pan with drag, zoom with the wheel, double-click to refit. */
export default function StitchCanvas({ document: doc, digitized, hoop, stale, showJumps }: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const wrapRef = useRef<HTMLDivElement>(null);
  const [view, setView] = useState<View | null>(null);
  const [size, setSize] = useState({ w: 0, h: 0 });
  const [fitNonce, setFitNonce] = useState(0);
  const drag = useRef<{ x: number; y: number; ox: number; oy: number } | null>(null);

  // Track the wrapper's CSS size; the canvas backing store follows DPR.
  useEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    const ro = new ResizeObserver(([entry]) => {
      const { width, height } = entry.contentRect;
      setSize({ w: Math.floor(width), h: Math.floor(height) });
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // Refit whenever the design's physical size or the canvas size changes.
  const fitKey = `${size.w}x${size.h}:${doc.physicalWidthMM}x${doc.physicalHeightMM}:${hoop?.name ?? ""}:${fitNonce}`;
  useEffect(() => {
    if (size.w === 0 || size.h === 0) return;
    const w = hoop ? Math.max(hoop.widthMM, doc.physicalWidthMM) : doc.physicalWidthMM;
    const h = hoop ? Math.max(hoop.heightMM, doc.physicalHeightMM) : doc.physicalHeightMM;
    const v = fitView(size.w, size.h, w, h);
    // Center the design inside the (possibly larger) hoop frame.
    v.offsetX += ((w - doc.physicalWidthMM) / 2) * v.scale;
    v.offsetY += ((h - doc.physicalHeightMM) / 2) * v.scale;
    setView(v);
  }, [fitKey]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || !view || size.w === 0) return;
    const dpr = window.devicePixelRatio || 1;
    canvas.width = Math.floor(size.w * dpr);
    canvas.height = Math.floor(size.h * dpr);
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = PAPER;
    ctx.fillRect(0, 0, size.w, size.h);

    const { scale, offsetX, offsetY } = view;
    // Hoop frame, centered on the design.
    if (hoop) {
      const hx = offsetX + ((doc.physicalWidthMM - hoop.widthMM) / 2) * scale;
      const hy = offsetY + ((doc.physicalHeightMM - hoop.heightMM) / 2) * scale;
      ctx.strokeStyle = "rgba(26,111,209,0.35)";
      ctx.lineWidth = 1.5;
      ctx.setLineDash([6, 5]);
      ctx.strokeRect(hx, hy, hoop.widthMM * scale, hoop.heightMM * scale);
      ctx.setLineDash([]);
      ctx.fillStyle = "rgba(26,111,209,0.7)";
      ctx.font = "12px system-ui, sans-serif";
      ctx.fillText(hoop.name, hx + 6, hy - 6);
    }
    // Design bounds.
    ctx.strokeStyle = "rgba(0,0,0,0.12)";
    ctx.lineWidth = 1;
    ctx.strokeRect(offsetX, offsetY, doc.physicalWidthMM * scale, doc.physicalHeightMM * scale);

    if (digitized) {
      drawPlan(ctx, digitized.plan.commands, digitized.colors, view, { showJumps });
    }
  }, [view, size, digitized, hoop, doc.physicalWidthMM, doc.physicalHeightMM, showJumps]);

  const onWheel = (e: React.WheelEvent) => {
    if (!view) return;
    e.preventDefault();
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const mx = e.clientX - rect.left, my = e.clientY - rect.top;
    const factor = Math.exp(-e.deltaY * 0.0015);
    const scale = Math.min(view.scale * factor, 200);
    const k = scale / view.scale;
    setView({ scale, offsetX: mx - (mx - view.offsetX) * k, offsetY: my - (my - view.offsetY) * k });
  };

  return (
    <div ref={wrapRef} className={"canvas-wrap" + (stale ? " stale" : "")}
      onWheel={onWheel}
      onPointerDown={(e) => { if (view) { drag.current = { x: e.clientX, y: e.clientY, ox: view.offsetX, oy: view.offsetY }; (e.target as Element).setPointerCapture(e.pointerId); } }}
      onPointerMove={(e) => { const d = drag.current; if (d && view) setView({ ...view, offsetX: d.ox + e.clientX - d.x, offsetY: d.oy + e.clientY - d.y }); }}
      onPointerUp={() => { drag.current = null; }}
      onDoubleClick={() => setFitNonce((n) => n + 1)}
    >
      <canvas ref={canvasRef} style={{ width: size.w, height: size.h }} />
      {stale && <div className="canvas-hint">Refreshing preview…</div>}
      {!digitized && !stale && <div className="canvas-hint">No stitches yet</div>}
    </div>
  );
}
