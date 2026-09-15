// The right-hand sidebar: the selected object's own settings (mirrors the
// Mac's ObjectInspectorSection), the multi-selection section, and the
// project-wide sections (size, density, hoop, colours, statistics,
// readiness). Every control edits the document in the browser and lets
// App re-digitize; only merge needs the server.

import { useEffect, useState } from "react";
import type { Catalog, CatalogSize, ColorPresetId, DigitizeResponse, EmbroideryObject, FabricType, FillPattern, StitchDocument, StitchType, ThreadColor, UnderlayType } from "../types";
import { cm, inches } from "../format";
import { PRESET_LABELS } from "./SetupFlow";
import { rgbCSS } from "../prefs";

export const STITCH_LABELS: Record<StitchType, string> = { runningStitch: "Running stitch", tripleRun: "Triple run", satin: "Satin", tatamiFill: "Fill" };
const UNDERLAY_LABELS: Record<UnderlayType, string> = { none: "None", centerRun: "Center run", edgeRun: "Edge run", zigzag: "Zigzag", tatami: "Tatami (open rows)", doubleTatami: "Double tatami (cross-hatch)" };

export interface InspectorProps {
  catalog: Catalog;
  document: StitchDocument;
  digitized: DigitizeResponse | null;
  busy: boolean;
  selectedIDs: Set<string>;
  palette: ThreadColor[];
  hoop: CatalogSize | null;
  colorPreset: ColorPresetId;
  isVector: boolean;
  hasSource: boolean;
  matchToThreadLibrary: boolean;
  allowExtendedDensity: boolean;
  globalSatinDensityMM: number;
  globalFillSpacingMM: number;
  onObject: (id: string, update: (o: EmbroideryObject) => EmbroideryObject) => void;
  onDeleteSelected: () => void;
  onMergeShapes: () => void;
  onResize: (widthMM: number, heightMM: number, lockAspect: boolean) => void;
  onHoop: (hoop: CatalogSize | null) => void;
  onColorPreset: (preset: ColorPresetId) => void;
  onMatchLibrary: (on: boolean) => void;
  onExtendedDensity: (on: boolean) => void;
  onGlobalSatinDensity: (mm: number) => void;
  onGlobalFillSpacing: (mm: number) => void;
}

export default function Inspector(p: InspectorProps) {
  const { document: doc, catalog, selectedIDs } = p;
  const selected = doc.objects.filter((o) => selectedIDs.has(o.id));
  return (
    <aside className="sidebar">
      {selected.length === 1 && <ObjectSection object={selected[0]} p={p} />}
      {selected.length > 1 && <MultiSection count={selected.length} p={p} />}
      <SizeSection p={p} />
      <DensitySection p={p} />
      <section className="panel">
        <h3>Hoop</h3>
        <select value={p.hoop?.name ?? ""} onChange={(e) => p.onHoop(catalog.hoops.find((x) => x.name === e.target.value) ?? null)}>
          <option value="">None (no fit check)</option>
          {catalog.hoops.map((x) => <option key={x.name} value={x.name}>{x.name} — {cm(x.widthMM)} × {cm(x.heightMM)} cm</option>)}
        </select>
      </section>
      <section className="panel">
        <h3>Colour reduction</h3>
        <select value={p.colorPreset} disabled={p.isVector || !p.hasSource} onChange={(e) => p.onColorPreset(e.target.value as ColorPresetId)}>
          {catalog.colorPresets.map((c) => <option key={c.id} value={c.id}>{PRESET_LABELS[c.id][0]} (up to {c.maxColors})</option>)}
        </select>
        <span className="hint">Only affects images — vector art keeps its own colours.</span>
      </section>
      <section className="panel">
        <h3>Thread colours</h3>
        <label className="check"><input type="checkbox" checked={p.matchToThreadLibrary} disabled={!p.hasSource} onChange={(e) => p.onMatchLibrary(e.target.checked)} /> Match to thread library</label>
        <span className="hint">Snaps each detected colour to the nearest sewable thread colour instead of the exact artwork colour.</span>
        {p.digitized && (
          <ol className="color-seq">
            {p.digitized.colors.map((c, i) => <li key={i}><span className="swatch" style={{ background: rgbCSS(c.rgb) }} />{c.name}{c.catalogNumber ? <small> {c.brand} {c.catalogNumber}</small> : null}</li>)}
          </ol>
        )}
      </section>
      {p.digitized && <StatsSection d={p.digitized} />}
    </aside>
  );
}

// --- selected object -----------------------------------------------------

function ObjectSection({ object: o, p }: { object: EmbroideryObject; p: InspectorProps }) {
  const set = (update: (o: EmbroideryObject) => EmbroideryObject) => p.onObject(o.id, update);
  const param = <K extends keyof EmbroideryObject["parameters"]>(key: K, value: EmbroideryObject["parameters"][K]) =>
    set((x) => ({ ...x, parameters: { ...x.parameters, [key]: value } }));
  const colorKey = (c: ThreadColor) => `${c.name}|${c.rgb.r},${c.rgb.g},${c.rgb.b}`;
  const paletteWithCurrent = p.palette.some((c) => colorKey(c) === colorKey(o.threadColor)) ? p.palette : [o.threadColor, ...p.palette];
  return (
    <section className="panel selected">
      <h3>Selected object <small>{o.name}</small>
        <button className="icon-btn danger" title="Delete this object" onClick={p.onDeleteSelected}>🗑</button>
      </h3>
      <label className="row">Thread colour
        <select value={colorKey(o.threadColor)} onChange={(e) => { const c = paletteWithCurrent.find((x) => colorKey(x) === e.target.value); if (c) set((x) => ({ ...x, threadColor: c })); }}>
          {paletteWithCurrent.map((c) => <option key={colorKey(c)} value={colorKey(c)}>{c.name}{c.catalogNumber ? ` (${c.catalogNumber})` : ""}</option>)}
        </select>
      </label>
      <label className="row">Stitch type
        <select value={o.stitchType} onChange={(e) => set((x) => ({ ...x, stitchType: e.target.value as StitchType, stitchTypeIsManualOverride: true }))}>
          {p.catalog.stitchTypes.map((t) => <option key={t} value={t}>{STITCH_LABELS[t]}</option>)}
        </select>
      </label>
      {o.stitchTypeIsManualOverride && <span className="hint">Chosen by you — resizing won't change it.</span>}
      <label className="check" title="Sews a placement outline, then a tack-down outline slightly inset, before this object's own stitching."><input type="checkbox" checked={o.isApplique} onChange={(e) => set((x) => ({ ...x, isApplique: e.target.checked }))} /> Appliqué</label>

      {(o.stitchType === "runningStitch" || o.stitchType === "tripleRun") && (
        <NumberRow label="Stitch length (cm)" value={o.parameters.stitchLengthMM / 10} step={0.01} min={0.05} onChange={(v) => param("stitchLengthMM", v * 10)} />
      )}
      {o.stitchType === "satin" && (
        <>
          <DensitySlider label="Density" valueMM={o.parameters.satinDensityMM} floorMM={p.allowExtendedDensity ? 0.1 : 0.2} onChange={(v) => param("satinDensityMM", v)} />
          <NumberRow label="Max width (cm)" value={o.parameters.maxSatinWidthMM / 10} step={0.05} min={0.1} onChange={(v) => param("maxSatinWidthMM", v * 10)} />
          <NumberRow label="Min width (cm)" value={o.parameters.minSatinWidthMM / 10} step={0.05} min={0.05} onChange={(v) => param("minSatinWidthMM", v * 10)} />
        </>
      )}
      {o.stitchType === "tatamiFill" && (
        <>
          <DensitySlider label="Row spacing" valueMM={o.parameters.fillSpacingMM} floorMM={p.allowExtendedDensity ? 0.05 : 0.2} onChange={(v) => param("fillSpacingMM", v)} />
          <label className="row">Fill pattern
            <select value={o.parameters.fillPattern} onChange={(e) => param("fillPattern", e.target.value as FillPattern)}>
              {p.catalog.fillPatterns.map((f) => <option key={f.id} value={f.id}>{f.displayName}</option>)}
            </select>
          </label>
          <AutoRow label="Fill angle" unit="°" value={o.parameters.fillAngleDegrees ?? null} defaultManual={45} step={1} onChange={(v) => param("fillAngleDegrees", v)} />
        </>
      )}
      {(o.stitchType === "satin" || o.stitchType === "tatamiFill") && (
        <>
          <label className="row">Underlay
            <select value={o.parameters.underlayType ?? ""} onChange={(e) => param("underlayType", (e.target.value || null) as UnderlayType | null)}>
              <option value="">Automatic</option>
              {p.catalog.underlayTypes.map((u) => <option key={u} value={u}>{UNDERLAY_LABELS[u]}</option>)}
            </select>
          </label>
          <AutoRow label="Pull compensation" unit="cm" value={o.parameters.pullCompensationMM == null ? null : o.parameters.pullCompensationMM / 10} defaultManual={0.02} step={0.005} onChange={(v) => param("pullCompensationMM", v == null ? null : v * 10)} />
          <AutoRow label="Push compensation" unit="cm" value={o.parameters.pushCompensationMM == null ? null : o.parameters.pushCompensationMM / 10} defaultManual={0.01} step={0.005} onChange={(v) => param("pushCompensationMM", v == null ? null : v * 10)} />
        </>
      )}
      <span className="hint">Updates the preview automatically a moment after each change.</span>
    </section>
  );
}

function MultiSection({ count, p }: { count: number; p: InspectorProps }) {
  return (
    <section className="panel selected">
      <h3>Selected objects <small>{count}</small></h3>
      <div className="btn-row">
        <button className="btn small" onClick={p.onMergeShapes} disabled={p.busy}>Merge shapes</button>
        <button className="btn small danger" onClick={p.onDeleteSelected} disabled={p.busy}>Delete</button>
      </div>
      <span className="hint">Merge joins these outlines into one shape — fixes a letter or detail that came in as several disconnected fragments.</span>
    </section>
  );
}

// --- project-wide ---------------------------------------------------------

function SizeSection({ p }: { p: InspectorProps }) {
  const doc = p.document;
  const [w, setW] = useState(+(doc.physicalWidthMM / 10).toFixed(2));
  const [h, setH] = useState(+(doc.physicalHeightMM / 10).toFixed(2));
  const [lock, setLock] = useState(true);
  useEffect(() => { setW(+(doc.physicalWidthMM / 10).toFixed(2)); setH(+(doc.physicalHeightMM / 10).toFixed(2)); }, [doc.physicalWidthMM, doc.physicalHeightMM]);
  const aspect = doc.physicalHeightMM > 0 ? doc.physicalWidthMM / doc.physicalHeightMM : 1;
  const dirty = Math.abs(w * 10 - doc.physicalWidthMM) > 0.05 || Math.abs(h * 10 - doc.physicalHeightMM) > 0.05;
  const preset = p.catalog.garmentPresets.find((g) => Math.abs(g.widthMM - doc.physicalWidthMM) < 0.5 && Math.abs(g.heightMM - doc.physicalHeightMM) < 0.5);
  return (
    <section className="panel">
      <h3>Finished size</h3>
      <select value={preset?.name ?? ""} onChange={(e) => { const g = p.catalog.garmentPresets.find((x) => x.name === e.target.value); if (g) p.onResize(g.widthMM, g.heightMM, false); }}>
        <option value="">Custom</option>
        {p.catalog.garmentPresets.map((g) => <option key={g.name} value={g.name}>{g.name} — {cm(g.widthMM)} × {cm(g.heightMM)} cm</option>)}
      </select>
      <div className="size-row">
        <label>Width <input type="number" step="0.1" min="0.5" value={w} onChange={(e) => { const v = Number(e.target.value); setW(v); if (lock && aspect > 0) setH(+(v / aspect).toFixed(2)); }} /></label>
        <span className="x">×</span>
        <label>Height <input type="number" step="0.1" min="0.5" value={h} onChange={(e) => { const v = Number(e.target.value); setH(v); if (lock && aspect > 0) setW(+(v * aspect).toFixed(2)); }} /></label>
        <span className="unit">cm</span>
      </div>
      <label className="check"><input type="checkbox" checked={lock} onChange={(e) => setLock(e.target.checked)} /> Lock aspect ratio</label>
      <div className="size-foot">
        <span className="hint">{inches(doc.physicalWidthMM)}" × {inches(doc.physicalHeightMM)}"</span>
        <button className="btn small" disabled={!dirty || p.busy} onClick={() => p.onResize(w * 10, h * 10, lock)}>Apply size</button>
      </div>
    </section>
  );
}

function DensitySection({ p }: { p: InspectorProps }) {
  return (
    <section className="panel">
      <h3>Density (entire project)</h3>
      <label className="check" title="Unlocks the sliders down to the engine's hard floor (0.1 mm satin, 0.05 mm fill) — tighter than most machines and thread handle reliably.">
        <input type="checkbox" checked={p.allowExtendedDensity} onChange={(e) => p.onExtendedDensity(e.target.checked)} /> Push past normal limits
      </label>
      {p.allowExtendedDensity && <span className="hint warn-text">Below the normal range, stitching this tight risks skipped stitches, puckering, or thread breakage on ordinary equipment. Test a small sample first.</span>}
      <DensitySlider label="Satin density" valueMM={p.globalSatinDensityMM} floorMM={p.allowExtendedDensity ? 0.1 : 0.2} onChange={p.onGlobalSatinDensity} />
      <DensitySlider label="Fill row spacing" valueMM={p.globalFillSpacingMM} floorMM={p.allowExtendedDensity ? 0.05 : 0.2} onChange={p.onGlobalFillSpacing} />
      <span className="hint">Applies to every satin or fill object at once. Select an individual object to fine-tune just that one.</span>
    </section>
  );
}

function StatsSection({ d }: { d: DigitizeResponse }) {
  const s = d.stats;
  return (
    <section className="panel">
      <h3>Production statistics</h3>
      <div className="stats">
        <div><b>{s.stitchCount.toLocaleString()}</b><span>stitches</span></div>
        <div><b>{d.colors.length}</b><span>colours</span></div>
        <div><b>{s.colorChangeCount}</b><span>changes</span></div>
        <div><b>{s.trimCount}</b><span>trims</span></div>
        <div><b>{(s.totalThreadMM / 1000).toFixed(1)} m</b><span>thread</span></div>
        <div><b>{s.maxStitchLengthMM.toFixed(1)} mm</b><span>longest</span></div>
      </div>
    </section>
  );
}

// --- small controls ---------------------------------------------------------

function NumberRow({ label, value, step, min, onChange }: { label: string; value: number; step: number; min: number; onChange: (v: number) => void }) {
  const [text, setText] = useState(String(+value.toFixed(3)));
  useEffect(() => setText(String(+value.toFixed(3))), [value]);
  return (
    <label className="row">{label}
      <input type="number" step={step} min={min} value={text} onChange={(e) => setText(e.target.value)}
        onBlur={() => { const v = Number(text); if (Number.isFinite(v) && v >= min) onChange(v); else setText(String(+value.toFixed(3))); }}
        onKeyDown={(e) => { if (e.key === "Enter") (e.target as HTMLInputElement).blur(); }} />
    </label>
  );
}

/** Density in mm, shown in cm like the Mac (0.02–0.10 cm normal range). */
function DensitySlider({ label, valueMM, floorMM, onChange }: { label: string; valueMM: number; floorMM: number; onChange: (mm: number) => void }) {
  const [v, setV] = useState(valueMM);
  useEffect(() => setV(valueMM), [valueMM]);
  return (
    <div className="slider-row">
      <div className="slider-head"><span>{label}</span><b>{(v / 10).toFixed(3)} cm</b></div>
      <input type="range" min={floorMM} max={1.0} step={0.05} value={v} onChange={(e) => setV(Number(e.target.value))} onPointerUp={() => onChange(v)} onKeyUp={() => onChange(v)} />
    </div>
  );
}

/** "Automatic" toggle with a manual value when off — fill angle, pull/push compensation. */
function AutoRow({ label, unit, value, defaultManual, step, onChange }: { label: string; unit: string; value: number | null; defaultManual: number; step: number; onChange: (v: number | null) => void }) {
  return (
    <div className="auto-row">
      <label className="check"><input type="checkbox" checked={value == null} onChange={(e) => onChange(e.target.checked ? null : defaultManual)} /> {label}: Automatic</label>
      {value != null && <NumberRow label={`${label} (${unit})`} value={value} step={step} min={-1000} onChange={(v) => onChange(v)} />}
    </div>
  );
}

export function fabricName(catalog: Catalog, f: FabricType) { return catalog.fabrics.find((x) => x.id === f)?.shortName ?? f; }
