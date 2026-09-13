// The web edition's AppState: what's imported, the document, selection,
// undo, tools, the latest digitize result, preferences, and the flow
// between the start screen, the setup questions and the editor. The server
// keeps nothing between requests, so everything the Mac app holds in
// memory lives here instead.

import { useCallback, useEffect, useRef, useState } from "react";
import { ApiError, api, type EditResponse, type PendingMerge } from "./api";
import { decodeImage, isSVGFile, type DecodedImage } from "./decode";
import type { AccountState, Catalog, CatalogSize, ColorPresetId, DigitizeResponse, EmbroideryObject, FabricType, ImportResponse, MeResponse, Point2D, ProjectSummary, RGBColor, StitchDocument, ThreadColor } from "./types";
import DropZone from "./components/DropZone";
import SetupFlow, { type SetupAnswers } from "./components/SetupFlow";
import Editor from "./components/Editor";
import { AccountMenu, SignIn, SubscribeWall } from "./components/Account";
import { HelpSheet, LetteringSheet, MergeColorsSheet, SettingsSheet, ThreadLibrarySheet, Modal } from "./components/Sheets";
import type { Tool } from "./components/StitchCanvas";
import { loadPrefs, savePrefs, type Preferences } from "./prefs";
import { transformShape } from "./geometry";
import { generateLetteringShapes, type LetteringSpec } from "./lettering";

interface Imported {
  name: string;
  fileName: string;
  isVector: boolean;
  decoded: DecodedImage | null;
  svgText: string | null;
  response: ImportResponse;
  maxColors: number;
}

type Phase = "start" | "setup" | "editor";
type Sheet = "help" | "settings" | "lettering" | "mergeColors" | "threadLibrary" | null;
interface Snapshot { document: StitchDocument; selectedIDs: string[] }
interface PendingPaint { targetID: string; targetName: string; points: Point2D[]; radiusMM: number }

const MAX_UNDO = 50;

export default function App() {
  const [catalog, setCatalog] = useState<Catalog | null>(null);
  const [me, setMe] = useState<MeResponse | null>(null);
  const [prefs, setPrefsState] = useState<Preferences>(() => loadPrefs());
  const [projects, setProjects] = useState<ProjectSummary[] | null>(null);
  const [projectId, setProjectId] = useState<string | null>(null);
  const [savedAt, setSavedAt] = useState<number | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [phase, setPhase] = useState<Phase>("start");
  const [imported, setImported] = useState<Imported | null>(null);
  const [answers, setAnswers] = useState<SetupAnswers | null>(null);
  const [document, setDocument] = useState<StitchDocument | null>(null);
  const [digitized, setDigitized] = useState<DigitizeResponse | null>(null);
  const [selectedIDs, setSelectedIDs] = useState<Set<string>>(new Set());
  const [tool, setTool] = useState<Tool>("select");
  const [sheet, setSheet] = useState<Sheet>(null);
  const [pendingPaint, setPendingPaint] = useState<PendingPaint | null>(null);
  const [undoStack, setUndoStack] = useState<Snapshot[]>([]);
  const [globalSatin, setGlobalSatin] = useState(0.32);
  const [globalFill, setGlobalFill] = useState(0.32);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [status, setStatus] = useState("");
  const [stale, setStale] = useState(false);
  const generation = useRef(0);
  const digitizeTimer = useRef<number | null>(null);

  const setPrefs = (p: Preferences) => { setPrefsState(p); savePrefs(p); };
  const palette: ThreadColor[] = prefs.threadLibrary.length > 0 ? prefs.threadLibrary : (catalog?.threadPalette ?? []);
  const matchToThreadLibrary = prefs.matchToThreadLibrary;

  useEffect(() => {
    api.catalog().then(setCatalog).catch((e) => setError(`Couldn't reach the PiperStitch server: ${e.message}`));
    const params = new URLSearchParams(window.location.search);
    const subscribed = params.get("subscribed");
    if (subscribed !== null) window.history.replaceState(null, "", window.location.pathname);
    api.me(subscribed !== null).then((m) => {
      setMe(m);
      if (subscribed === "1" && m.account?.status === "active") setNotice("You're subscribed — thank you! Everything's unlocked.");
    }).catch((e) => setError(`Couldn't reach the PiperStitch server: ${e.message}`));
  }, []);

  const signedInAndEntitled = !!me && (!me.authEnabled || (me.signedIn && !!me.account?.entitled));
  useEffect(() => {
    if (signedInAndEntitled && me?.authEnabled && phase === "start") api.listProjects().then(setProjects).catch(() => setProjects([]));
  }, [signedInAndEntitled, me?.authEnabled, phase]);

  const refreshMe = async () => { try { setMe(await api.me(true)); } catch (e) { fail(e); } };
  const onSignedIn = (account: AccountState) => { setMe({ authEnabled: true, signedIn: true, account }); setNotice(null); };
  const onSignOut = async () => {
    try { await api.signOut(); } catch { /* cookie is cleared regardless */ }
    onStartOver(); setProjects(null); setSheet(null);
    setMe({ authEnabled: true, signedIn: false, account: null });
  };

  const fail = (e: unknown) => {
    setError(e instanceof Error ? e.message : String(e));
    if (e instanceof ApiError && e.isAccountProblem) refreshMe();
  };

  // --- digitize (debounced, latest-wins) -------------------------------

  const digitizeNow = useCallback(async (doc: StitchDocument, hoop: CatalogSize | null) => {
    const gen = ++generation.current;
    setStale(true);
    try {
      const result = await api.digitize(doc, hoop?.widthMM, hoop?.heightMM);
      if (gen !== generation.current) return;
      setDigitized(result); setError(null);
      setStatus(`${result.stats.stitchCount.toLocaleString()} stitches, ${result.stats.colorChangeCount} colour change${result.stats.colorChangeCount === 1 ? "" : "s"}.`);
    } catch (e) { if (gen === generation.current) fail(e); }
    finally { if (gen === generation.current) setStale(false); }
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const scheduleDigitize = useCallback((doc: StitchDocument, hoop: CatalogSize | null) => {
    setStale(true);
    if (digitizeTimer.current) window.clearTimeout(digitizeTimer.current);
    digitizeTimer.current = window.setTimeout(() => digitizeNow(doc, hoop), 250);
  }, [digitizeNow]);

  /** Every edit goes through here: snapshot for undo, apply, re-digitize. */
  const commit = (next: StitchDocument, opts: { select?: string[]; status?: string; undoable?: boolean } = {}) => {
    if (document && opts.undoable !== false) setUndoStack((s) => [...s.slice(-(MAX_UNDO - 1)), { document, selectedIDs: [...selectedIDs] }]);
    setDocument(next);
    setSavedAt(null);
    if (opts.select) setSelectedIDs(new Set(opts.select));
    if (opts.status !== undefined) setStatus(opts.status);
    scheduleDigitize(next, answers?.hoop ?? null);
  };

  const onUndo = () => {
    const last = undoStack[undoStack.length - 1];
    if (!last) return;
    setUndoStack((s) => s.slice(0, -1));
    setDocument(last.document); setSelectedIDs(new Set(last.selectedIDs)); setSavedAt(null);
    setStatus("Undid the last edit.");
    scheduleDigitize(last.document, answers?.hoop ?? null);
  };

  // --- import ------------------------------------------------------------

  const runImport = async (file: File, maxColors: number, hoop: CatalogSize | null): Promise<Imported> => {
    const name = file.name.replace(/\.[^.]+$/, "");
    const hoopOpts = { hoopWidthMM: hoop?.widthMM, hoopHeightMM: hoop?.heightMM };
    if (isSVGFile(file)) {
      const svgText = await file.text();
      return { name, fileName: file.name, isVector: true, decoded: null, svgText, response: await api.importSVG(svgText, hoopOpts), maxColors };
    }
    setBusy("Reading image…");
    const decoded = await decodeImage(file);
    setBusy("Finding shapes…");
    const response = await api.importRaster(decoded.rgba, decoded.width, decoded.height, { maxColors, ...hoopOpts });
    return { name, fileName: file.name, isVector: false, decoded, svgText: null, response, maxColors };
  };

  const onFile = async (file: File) => {
    if (!catalog) return;
    setError(null); setBusy("Reading file…");
    try {
      const defaultHoop = catalog.hoops.find((h) => h.name === prefs.defaultHoopName) ?? null;
      const preset = prefs.defaultColorPreset;
      const maxColors = catalog.colorPresets.find((c) => c.id === preset)!.maxColors;
      const imp = await runImport(file, maxColors, defaultHoop);
      if (imp.response.source.shapes.length === 0) throw new Error("No usable shapes were found in this file.");
      setImported(imp);
      setAnswers({ placement: null, widthMM: imp.response.recommendedWidthMM, heightMM: imp.response.recommendedHeightMM, lockAspect: true,
        hoop: defaultHoop, hoopMode: defaultHoop ? "specific" : "none", fabric: prefs.defaultFabric, colorPreset: preset });
      setDocument(null); setDigitized(null); setSelectedIDs(new Set()); setUndoStack([]); setProjectId(null); setSavedAt(null);
      setPhase("setup");
    } catch (e) { fail(e); } finally { setBusy(null); }
  };

  const buildFrom = async (imp: Imported, a: SetupAnswers) => (await api.build({
    source: imp.response.source, name: imp.name, widthMM: a.widthMM, heightMM: a.heightMM,
    matchToThreadLibrary, palette: prefs.threadLibrary.length ? prefs.threadLibrary : undefined, fabricType: a.fabric,
  })).document;

  const reimportIfNeeded = async (imp: Imported, preset: ColorPresetId, hoop: CatalogSize | null): Promise<Imported> => {
    if (!catalog || imp.isVector || !imp.decoded) return imp;
    const maxColors = catalog.colorPresets.find((c) => c.id === preset)!.maxColors;
    if (maxColors === imp.maxColors) return imp;
    setBusy("Finding shapes…");
    const response = await api.importRaster(imp.decoded.rgba, imp.decoded.width, imp.decoded.height, { maxColors, hoopWidthMM: hoop?.widthMM, hoopHeightMM: hoop?.heightMM });
    return { ...imp, response, maxColors };
  };

  const onSetupFinish = async (a: SetupAnswers) => {
    if (!imported) return;
    setError(null); setBusy("Creating embroidery…");
    try {
      const imp = await reimportIfNeeded(imported, a.colorPreset, a.hoop);
      setImported(imp); setAnswers(a);
      const doc = await buildFrom(imp, a);
      setDocument(doc); setUndoStack([]); setPhase("editor");
      setStatus(`Imported ${imp.response.source.shapes.length} shape(s) from ${imp.fileName}.`);
      await digitizeNow(doc, a.hoop);
    } catch (e) { fail(e); } finally { setBusy(null); }
  };

  // --- editor actions -----------------------------------------------------

  const withBusy = async (label: string, fn: () => Promise<void>) => { setBusy(label); try { await fn(); } catch (e) { fail(e); } finally { setBusy(null); } };
  const applyEdit = (r: EditResponse) => commit(r.document, { select: r.selectedIDs, status: r.status });

  const onResize = (widthMM: number, heightMM: number) => withBusy("Resizing…", async () => {
    if (!document || !answers) return;
    setAnswers({ ...answers, widthMM, heightMM });
    commit((await api.resize(document, widthMM, heightMM)).document, { status: `Resized to ${(widthMM / 10).toFixed(1)} × ${(heightMM / 10).toFixed(1)} cm.` });
  });
  const onHoop = (hoop: CatalogSize | null) => { if (!answers || !document) return; setAnswers({ ...answers, hoop }); digitizeNow(document, hoop); };
  const onFabric = (fabric: FabricType) => {
    if (!answers || !document) return;
    setAnswers({ ...answers, fabric });
    commit({ ...document, objects: document.objects.map((o) => ({ ...o, parameters: { ...o.parameters, fabricType: fabric } })) }, { status: `Fabric: ${catalog?.fabrics.find((f) => f.id === fabric)?.displayName ?? fabric}.` });
  };
  const onColorPreset = (preset: ColorPresetId) => withBusy("Finding shapes…", async () => {
    if (!imported || !answers) return;
    const next = { ...answers, colorPreset: preset }; setAnswers(next);
    const imp = await reimportIfNeeded(imported, preset, next.hoop); setImported(imp);
    commit(await buildFrom(imp, next), { select: [] });
  });
  const onMatchLibrary = (on: boolean) => withBusy("Matching colours…", async () => {
    setPrefs({ ...prefs, matchToThreadLibrary: on });
    if (!imported || !answers) return;
    const doc = await api.build({ source: imported.response.source, name: imported.name, widthMM: answers.widthMM, heightMM: answers.heightMM, matchToThreadLibrary: on, palette: prefs.threadLibrary.length ? prefs.threadLibrary : undefined, fabricType: answers.fabric });
    commit(doc.document, { select: [] });
  });
  const onRedo = () => withBusy("Redoing from original artwork…", async () => {
    if (!imported || !answers) return;
    commit(await buildFrom(imported, answers), { select: [], status: "Redone from the original artwork — edits made since import were discarded." });
  });

  const onObject = (id: string, update: (o: EmbroideryObject) => EmbroideryObject) => {
    if (!document) return;
    commit({ ...document, objects: document.objects.map((o) => o.id === id ? update(o) : o) });
  };
  const onDeleteSelected = () => {
    if (!document || selectedIDs.size === 0) return;
    commit({ ...document, objects: document.objects.filter((o) => !selectedIDs.has(o.id)) }, { select: [], status: `Deleted ${selectedIDs.size} object${selectedIDs.size === 1 ? "" : "s"}.` });
  };
  const onSelect = (ids: string[], additive: boolean) => {
    setSelectedIDs((prev) => {
      if (!additive) return new Set(ids);
      const next = new Set(prev);
      for (const id of ids) next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  };
  const onTranslate = (dx: number, dy: number) => {
    if (!document || selectedIDs.size === 0) return;
    commit({ ...document, objects: document.objects.map((o) => selectedIDs.has(o.id) ? { ...o, shape: transformShape(o.shape, (pt) => ({ x: pt.x + dx, y: pt.y + dy })) } : o) }, { status: "Moved." });
  };
  const onScale = (scale: number, anchor: Point2D) => withBusy("Resizing…", async () => {
    if (!document || selectedIDs.size === 0) return;
    const scaled = { ...document, objects: document.objects.map((o) => selectedIDs.has(o.id) ? { ...o, shape: transformShape(o.shape, (pt) => ({ x: anchor.x + (pt.x - anchor.x) * scale, y: anchor.y + (pt.y - anchor.y) * scale })) } : o) };
    const r = await api.classify(scaled, [...selectedIDs]);
    commit(r.document, { status: "Resized." });
  });
  const onMergeShapes = () => withBusy("Merging…", async () => { if (!document) return; applyEdit(await api.mergeShapes(document, [...selectedIDs])); });
  const onMergeColors = (sources: RGBColor[], target: ThreadColor) => {
    if (!document) return;
    const keys = new Set(sources.map((c) => `${c.r},${c.g},${c.b}`));
    commit({ ...document, objects: document.objects.map((o) => keys.has(`${o.threadColor.rgb.r},${o.threadColor.rgb.g},${o.threadColor.rgb.b}`) ? { ...o, threadColor: target } : o) }, { status: `Merged ${sources.length} colour${sources.length === 1 ? "" : "s"} into ${target.name}.` });
  };
  const onStroke = (points: Point2D[], radiusMM: number) => withBusy(tool === "erase" ? "Erasing…" : "Painting…", async () => {
    if (!document) return;
    if (tool === "erase") { const r = await api.erase(document, points, radiusMM, [...selectedIDs]); if (r.status) applyEdit(r); return; }
    const selectedID = selectedIDs.size === 1 ? [...selectedIDs][0] : undefined;
    const r = await api.paint({ document, points, radiusMM, mode: "auto", selectedID, paintColor: prefs.paintColor, matchToThreadLibrary, palette: prefs.threadLibrary.length ? prefs.threadLibrary : undefined });
    if ("pendingMerge" in r) { setPendingPaint({ ...(r as PendingMerge).pendingMerge, points, radiusMM }); return; }
    if (r.status) applyEdit(r);
  });
  const resolvePaint = (mode: "extend" | "separate") => withBusy("Painting…", async () => {
    if (!document || !pendingPaint) return;
    const pp = pendingPaint; setPendingPaint(null);
    applyEdit(await api.paint({ document, points: pp.points, radiusMM: pp.radiusMM, mode, targetID: pp.targetID, paintColor: prefs.paintColor, matchToThreadLibrary }) as EditResponse);
  });
  const onAddLettering = async (spec: LetteringSpec, threadColor: ThreadColor, replaceSelected: boolean) => {
    if (!document) return;
    const shapes = await generateLetteringShapes(spec);
    const center = { x: document.physicalWidthMM / 2, y: document.physicalHeightMM / 2 };
    const r = await api.lettering({ document, shapes, capHeightMM: spec.fontSizeMM, threadColor, targetCenter: center, replaceIDs: replaceSelected ? [...selectedIDs] : undefined });
    applyEdit(r); setTool("select");
  };
  const onGlobalSatin = (mm: number) => { setGlobalSatin(mm); if (!document) return; commit({ ...document, objects: document.objects.map((o) => o.stitchType === "satin" ? { ...o, parameters: { ...o.parameters, satinDensityMM: mm } } : o) }); };
  const onGlobalFill = (mm: number) => { setGlobalFill(mm); if (!document) return; commit({ ...document, objects: document.objects.map((o) => o.stitchType === "tatamiFill" ? { ...o, parameters: { ...o.parameters, fillSpacingMM: mm } } : o) }); };

  // keyboard: delete, undo, escape
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (phase !== "editor" || sheet || e.target instanceof HTMLInputElement || e.target instanceof HTMLSelectElement || e.target instanceof HTMLTextAreaElement) return;
      if ((e.key === "Delete" || e.key === "Backspace") && selectedIDs.size > 0) { e.preventDefault(); onDeleteSelected(); }
      if ((e.metaKey || e.ctrlKey) && e.key === "z") { e.preventDefault(); onUndo(); }
      if (e.key === "Escape") { setSelectedIDs(new Set()); setTool("select"); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }); // eslint-disable-line react-hooks/exhaustive-deps

  // --- projects -----------------------------------------------------------

  const onOpenProject = (summary: ProjectSummary) => withBusy("Opening project…", async () => {
    if (!catalog) return;
    const project = await api.getProject(summary.id);
    const doc = project.document;
    const fabric = (doc.objects[0]?.parameters.fabricType ?? "standard") as FabricType;
    const hoop = catalog.hoops.find((h) => h.name === prefs.defaultHoopName) ?? null;
    setImported(null); setProjectId(project.id); setSavedAt(Date.now()); setUndoStack([]); setSelectedIDs(new Set());
    setAnswers({ placement: "custom", widthMM: doc.physicalWidthMM, heightMM: doc.physicalHeightMM, lockAspect: false, hoop, hoopMode: hoop ? "specific" : "none", fabric, colorPreset: prefs.defaultColorPreset });
    setDocument(doc); setDigitized(null); setPhase("editor"); setStatus(`Opened ${project.name}.`);
    await digitizeNow(doc, hoop);
  });
  const onSaveProject = () => withBusy("Saving…", async () => {
    if (!document) return;
    const id = projectId ?? crypto.randomUUID();
    await api.saveProject(id, document.name, document);
    setProjectId(id); setSavedAt(Date.now()); setStatus("Saved to your account.");
  });
  const onDeleteProject = async (summary: ProjectSummary) => {
    if (!window.confirm(`Delete "${summary.name}"? This can't be undone.`)) return;
    try { await api.deleteProject(summary.id); setProjects((p) => (p ?? []).filter((x) => x.id !== summary.id)); } catch (e) { fail(e); }
  };
  const onExport = (format: string) => withBusy(`Writing ${format.toUpperCase()}…`, async () => {
    if (!document) return;
    const blob = await api.export(document, format);
    const hoopTag = answers?.hoop ? "-" + answers.hoop.name.replace(/[^0-9x×]+/g, "").replace("×", "x") : "";
    const a = window.document.createElement("a");
    a.href = URL.createObjectURL(blob); a.download = `${document.name}${hoopTag}.${format}`; a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
    setStatus(`Downloaded ${a.download}.`);
  });
  const onStartOver = () => {
    generation.current++;
    if (imported?.decoded) URL.revokeObjectURL(imported.decoded.previewURL);
    setImported(null); setAnswers(null); setDocument(null); setDigitized(null); setError(null); setStale(false);
    setSelectedIDs(new Set()); setUndoStack([]); setTool("select"); setSheet(null); setPendingPaint(null); setProjectId(null); setSavedAt(null);
    setPhase("start");
  };
  const onNew = () => { if (!document || savedAt || window.confirm("Start a new project? Unsaved changes to this one will be lost.")) onStartOver(); };

  // --- render ------------------------------------------------------------

  if (!catalog || !me) {
    return <div className="start"><div className="start-brand"><img src="/icon.png" alt="" width={64} height={64} /><h1>PiperStitch</h1>{error ? <p className="error-text">{error}</p> : <p>Loading…</p>}</div></div>;
  }
  if (me.authEnabled && !me.signedIn) return <SignIn onSignedIn={onSignedIn} />;
  if (me.authEnabled && me.account && !me.account.entitled) return <SubscribeWall account={me.account} onSignOut={onSignOut} onRefresh={refreshMe} />;

  const accountMenu = me.authEnabled && me.account ? <AccountMenu account={me.account} onSignOut={onSignOut} /> : null;
  const sheets = (
    <>
      {sheet === "help" && <HelpSheet onClose={() => setSheet(null)} />}
      {sheet === "settings" && <SettingsSheet catalog={catalog} prefs={prefs} account={me.account ?? null} onPrefs={setPrefs} onClose={() => setSheet(null)} onSignOut={onSignOut} onRefreshAccount={refreshMe} />}
      {sheet === "threadLibrary" && <ThreadLibrarySheet library={prefs.threadLibrary} onChange={(lib) => setPrefs({ ...prefs, threadLibrary: lib })} onClose={() => setSheet(null)} />}
      {sheet === "lettering" && document && <LetteringSheet palette={palette} selectedCount={selectedIDs.size} onClose={() => setSheet(null)} onAdd={onAddLettering} />}
      {sheet === "mergeColors" && document && <MergeColorsSheet objects={document.objects} palette={palette} onClose={() => setSheet(null)} onMerge={onMergeColors} />}
      {pendingPaint && (
        <Modal title="Extend this object?" onClose={() => setPendingPaint(null)}>
          <p>Your stroke touches <b>{pendingPaint.targetName}</b>. Add the painted area to it, or keep it as a separate shape in the same colour?</p>
          <div className="modal-foot"><button className="btn ghost" onClick={() => setPendingPaint(null)}>Cancel</button><button className="btn" onClick={() => resolvePaint("separate")}>Keep separate</button><button className="btn primary" onClick={() => resolvePaint("extend")}>Extend {pendingPaint.targetName}</button></div>
        </Modal>
      )}
    </>
  );

  if (phase === "setup" && imported && answers) {
    return <SetupFlow catalog={catalog} fileName={imported.fileName} isVector={imported.isVector} recommendedWidthMM={imported.response.recommendedWidthMM}
      recommendedHeightMM={imported.response.recommendedHeightMM} aspectRatio={imported.response.aspectRatio} initial={answers} busy={busy} onFinish={onSetupFinish} onCancel={onStartOver} />;
  }

  if (phase === "editor" && document && answers) {
    return (
      <>
        <Editor catalog={catalog} document={document} digitized={digitized} stale={stale} busy={busy} error={error} status={status}
          prefs={prefs} palette={palette} selectedIDs={selectedIDs} tool={tool} canUndo={undoStack.length > 0}
          hoop={answers.hoop} fabric={answers.fabric} colorPreset={answers.colorPreset} isVector={imported?.isVector ?? true} hasSource={!!imported}
          matchToThreadLibrary={matchToThreadLibrary} globalSatinDensityMM={globalSatin} globalFillSpacingMM={globalFill}
          previewURL={imported?.decoded?.previewURL ?? null} accountMenu={accountMenu} canSave={me.authEnabled} savedAt={savedAt}
          onTool={setTool} onPrefs={setPrefs} onSelect={onSelect} onTranslate={onTranslate} onScale={onScale} onStroke={onStroke}
          onObject={onObject} onDeleteSelected={onDeleteSelected} onMergeShapes={onMergeShapes} onResize={onResize} onHoop={onHoop} onFabric={onFabric}
          onColorPreset={onColorPreset} onMatchLibrary={onMatchLibrary} onExtendedDensity={(on) => setPrefs({ ...prefs, allowExtendedDensity: on })}
          onGlobalSatinDensity={onGlobalSatin} onGlobalFillSpacing={onGlobalFill} onUndo={onUndo} onNew={onNew} onRedo={onRedo} onSave={onSaveProject}
          onExport={onExport} onOpenSheet={setSheet} />
        {sheets}
      </>
    );
  }

  return (
    <>
      {error && <div className="error-bar floating">{error}</div>}
      {notice && <div className="notice-bar floating" onClick={() => setNotice(null)}>{notice}</div>}
      <div className="start-account">{accountMenu}<button className="btn ghost" onClick={() => setSheet("settings")}>⚙ Settings</button><button className="btn ghost" onClick={() => setSheet("help")}>? Help</button></div>
      <DropZone onFile={onFile} busy={busy} projects={me.authEnabled ? projects : null} onOpenProject={onOpenProject} onDeleteProject={onDeleteProject} />
      {sheets}
    </>
  );
}
