// The web edition's AppState: what's imported, the document, the latest
// digitize result, and the flow between the start screen, the setup
// questions and the editor. The server keeps nothing between requests,
// so everything the Mac app holds in memory lives here instead.

import { useCallback, useEffect, useRef, useState } from "react";
import { api } from "./api";
import { decodeImage, isSVGFile, type DecodedImage } from "./decode";
import type { Catalog, CatalogSize, ColorPresetId, DigitizeResponse, FabricType, ImportResponse, StitchDocument, StitchType } from "./types";
import DropZone from "./components/DropZone";
import SetupFlow, { type SetupAnswers } from "./components/SetupFlow";
import Editor from "./components/Editor";

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

/** The Mac app's default hoop is commonHoops[2] (6" × 10"). */
const DEFAULT_HOOP_INDEX = 2;

export default function App() {
  const [catalog, setCatalog] = useState<Catalog | null>(null);
  const [phase, setPhase] = useState<Phase>("start");
  const [imported, setImported] = useState<Imported | null>(null);
  const [answers, setAnswers] = useState<SetupAnswers | null>(null);
  const [document, setDocument] = useState<StitchDocument | null>(null);
  const [digitized, setDigitized] = useState<DigitizeResponse | null>(null);
  const [matchToThreadLibrary, setMatchToThreadLibrary] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [stale, setStale] = useState(false);
  const generation = useRef(0);
  const digitizeTimer = useRef<number | null>(null);

  useEffect(() => {
    api.catalog().then(setCatalog).catch((e) => setError(`Couldn't reach the PiperStitch server: ${e.message}`));
  }, []);

  const fail = (e: unknown) => setError(e instanceof Error ? e.message : String(e));

  // --- digitize (debounced, latest-wins) -------------------------------

  const digitizeNow = useCallback(async (doc: StitchDocument, hoop: CatalogSize | null) => {
    const gen = ++generation.current;
    setStale(true);
    try {
      const result = await api.digitize(doc, hoop?.widthMM, hoop?.heightMM);
      if (gen !== generation.current) return; // superseded by a newer edit
      setDigitized(result);
      setError(null);
    } catch (e) {
      if (gen === generation.current) fail(e);
    } finally {
      if (gen === generation.current) setStale(false);
    }
  }, []);

  const scheduleDigitize = useCallback((doc: StitchDocument, hoop: CatalogSize | null) => {
    setStale(true);
    if (digitizeTimer.current) window.clearTimeout(digitizeTimer.current);
    digitizeTimer.current = window.setTimeout(() => digitizeNow(doc, hoop), 250);
  }, [digitizeNow]);

  const updateDocument = (next: StitchDocument, hoop = answers?.hoop ?? null) => {
    setDocument(next);
    scheduleDigitize(next, hoop);
  };

  // --- import ----------------------------------------------------------

  const runImport = async (file: File, maxColors: number, hoop: CatalogSize | null): Promise<Imported> => {
    const name = file.name.replace(/\.[^.]+$/, "");
    const hoopOpts = { hoopWidthMM: hoop?.widthMM, hoopHeightMM: hoop?.heightMM };
    if (isSVGFile(file)) {
      const svgText = await file.text();
      const response = await api.importSVG(svgText, hoopOpts);
      return { name, fileName: file.name, isVector: true, decoded: null, svgText, response, maxColors };
    }
    setBusy("Reading image…");
    const decoded = await decodeImage(file);
    setBusy("Finding shapes…");
    const response = await api.importRaster(decoded.rgba, decoded.width, decoded.height, { maxColors, ...hoopOpts });
    return { name, fileName: file.name, isVector: false, decoded, svgText: null, response, maxColors };
  };

  const onFile = async (file: File) => {
    if (!catalog) return;
    setError(null);
    setBusy("Reading file…");
    try {
      const defaultHoop = catalog.hoops[DEFAULT_HOOP_INDEX] ?? null;
      const preset: ColorPresetId = "normalEmbroidery";
      const maxColors = catalog.colorPresets.find((c) => c.id === preset)!.maxColors;
      const imp = await runImport(file, maxColors, defaultHoop);
      if (imp.response.source.shapes.length === 0) throw new Error("No usable shapes were found in this file.");
      setImported(imp);
      setAnswers({
        placement: null,
        widthMM: imp.response.recommendedWidthMM,
        heightMM: imp.response.recommendedHeightMM,
        lockAspect: true,
        hoop: defaultHoop,
        hoopMode: "specific",
        fabric: "standard",
        colorPreset: preset,
      });
      setDocument(null);
      setDigitized(null);
      setPhase("setup");
    } catch (e) {
      fail(e);
    } finally {
      setBusy(null);
    }
  };

  // --- build (source shapes + answers -> document) ---------------------

  const buildFrom = async (imp: Imported, a: SetupAnswers, match: boolean) => {
    const { document: doc } = await api.build({
      source: imp.response.source, name: imp.name, widthMM: a.widthMM, heightMM: a.heightMM,
      matchToThreadLibrary: match, fabricType: a.fabric,
    });
    return doc;
  };

  /** Raster only: a different colour count means tracing the pixels again. */
  const reimportIfNeeded = async (imp: Imported, preset: ColorPresetId, hoop: CatalogSize | null): Promise<Imported> => {
    if (!catalog || imp.isVector || !imp.decoded) return imp;
    const maxColors = catalog.colorPresets.find((c) => c.id === preset)!.maxColors;
    if (maxColors === imp.maxColors) return imp;
    setBusy("Finding shapes…");
    const response = await api.importRaster(imp.decoded.rgba, imp.decoded.width, imp.decoded.height,
      { maxColors, hoopWidthMM: hoop?.widthMM, hoopHeightMM: hoop?.heightMM });
    return { ...imp, response, maxColors };
  };

  const onSetupFinish = async (a: SetupAnswers) => {
    if (!imported) return;
    setError(null);
    setBusy("Creating embroidery…");
    try {
      const imp = await reimportIfNeeded(imported, a.colorPreset, a.hoop);
      setImported(imp);
      setAnswers(a);
      const doc = await buildFrom(imp, a, matchToThreadLibrary);
      setDocument(doc);
      setPhase("editor");
      await digitizeNow(doc, a.hoop);
    } catch (e) {
      fail(e);
    } finally {
      setBusy(null);
    }
  };

  // --- editor actions ---------------------------------------------------

  const onResize = async (widthMM: number, heightMM: number) => {
    if (!document || !answers) return;
    setBusy("Resizing…");
    try {
      const next = { ...answers, widthMM, heightMM };
      setAnswers(next);
      const { document: doc } = await api.resize(document, widthMM, heightMM);
      updateDocument(doc, next.hoop);
    } catch (e) { fail(e); } finally { setBusy(null); }
  };

  const onHoop = (hoop: CatalogSize | null) => {
    if (!answers || !document) return;
    setAnswers({ ...answers, hoop });
    digitizeNow(document, hoop);
  };

  const onFabric = (fabric: FabricType) => {
    if (!answers || !document) return;
    setAnswers({ ...answers, fabric });
    updateDocument({ ...document, objects: document.objects.map((o) => ({ ...o, parameters: { ...o.parameters, fabricType: fabric } })) });
  };

  const onColorPreset = async (preset: ColorPresetId) => {
    if (!imported || !answers) return;
    setBusy("Finding shapes…");
    try {
      const next = { ...answers, colorPreset: preset };
      setAnswers(next);
      const imp = await reimportIfNeeded(imported, preset, next.hoop);
      setImported(imp);
      const doc = await buildFrom(imp, next, matchToThreadLibrary);
      updateDocument(doc, next.hoop);
    } catch (e) { fail(e); } finally { setBusy(null); }
  };

  const onMatchLibrary = async (on: boolean) => {
    if (!imported || !answers) return;
    setMatchToThreadLibrary(on);
    setBusy("Matching colours…");
    try {
      const doc = await buildFrom(imported, answers, on);
      updateDocument(doc);
    } catch (e) { fail(e); } finally { setBusy(null); }
  };

  const onObjectStitchType = (id: string, stitchType: StitchType) => {
    if (!document) return;
    updateDocument({ ...document, objects: document.objects.map((o) => o.id === id ? { ...o, stitchType, stitchTypeIsManualOverride: true } : o) });
  };

  const onDeleteObject = (id: string) => {
    if (!document) return;
    updateDocument({ ...document, objects: document.objects.filter((o) => o.id !== id) });
  };

  const onRedo = async () => {
    if (!imported || !answers) return;
    setBusy("Redoing from original artwork…");
    try {
      const doc = await buildFrom(imported, answers, matchToThreadLibrary);
      updateDocument(doc);
    } catch (e) { fail(e); } finally { setBusy(null); }
  };

  const onExport = async (format: string) => {
    if (!document) return;
    setBusy(`Writing ${format.toUpperCase()}…`);
    try {
      const blob = await api.export(document, format);
      const hoopTag = answers?.hoop ? "-" + answers.hoop.name.replace(/[^0-9x×]+/g, "").replace("×", "x") : "";
      const a = window.document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = `${document.name}${hoopTag}.${format}`;
      a.click();
      setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
    } catch (e) { fail(e); } finally { setBusy(null); }
  };

  const onStartOver = () => {
    generation.current++;
    if (imported?.decoded) URL.revokeObjectURL(imported.decoded.previewURL);
    setImported(null); setAnswers(null); setDocument(null); setDigitized(null); setError(null); setStale(false);
    setPhase("start");
  };

  // --- render -----------------------------------------------------------

  if (!catalog) {
    return <div className="start"><div className="start-brand"><img src="/icon.png" alt="" width={64} height={64} /><h1>PiperStitch</h1>{error ? <p className="error-text">{error}</p> : <p>Loading…</p>}</div></div>;
  }

  if (phase === "setup" && imported && answers) {
    return (
      <SetupFlow catalog={catalog} fileName={imported.fileName} isVector={imported.isVector}
        recommendedWidthMM={imported.response.recommendedWidthMM} recommendedHeightMM={imported.response.recommendedHeightMM}
        aspectRatio={imported.response.aspectRatio} initial={answers} busy={busy}
        onFinish={onSetupFinish} onCancel={onStartOver} />
    );
  }

  if (phase === "editor" && document && answers) {
    return (
      <Editor catalog={catalog} document={document} digitized={digitized} stale={stale} busy={busy} error={error}
        hoop={answers.hoop} fabric={answers.fabric} colorPreset={answers.colorPreset}
        isVector={imported?.isVector ?? true} hasSource={!!imported} matchToThreadLibrary={matchToThreadLibrary}
        previewURL={imported?.decoded?.previewURL ?? null}
        onResize={onResize} onHoop={onHoop} onFabric={onFabric} onColorPreset={onColorPreset} onMatchLibrary={onMatchLibrary}
        onObjectStitchType={onObjectStitchType} onDeleteObject={onDeleteObject} onRedo={onRedo} onExport={onExport} onStartOver={onStartOver} />
    );
  }

  return (
    <>
      {error && <div className="error-bar floating">{error}</div>}
      <DropZone onFile={onFile} busy={busy} />
    </>
  );
}
