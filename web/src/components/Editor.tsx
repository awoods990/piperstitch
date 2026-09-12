import { useState } from "react";
import type { Catalog, CatalogSize, ColorPresetId, DigitizeResponse, FabricType, StitchDocument, StitchType } from "../types";
import { cm, inches } from "../format";
import { PRESET_LABELS } from "./SetupFlow";
import StitchCanvas from "./StitchCanvas";

interface Props {
  catalog: Catalog;
  document: StitchDocument;
  digitized: DigitizeResponse | null;
  stale: boolean;
  busy: string | null;
  error: string | null;
  hoop: CatalogSize | null;
  fabric: FabricType;
  colorPreset: ColorPresetId;
  isVector: boolean;
  hasSource: boolean;
  matchToThreadLibrary: boolean;
  previewURL: string | null;
  onResize: (widthMM: number, heightMM: number) => void;
  onHoop: (hoop: CatalogSize | null) => void;
  onFabric: (fabric: FabricType) => void;
  onColorPreset: (preset: ColorPresetId) => void;
  onMatchLibrary: (on: boolean) => void;
  onObjectStitchType: (objectID: string, stitchType: StitchType) => void;
  onDeleteObject: (objectID: string) => void;
  onRedo: () => void;
  onExport: (format: string) => void;
  onStartOver: () => void;
}

const STITCH_LABELS: Record<StitchType, string> = {
  runningStitch: "Running stitch",
  tripleRun: "Triple run",
  satin: "Satin",
  tatamiFill: "Fill",
};

export default function Editor(p: Props) {
  const { document: doc, digitized, catalog } = p;
  const [w, setW] = useState(+(doc.physicalWidthMM / 10).toFixed(1));
  const [h, setH] = useState(+(doc.physicalHeightMM / 10).toFixed(1));
  const [showJumps, setShowJumps] = useState(false);
  const [showOriginal, setShowOriginal] = useState(false);
  const sizeDirty = Math.abs(w * 10 - doc.physicalWidthMM) > 0.05 || Math.abs(h * 10 - doc.physicalHeightMM) > 0.05;
  const report = digitized?.report;
  const stats = digitized?.stats;

  return (
    <div className="editor">
      <header className="topbar">
        <div className="brand"><img src="/icon.png" alt="" width={28} height={28} /><span>PiperStitch</span></div>
        <div className="doc-name" title={doc.name}>{doc.name}</div>
        <div className="grow" />
        {p.busy && <span className="busy-pill"><span className="spinner small" />{p.busy}</span>}
        <button className="btn ghost" onClick={p.onStartOver}>Start over</button>
      </header>

      {p.error && <div className="error-bar">{p.error}</div>}

      <div className="workspace">
        <main className="canvas-area">
          {showOriginal && p.previewURL ? (
            <div className="original"><img src={p.previewURL} alt="Original artwork" /></div>
          ) : (
            <StitchCanvas document={doc} digitized={digitized} hoop={p.hoop} stale={p.stale} showJumps={showJumps} />
          )}
          <div className="canvas-tools">
            {p.previewURL && <label className="check"><input type="checkbox" checked={showOriginal} onChange={(e) => setShowOriginal(e.target.checked)} /> Show original</label>}
            <label className="check"><input type="checkbox" checked={showJumps} onChange={(e) => setShowJumps(e.target.checked)} /> Show jumps</label>
            <span className="hint">Scroll to zoom · drag to pan · double-click to fit</span>
          </div>
        </main>

        <aside className="sidebar">
          {report && (
            <section className={"panel readiness " + (report.isReadyToSew ? "ready" : "review")}>
              <div className="readiness-head">
                <span className="score">{report.score}<small>/100</small></span>
                <span className="verdict">{report.isReadyToSew ? "Ready to sew" : "Review recommended"}</span>
              </div>
              {report.issues.length > 0 && (
                <ul className="issues">
                  {report.issues.map((i, n) => <li key={n} className={i.severity}><b>{i.severity}</b> {i.message}</li>)}
                </ul>
              )}
            </section>
          )}

          <section className="panel">
            <h3>Download embroidery file</h3>
            <div className="export-grid">
              {[["dst", "DST", "Tajima · most machines"], ["pes", "PES", "Brother · Baby Lock"], ["jef", "JEF", "Janome"], ["exp", "EXP", "Melco · Bernina"], ["vp3", "VP3", "Husqvarna · Pfaff"]].map(([id, label, hint]) => (
                <button key={id} className="btn export" onClick={() => p.onExport(id)} disabled={!digitized || !!p.busy}>
                  <b>{label}</b><small>{hint}</small>
                </button>
              ))}
            </div>
          </section>

          {stats && (
            <section className="panel stats">
              <div><b>{stats.stitchCount.toLocaleString()}</b><span>stitches</span></div>
              <div><b>{digitized!.colors.length}</b><span>colours</span></div>
              <div><b>{stats.colorChangeCount}</b><span>changes</span></div>
              <div><b>{stats.trimCount}</b><span>trims</span></div>
              <div><b>{(stats.totalThreadMM / 1000).toFixed(1)} m</b><span>thread</span></div>
              <div><b>{stats.maxStitchLengthMM.toFixed(1)} mm</b><span>longest</span></div>
            </section>
          )}

          <section className="panel">
            <h3>Finished size</h3>
            <div className="size-row">
              <label>Width <input type="number" step="0.1" min="0.5" value={w} onChange={(e) => setW(Number(e.target.value))} /></label>
              <span className="x">×</span>
              <label>Height <input type="number" step="0.1" min="0.5" value={h} onChange={(e) => setH(Number(e.target.value))} /></label>
              <span className="unit">cm</span>
            </div>
            <div className="size-foot">
              <span className="hint">{inches(doc.physicalWidthMM)}" × {inches(doc.physicalHeightMM)}"</span>
              <button className="btn small" disabled={!sizeDirty || !!p.busy} onClick={() => p.onResize(w * 10, h * 10)}>Apply</button>
            </div>
            <div className="chips">
              {catalog.garmentPresets.map((g) => (
                <button key={g.name} className="chip" onClick={() => { setW(+(g.widthMM / 10).toFixed(1)); setH(+(g.heightMM / 10).toFixed(1)); p.onResize(g.widthMM, g.heightMM); }}>{g.name}</button>
              ))}
            </div>
          </section>

          <section className="panel">
            <h3>Hoop</h3>
            <select value={p.hoop?.name ?? ""} onChange={(e) => p.onHoop(catalog.hoops.find((x) => x.name === e.target.value) ?? null)}>
              <option value="">No hoop (no fit check)</option>
              {catalog.hoops.map((x) => <option key={x.name} value={x.name}>{x.name} — {cm(x.widthMM)} × {cm(x.heightMM)} cm</option>)}
            </select>
          </section>

          <section className="panel">
            <h3>Fabric</h3>
            <select value={p.fabric} onChange={(e) => p.onFabric(e.target.value as FabricType)}>
              {catalog.fabrics.map((f) => <option key={f.id} value={f.id}>{f.displayName}</option>)}
            </select>
          </section>

          <section className="panel">
            <h3>Thread colours</h3>
            {!p.isVector && (
              <select value={p.colorPreset} onChange={(e) => p.onColorPreset(e.target.value as ColorPresetId)}>
                {catalog.colorPresets.map((c) => <option key={c.id} value={c.id}>{PRESET_LABELS[c.id][0]} (up to {c.maxColors})</option>)}
              </select>
            )}
            <label className="check"><input type="checkbox" checked={p.matchToThreadLibrary} onChange={(e) => p.onMatchLibrary(e.target.checked)} disabled={!p.hasSource} /> Match to thread library</label>
            {digitized && (
              <ol className="color-seq">
                {digitized.colors.map((c, i) => (
                  <li key={i}><span className="swatch" style={{ background: `rgb(${c.rgb.r},${c.rgb.g},${c.rgb.b})` }} />{c.name}{c.catalogNumber ? <small> {c.brand} {c.catalogNumber}</small> : null}</li>
                ))}
              </ol>
            )}
          </section>

          <section className="panel">
            <h3>Objects <small>{doc.objects.length}</small></h3>
            <ul className="objects">
              {doc.objects.map((o) => (
                <li key={o.id}>
                  <span className="swatch" style={{ background: `rgb(${o.threadColor.rgb.r},${o.threadColor.rgb.g},${o.threadColor.rgb.b})` }} />
                  <span className="obj-name" title={o.name}>{o.name}</span>
                  <select value={o.stitchType} onChange={(e) => p.onObjectStitchType(o.id, e.target.value as StitchType)} title={o.stitchTypeIsManualOverride ? "Chosen by you" : "Chosen automatically"}>
                    {catalog.stitchTypes.map((t) => <option key={t} value={t}>{STITCH_LABELS[t]}{o.stitchTypeIsManualOverride && t === o.stitchType ? " ✓" : ""}</option>)}
                  </select>
                  <button className="icon-btn" title="Remove this object" onClick={() => p.onDeleteObject(o.id)}>×</button>
                </li>
              ))}
            </ul>
            {p.hasSource && <button className="btn small ghost" onClick={p.onRedo} disabled={!!p.busy}>Redo from original artwork</button>}
          </section>
        </aside>
      </div>
    </div>
  );
}
