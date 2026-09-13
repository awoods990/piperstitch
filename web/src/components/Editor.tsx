import { useState } from "react";
import type { CatalogSize, DigitizeResponse, FabricType, StitchDocument } from "../types";
import type { Preferences } from "../prefs";
import { rgbHex, hexRGB } from "../prefs";
import StitchCanvas, { type Tool } from "./StitchCanvas";
import Inspector, { type InspectorProps } from "./Inspector";
import type { Point2D } from "../types";

export interface EditorProps extends Omit<InspectorProps, "busy" | "palette" | "allowExtendedDensity"> {
  busy: string | null;
  error: string | null;
  status: string;
  stale: boolean;
  prefs: Preferences;
  palette: InspectorProps["palette"];
  fabric: FabricType;
  hoop: CatalogSize | null;
  previewURL: string | null;
  digitized: DigitizeResponse | null;
  document: StitchDocument;
  tool: Tool;
  canUndo: boolean;
  accountMenu: React.ReactNode;
  canSave: boolean;
  savedAt: number | null;
  onTool: (t: Tool) => void;
  onPrefs: (p: Preferences) => void;
  onSelect: (ids: string[], additive: boolean) => void;
  onTranslate: (dx: number, dy: number) => void;
  onScale: (scale: number, anchor: Point2D) => void;
  onStroke: (points: Point2D[], radiusMM: number) => void;
  onFabric: (f: FabricType) => void;
  onUndo: () => void;
  onNew: () => void;
  onRedo: () => void;
  onSave: () => void;
  onExport: (format: string) => void;
  onOpenSheet: (s: "help" | "settings" | "lettering" | "mergeColors" | "threadLibrary") => void;
}

const FORMATS: [string, string, string][] = [["dst", "Tajima (.dst)", "most machines"], ["pes", "Brother / Baby Lock (.pes)", ""], ["jef", "Janome (.jef)", ""], ["exp", "Melco / Bernina (.exp)", ""], ["vp3", "Husqvarna Viking / Pfaff (.vp3)", ""]];

export default function Editor(p: EditorProps) {
  const { document: doc, digitized, catalog } = p;
  const [showOriginal, setShowOriginal] = useState(false);
  const [downloadOpen, setDownloadOpen] = useState(false);
  const report = digitized?.report;
  const brushCM = p.prefs.paintBrushRadiusMM / 10;

  return (
    <div className="editor">
      <header className="topbar">
        <div className="brand"><img src="/icon.png" alt="" width={26} height={26} /><span>PiperStitch</span></div>
        <div className="doc-name" title={doc.name}>{doc.name}</div>
        <div className="grow" />
        {p.busy && <span className="busy-pill"><span className="spinner small" />{p.busy}</span>}
        {p.accountMenu}
      </header>

      {/* File row */}
      <div className="toolbar">
        <button className="pill" onClick={p.onNew} title="Start a new project (the current one is kept only if saved).">＋ New</button>
        {p.hasSource && <button className="pill" onClick={p.onRedo} disabled={!!p.busy} title="Discard edits made since import and regenerate fresh from the original artwork.">↻ Start over</button>}
        {p.canSave && <button className="pill" onClick={p.onSave} disabled={!!p.busy} title="Save this project to your account.">{p.savedAt ? "Saved ✓" : "💾 Save"}</button>}
        <button className="pill" onClick={p.onUndo} disabled={!p.canUndo || !!p.busy} title="Undo the last edit.">↶ Back</button>
        <span className="sep" />
        <div className="menu-anchor">
          <button className="pill primary" onClick={() => setDownloadOpen((o) => !o)} disabled={!digitized || !!p.busy}>⬇ Download</button>
          {downloadOpen && (
            <div className="menu" onMouseLeave={() => setDownloadOpen(false)}>
              {FORMATS.map(([id, label, hint]) => <button key={id} onClick={() => { setDownloadOpen(false); p.onExport(id); }}>{label}{hint && <small> · {hint}</small>}</button>)}
            </div>
          )}
        </div>
        <span className="grow" />
        <button className="pill" onClick={() => p.onOpenSheet("help")} title="Definitions of the digitizing terms used throughout this app, and why they matter.">? Help</button>
        <button className="pill" onClick={() => p.onOpenSheet("settings")} title="Account, billing, and preferences.">⚙ Settings</button>
      </div>

      {/* Editing row */}
      <div className="toolbar edit">
        <button className={"pill" + (p.tool === "select" ? " on" : "")} onClick={() => p.onTool("select")} title="Select objects: click, shift-click, or drag a box. Drag to move, corners to resize.">⬚ Select</button>
        <button className={"pill" + (p.tool === "pan" ? " on" : "")} onClick={() => p.onTool("pan")} title="Drag to move around the canvas (or hold Space).">✋ Pan</button>
        <span className="sep" />
        <button className="pill" onClick={() => p.onOpenSheet("mergeColors")} title="Reassign several objects to the same thread colour at once.">⤳ Merge colours</button>
        <button className="pill" onClick={() => p.onOpenSheet("threadLibrary")} title="Define your own thread colours to match against.">🎨 Thread library</button>
        <label className="pill select-pill" title="Adjusts the automatic pull/push compensation for the fabric this design will be sewn on. Applies to every object; an object's own manually-set compensation always wins.">
          Fabric: <select value={p.fabric} onChange={(e) => p.onFabric(e.target.value as FabricType)}>{catalog.fabrics.map((f) => <option key={f.id} value={f.id}>{f.shortName}</option>)}</select>
        </label>
        <span className="sep" />
        <button className="pill" onClick={() => p.onOpenSheet("lettering")} title="Type text and pick a font — clean satin letters generated from the font's own outline.">A Add lettering</button>
        <button className="pill" onClick={p.onMergeShapes} disabled={p.selectedIDs.size < 2 || !!p.busy} title="Join the selected objects' outlines into one shape. Select several first.">⧉ Merge shapes</button>
        <button className={"pill" + (p.tool === "paint" ? " on" : "")} onClick={() => p.onTool(p.tool === "paint" ? "select" : "paint")} title="Draw in missing coverage by hand — extends the selected object, or draws a new shape if nothing's selected.">🖌 Paint</button>
        <button className={"pill danger" + (p.tool === "erase" ? " on" : "")} onClick={() => p.onTool(p.tool === "erase" ? "select" : "erase")} title="Remove coverage by hand — draw over whatever's wrong.">◌ Erase</button>
        {(p.tool === "paint" || p.tool === "erase") && (
          <span className="brush">
            <label title="Brush size">Brush <input type="range" min={0.05} max={1} step={0.05} value={brushCM} onChange={(e) => p.onPrefs({ ...p.prefs, paintBrushRadiusMM: Number(e.target.value) * 10 })} /> {brushCM.toFixed(2)} cm</label>
            {p.tool === "paint" && <input type="color" title="Paint colour" value={rgbHex(p.prefs.paintColor)} onChange={(e) => p.onPrefs({ ...p.prefs, paintColor: hexRGB(e.target.value) })} />}
          </span>
        )}
      </div>

      {p.error && <div className="error-bar">{p.error}</div>}

      <div className="workspace">
        <main className="canvas-area">
          {showOriginal && p.previewURL ? (
            <div className="original"><img src={p.previewURL} alt="Original artwork" /></div>
          ) : (
            <StitchCanvas document={doc} digitized={digitized} hoop={p.hoop} stale={p.stale} showJumps={p.prefs.showJumps}
              tool={p.tool} selectedIDs={p.selectedIDs} brushRadiusMM={p.prefs.paintBrushRadiusMM} paintColor={p.prefs.paintColor}
              onSelect={p.onSelect} onTranslate={p.onTranslate} onScale={p.onScale} onStroke={p.onStroke} />
          )}
          <div className="status-bar">
            <span className="status-msg">{p.status}</span>
            <span className="grow" />
            {p.previewURL && <label className="check"><input type="checkbox" checked={showOriginal} onChange={(e) => setShowOriginal(e.target.checked)} /> Show original</label>}
            <span className="hint">Scroll to zoom · Space+drag or Pan to move · double-click to fit</span>
            {report && <span className={"readiness-badge " + (report.isReadyToSew ? "ready" : "review")} title={report.issues.map((i) => `${i.severity}: ${i.message}`).join("\n")}>{report.score}/100 · {report.isReadyToSew ? "Ready to sew" : "Review recommended"}</span>}
          </div>
        </main>

        <Inspector {...p} busy={!!p.busy} palette={p.palette} allowExtendedDensity={p.prefs.allowExtendedDensity} />
      </div>
    </div>
  );
}
