// The web edition's AppState: what's imported, the document, selection,
// undo, tools, the latest digitize result, preferences, and the flow
// between the start screen, the setup questions and the editor. The server
// keeps nothing between requests, so everything the Mac app holds in
// memory lives here instead.

import { useCallback, useEffect, useRef, useState } from "react";
import { ApiError, api, type EditResponse, type PendingMerge } from "./api";
import { decodeImage, isSVGFile, type DecodedImage } from "./decode";
import type { AccountState, Catalog, CatalogSize, ColorPresetId, DigitizeResponse, EmbroideryObject, FabricType, ImportResponse, MeResponse, Point2D, ProjectSummary, RGBColor, StitchDocument, ThreadColor, LaydownSettings, ThreadWeight } from "./types";
import { THREAD_WEIGHTS } from "./types";
import DropZone from "./components/DropZone";
import SetupFlow, { type SetupAnswers } from "./components/SetupFlow";
import { defaultLaydown } from "./components/Inspector";
import Editor from "./components/Editor";
import { AccountMenu, SignIn, SubscribeWall, capturePromoFromURL } from "./components/Account";
import { FeedbackSheet, HelpSheet, LetteringSheet, MergeColorsSheet, OpenProjectsSheet, SendSheet, SettingsSheet, ThreadLibrarySheet, Modal } from "./components/Sheets";
import type { Tool } from "./components/StitchCanvas";
import { loadPrefs, savePrefs, withDefaults, type Preferences } from "./prefs";
import Onboarding from "./components/Onboarding";
import { setDisplayUnits } from "./format";
import { transformShape } from "./geometry";
import { generateLetteringShapes, type LetteringSpec } from "./lettering";
import { blobURLToPNGDataURL, dataURLToBase64, renderDigitizedPNGDataURL, renderSVGPNGDataURL } from "./feedback";

interface Imported {
  name: string;
  fileName: string;
  isVector: boolean;
  decoded: DecodedImage | null;
  svgText: string | null;
  response: ImportResponse;
  maxColors: number;
}

type Phase = "start" | "setup" | "editor" | "onboarding";
type Sheet = "help" | "settings" | "settingsBusiness" | "lettering" | "mergeColors" | "threadLibrary" | "feedback" | "send" | "open" | null;
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
  const [feedbackImages, setFeedbackImages] = useState<{ original: string | null; digitized: string } | null>(null);
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

  const prefsSyncTimer = useRef<number | null>(null);
  // Guided setup: shown once per account, after the first sign-in on an
  // account whose preferences carry no onboarding record; re-runnable
  // from Settings. `prefsPulled` keeps it from flashing before the
  // account's own copy of the preferences has arrived.
  const [prefsPulled, setPrefsPulled] = useState(false);
  const [rerunOnboarding, setRerunOnboarding] = useState<false | "settings" | "link">(false);
  // Once the first-run flow is on screen it stays until it says it's done:
  // finishing the last step records the setup, which would otherwise
  // satisfy the "needs onboarding" test and unmount the finish screen.
  const [firstRunActive, setFirstRunActive] = useState(false);
  // "Start free trial" while signed out: the account gets created inside
  // guided setup rather than on a separate sign-in page.
  const [signUpMode, setSignUpMode] = useState(false);
  // From the sign-up email's link (?trial=1&email=&code=): the setup opens
  // on its code step with both filled in, and verifies on its own.
  const [signUpLink, setSignUpLink] = useState<{ email: string; code: string } | null>(null);
  useEffect(() => { setDisplayUnits(prefs.units); }, [prefs.units]);
  const setPrefs = (p: Preferences) => {
    setPrefsState(p); savePrefs(p);
    // Mirror to the account (debounced) so the same hoops and thread
    // library show up in another browser and in PiperStitch Proofs.
    if (me?.signedIn) {
      if (prefsSyncTimer.current) window.clearTimeout(prefsSyncTimer.current);
      prefsSyncTimer.current = window.setTimeout(() => { api.savePreferences(p as unknown as Record<string, unknown>).catch(() => { /* local copy still stands */ }); }, 800);
    }
  };
  const palette: ThreadColor[] = prefs.threadLibrary.length > 0 ? prefs.threadLibrary : (catalog?.threadPalette ?? []);
  const matchToThreadLibrary = prefs.matchToThreadLibrary;

  useEffect(() => {
    api.catalog().then(setCatalog).catch((e) => setError(`Couldn't reach the PiperStitch server: ${e.message}`));
    capturePromoFromURL();
    const params = new URLSearchParams(window.location.search);
    const subscribed = params.get("subscribed");
    if (subscribed !== null) window.history.replaceState(null, "", window.location.pathname);
    // Arriving from PiperStitch Proofs already signed in: ?handoff=<code>
    // becomes this app's session, no email code needed. Other parameters
    // (?project=, ?return=) stay for their own handlers.
    // ?setup=1 opens guided setup directly (a link from the welcome email
    // or the marketing site, and how support tells someone to re-run it).
    if (params.get("setup") !== null) {
      params.delete("setup");
      window.history.replaceState(null, "", window.location.pathname + (params.toString() ? `?${params}` : ""));
      setRerunOnboarding("link");
    }
    // ?trial=1 (every "Start free trial" button on the site): guided setup
    // opens at once, creating the account as its first step if needed.
    if (params.get("trial") !== null) {
      const linkEmail = params.get("email")?.trim() ?? "", linkCode = params.get("code")?.trim() ?? "";
      params.delete("trial"); params.delete("email"); params.delete("code");
      window.history.replaceState(null, "", window.location.pathname + (params.toString() ? `?${params}` : ""));
      if (linkEmail && linkCode) setSignUpLink({ email: linkEmail, code: linkCode });
      setSignUpMode(true);
      setRerunOnboarding("link");
    }
    const handoff = params.get("handoff");
    if (handoff) {
      params.delete("handoff");
      window.history.replaceState(null, "", window.location.pathname + (params.toString() ? `?${params}` : ""));
    }
    const load = handoff ? api.redeemHandoff(handoff).catch(() => api.me(true)) : api.me(subscribed !== null);
    load.then((m) => {
      setMe(m);
      if (m.signedIn) pullPreferences();
      if (subscribed === "1" && m.account?.status === "active") setNotice("You're subscribed — thank you! Everything's unlocked.");
    }).catch((e) => setError(`Couldn't reach the PiperStitch server: ${e.message}`));
  }, []);

  const signedInAndEntitled = !!me && (!me.authEnabled || (me.signedIn && !!me.account?.entitled));
  useEffect(() => {
    if (signedInAndEntitled && me?.authEnabled && phase === "start") api.listProjects().then(setProjects).catch(() => setProjects([]));
  }, [signedInAndEntitled, me?.authEnabled, phase]);

  /** The account's mirrored preferences win over this browser's copy when
   *  they're newer than the last local save, so a hoop or thread added on
   *  another machine shows up here; a browser that has never synced pushes
   *  its own copy up instead. */
  const pullPreferences = async () => {
    try {
      const { preferences, updatedAt } = await api.getPreferences();
      const localStamp = Number(localStorage.getItem("piperstitch.preferences.savedAt") || 0);
      if (preferences && updatedAt && (!localStamp || Date.parse(updatedAt) > localStamp)) {
        const merged = withDefaults({ ...loadPrefs(), ...(preferences as Partial<Preferences>) });
        setPrefsState(merged); savePrefs(merged);
      } else {
        api.savePreferences(loadPrefs() as unknown as Record<string, unknown>).catch(() => { /* best effort */ });
      }
    } catch { /* offline or auth off: local preferences are fine */ }
    setPrefsPulled(true);
  };
  const refreshMe = async () => { try { setMe(await api.me(true)); } catch (e) { fail(e); } };
  const onSignedIn = (account: AccountState, mode: "trial" | "signin" = "signin") => {
    setMe({ authEnabled: true, signedIn: true, account }); setNotice(null); pullPreferences();
    if (mode === "trial") setRerunOnboarding("link");
  };
  /** Account creation from inside guided setup: signed in and preferences
   *  pulled before this resolves, so the flow can re-seed from them. */
  const signUp = {
    requestCode: async (email: string) => { await api.requestCode(email, "trial"); },
    verifyCode: async (email: string, code: string) => {
      const m = await api.verifyCode(email, code);
      if (!m.account) throw new Error("Couldn't sign in.");
      setMe({ authEnabled: true, signedIn: true, account: m.account }); setNotice(null);
      await pullPreferences();
    },
  };
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
        hoop: defaultHoop, hoopMode: defaultHoop ? "specific" : "none", fabric: prefs.defaultFabric, colorPreset: preset, threadWeight: "wt40" });
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

  // 40wt is the standard weight most digitizing (including this app's own
  // default density) already assumes; 60wt is meaningfully thinner and
  // conventionally sewn a bit denser for full coverage -- see SetupFlow's
  // own note on the choice. Still well within the normal 0.2-1.0mm range,
  // no "push past normal limits" override needed.

  const onSetupFinish = async (a: SetupAnswers) => {
    if (!imported) return;
    setError(null); setBusy("Creating embroidery…");
    try {
      const imp = await reimportIfNeeded(imported, a.colorPreset, a.hoop);
      setImported(imp); setAnswers(a);
      let doc = await buildFrom(imp, a);
      // Cap frames register on the centre mark (C4).
      if (a.placement && a.placement !== "custom" && /cap|hat/i.test(a.placement.name)) doc = { ...doc, startAndEndAtCenter: true };
      // Towels and fleece: a laydown first, unless the customer unticked it (C1).
      if (a.fabric === "terry" ? a.laydown !== false : !!a.laydown) doc = { ...doc, laydown: defaultLaydown(palette) };
      // Thread weight is an engine parameter (C3): spacing is offset at generation time, the numbers stay 40 wt numbers.
      if (a.threadWeight !== "wt40") doc = { ...doc, objects: doc.objects.map((o) => ({ ...o, parameters: { ...o.parameters, threadWeight: a.threadWeight } })) };
      setGlobalSatin(0.32); setGlobalFill(0.32);
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
  /** C5: stitch count is ~proportional to 1/spacing, so scale every satin/fill spacing by current/target (clamped 0.2-1.0 mm). */
  const onTargetStitchCount = (target: number) => {
    if (!document || !digitized || target <= 0 || digitized.stats.stitchCount <= 0) return;
    const scale = digitized.stats.stitchCount / target;
    const clamp = (v: number) => Math.min(1.0, Math.max(0.2, v));
    commit({ ...document, objects: document.objects.map((o) => o.stitchType === "satin" ? { ...o, parameters: { ...o.parameters, satinDensityMM: clamp(o.parameters.satinDensityMM * scale) } }
      : o.stitchType === "tatamiFill" ? { ...o, parameters: { ...o.parameters, fillSpacingMM: clamp(o.parameters.fillSpacingMM * scale) } } : o) },
      { status: `Aiming for about ${target.toLocaleString()} stitches.` });
  };
  const onAddOutlines = () => withBusy("Adding outlines…", async () => { if (!document) return; applyEdit(await api.outlines(document)); });
  const onAddBorder = (threadColor: ThreadColor, widthMM: number) => withBusy("Adding border…", async () => { if (!document) return; applyEdit(await api.border(document, threadColor, widthMM)); });
  const onThreadWeight = (threadWeight: ThreadWeight) => {
    if (!document) return;
    if (answers) setAnswers({ ...answers, threadWeight });
    commit({ ...document, objects: document.objects.map((o) => ({ ...o, parameters: { ...o.parameters, threadWeight } })) }, { status: `Thread: ${THREAD_WEIGHTS.find((w) => w.id === threadWeight)?.title ?? threadWeight}.` });
  };
  const onLaydown = (laydown: LaydownSettings | null) => { if (!document) return; commit({ ...document, laydown }, { status: laydown ? "A laydown will be sewn first to flatten the nap." : "No laydown." }); };
  const onStartAtCenter = (on: boolean) => { if (!document) return; commit({ ...document, startAndEndAtCenter: on }, { status: on ? "The file will start and end at the hoop centre." : "The file starts at its first stitch." }); };
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

  /** Opens the "Open a saved project" sheet from anywhere (not just the
   *  start screen) -- refetches first, since the list the start screen
   *  loaded could be stale or, if this session arrived via a saved
   *  project link or the setup flow, never loaded at all. */
  const onOpenProjectsSheet = () => {
    setSheet("open");
    api.listProjects().then(setProjects).catch(() => setProjects([]));
  };

  const onOpenProject = (summary: ProjectSummary) => withBusy("Opening project…", async () => {
    if (!catalog) return;
    const project = await api.getProject(summary.id);
    const doc = project.document;
    const fabric = (doc.objects[0]?.parameters.fabricType ?? "standard") as FabricType;
    const hoop = catalog.hoops.find((h) => h.name === prefs.defaultHoopName) ?? null;
    setImported(null); setProjectId(project.id); setSavedAt(Date.now()); setUndoStack([]); setSelectedIDs(new Set());
    setAnswers({ placement: "custom", widthMM: doc.physicalWidthMM, heightMM: doc.physicalHeightMM, lockAspect: false, hoop, hoopMode: hoop ? "specific" : "none", fabric, colorPreset: prefs.defaultColorPreset, threadWeight: (doc.objects[0]?.parameters.threadWeight ?? "wt40") as ThreadWeight });
    setDocument(doc); setDigitized(null); setPhase("editor"); setStatus(`Opened ${project.name}.`);
    await digitizeNow(doc, hoop);
  });
  /** `?project=<id>` opens a saved project straight from a link (PiperStitch
   *  Proofs sends the embroiderer here to adjust a digitized design before
   *  the proof goes out). Waits for the catalog and a signed-in, entitled
   *  session, then strips the parameter so a reload doesn't reopen it. */
  useEffect(() => {
    if (!catalog || !signedInAndEntitled || phase !== "start") return;
    const params = new URLSearchParams(window.location.search);
    const id = params.get("project");
    if (!id) return;
    params.delete("project");
    window.history.replaceState(null, "", window.location.pathname + (params.toString() ? `?${params}` : ""));
    onOpenProject({ id, name: "", widthMM: 0, heightMM: 0, objectCount: 0, createdAt: "", updatedAt: "" });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [catalog, signedInAndEntitled, phase]);

  /** `?return=<url>` (sent along with `?project=`) puts a "Back to Proofs"
   *  button in the top bar for the rest of this tab's session. Only a
   *  PiperStitch address (or a local dev server) is accepted. */
  const [returnTo, setReturnTo] = useState<string | null>(() => { try { return sessionStorage.getItem("piperstitch.returnTo"); } catch { return null; } });
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const raw = params.get("return");
    if (!raw) return;
    params.delete("return");
    window.history.replaceState(null, "", window.location.pathname + (params.toString() ? `?${params}` : ""));
    try {
      const u = new URL(raw);
      const host = u.hostname;
      const ok = (u.protocol === "https:" || u.protocol === "http:") && (host === "piperstitch.com" || host.endsWith(".piperstitch.com") || host === "localhost" || host === "127.0.0.1");
      if (ok) { setReturnTo(u.toString()); try { sessionStorage.setItem("piperstitch.returnTo", u.toString()); } catch { /* fine */ } }
    } catch { /* not a URL */ }
  }, []);
  const onSaveProject = () => withBusy("Saving…", async () => {
    if (!document) return;
    const id = projectId ?? crypto.randomUUID();
    await api.saveProject(id, document.name, document);
    setProjectId(id); setSavedAt(Date.now()); setStatus("Saved to your account.");
  });
  /** "Send to Proofs": save the project (Proofs builds the proof from the
   *  saved copy), then hand the signed-in session over to Proofs' new-job
   *  form with this project preselected. */
  const onSendToProofs = () => withBusy("Opening Proofs…", async () => {
    if (!document) return;
    const id = projectId ?? crypto.randomUUID();
    await api.saveProject(id, document.name, document);
    setProjectId(id); setSavedAt(Date.now());
    const next = `/proofs/new?project=${encodeURIComponent(id)}&name=${encodeURIComponent(document.name)}`;
    window.location.assign(await api.proofsHandoffURL(next));
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
  const onOpenFeedback = async () => {
    if (!document || !digitized) return;
    const digitizedPNG = renderDigitizedPNGDataURL(document, digitized);
    let originalPNG: string | null = null;
    if (imported?.decoded?.previewURL) originalPNG = await blobURLToPNGDataURL(imported.decoded.previewURL);
    else if (imported?.svgText) originalPNG = await renderSVGPNGDataURL(imported.svgText);
    setFeedbackImages({ original: originalPNG, digitized: digitizedPNG });
    setSheet("feedback");
  };
  const onSendFeedback = async (note: string) => {
    if (!feedbackImages || !document) return;
    const dig = dataURLToBase64(feedbackImages.digitized);
    const orig = feedbackImages.original ? dataURLToBase64(feedbackImages.original) : null;
    await api.sendFeedback({
      note, designName: document.name, stitchCount: digitized?.stats.stitchCount ?? 0,
      digitizedImageBase64: dig.base64, digitizedImageType: dig.type,
      originalImageBase64: orig?.base64, originalImageType: orig?.type,
    });
  };
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
  if (me.authEnabled && !me.signedIn && signUpMode) {
    return (
      <>
        {error && <div className="error-bar floating">{error}</div>}
        <Onboarding account={null} catalog={catalog} prefs={prefs} onPrefs={setPrefs} signUp={signUp} signUpLink={signUpLink}
          onSignInInstead={() => { setSignUpMode(false); setRerunOnboarding(false); }}
          onCancel={() => { setSignUpMode(false); setRerunOnboarding(false); }}
          onSkip={() => { setSignUpMode(false); setRerunOnboarding(false); setFirstRunActive(false); }}
          onDone={() => { setSignUpMode(false); setRerunOnboarding(false); setFirstRunActive(false); }} />
      </>
    );
  }
  if (me.authEnabled && !me.signedIn) return <SignIn onSignedIn={onSignedIn} proofsURL={me.proofsURL} onStartTrial={() => { setSignUpMode(true); setRerunOnboarding("link"); }} />;
  if (me.authEnabled && me.account && !me.account.entitled) return <SubscribeWall account={me.account} onSignOut={onSignOut} onRefresh={refreshMe} />;

  const proofs = me.account?.proofs ?? null;
  const showProofs = !!proofs && (proofs.subscribed || proofs.free_used > 0);
  // Anyone with a Proofs subscription or free proofs left can send a design across.
  const canSendToProofs = me.authEnabled && !!proofs && (proofs.subscribed || proofs.free_left > 0);
  const goProofs = () => api.proofsHandoffURL().then((url) => window.location.assign(url)).catch((e) => fail(e));
  const accountMenu = (
    <>
      {returnTo && <a className="btn primary return-to" href={returnTo} title="Save here first; the proof is built from the saved project">← Back to Proofs</a>}
      {!returnTo && showProofs && <button className="btn primary proofs-btn" onClick={goProofs} title="Open PiperStitch Proofs — already signed in">Proofs ↗</button>}
      {me.authEnabled && me.account ? <AccountMenu account={me.account} onSignOut={onSignOut} /> : null}
    </>
  );
  const sheets = (
    <>
      {sheet === "help" && <HelpSheet onClose={() => setSheet(null)} showProofs={!!me.account?.proofs} />}
      {(sheet === "settings" || sheet === "settingsBusiness") && <SettingsSheet catalog={catalog} prefs={prefs} account={me.account ?? null} onPrefs={setPrefs} onClose={() => setSheet(null)} onSignOut={onSignOut} onRefreshAccount={refreshMe} onAccount={(a) => setMe({ ...me, account: a })} initialTab={sheet === "settingsBusiness" ? "business" : undefined}
        onRunSetup={me.authEnabled && phase === "start" ? () => { setSheet(null); setRerunOnboarding("settings"); } : undefined} />}
      {sheet === "send" && document && <SendSheet designName={document.name} onClose={() => setSheet(null)} onSend={async (format, toEmail, message) => { await api.sendFile(document, format, toEmail, message); setStatus(`Sent ${document.name}.${format} to ${toEmail}.`); }} />}
      {sheet === "open" && <OpenProjectsSheet projects={projects} busy={busy} onOpen={onOpenProject} onDelete={onDeleteProject} onClose={() => setSheet(null)} />}
      {sheet === "threadLibrary" && (
        <ThreadLibrarySheet library={prefs.threadLibrary} onChange={(lib) => setPrefs({ ...prefs, threadLibrary: lib })}
          suppliers={prefs.threadSuppliers} onSuppliersChange={(ids) => setPrefs({ ...prefs, threadSuppliers: ids })} onClose={() => setSheet(null)} />
      )}
      {sheet === "lettering" && document && <LetteringSheet palette={palette} selectedCount={selectedIDs.size} onClose={() => setSheet(null)} onAdd={onAddLettering} />}
      {sheet === "mergeColors" && document && <MergeColorsSheet objects={document.objects} palette={palette} onClose={() => setSheet(null)} onMerge={onMergeColors} />}
      {sheet === "feedback" && feedbackImages && document && (
        <FeedbackSheet originalImage={feedbackImages.original} digitizedImage={feedbackImages.digitized} designName={document.name}
          stitchCount={digitized?.stats.stitchCount ?? 0} onClose={() => { setSheet(null); setFeedbackImages(null); }} onSend={onSendFeedback} />
      )}
      {pendingPaint && (
        <Modal title="Extend this object?" onClose={() => setPendingPaint(null)}>
          <p>Your stroke touches <b>{pendingPaint.targetName}</b>. Add the painted area to it, or keep it as a separate shape in the same colour?</p>
          <div className="modal-foot"><button className="btn ghost" onClick={() => setPendingPaint(null)}>Cancel</button><button className="btn" onClick={() => resolvePaint("separate")}>Keep separate</button><button className="btn primary" onClick={() => resolvePaint("extend")}>Extend {pendingPaint.targetName}</button></div>
        </Modal>
      )}
    </>
  );

  const needsOnboarding = me.authEnabled && !!me.account && prefsPulled && prefs.onboarding === null && phase === "start" && !returnTo;
  if (needsOnboarding && !firstRunActive) setFirstRunActive(true);
  if (rerunOnboarding || firstRunActive) {
    // The account's own preferences (an existing member's business, hoops,
    // threads) must be in before the flow snapshots them as its draft --
    // unless the flow itself just created the account (signUpMode), in
    // which case it re-seeds after the code and must not be remounted.
    if (me.authEnabled && me.signedIn && !prefsPulled && !signUpMode) {
      return <div className="start"><div className="start-brand"><img src="/icon.png" alt="" width={64} height={64} /><h1>PiperStitch</h1><p>One moment…</p></div></div>;
    }
    const leave = () => { setRerunOnboarding(false); setFirstRunActive(false); setSignUpMode(false); setSheet(null); };
    return (
      <>
        {error && <div className="error-bar floating">{error}</div>}
        <Onboarding account={me.account ?? null} catalog={catalog} prefs={prefs} onPrefs={setPrefs} rerun={rerunOnboarding === "settings"}
          signUp={signUpMode ? signUp : undefined} signUpLink={signUpLink} onSignInInstead={() => { setSignUpMode(false); setRerunOnboarding(false); }}
          onCancel={leave} onSkip={leave} onDone={leave} />
      </>
    );
  }

  if (phase === "setup" && imported && answers) {
    return <><SetupFlow catalog={catalog} ownedHoopNames={prefs.ownedHoopNames} onEditHoops={() => setSheet("settingsBusiness")} fileName={imported.fileName} isVector={imported.isVector} recommendedWidthMM={imported.response.recommendedWidthMM}
      recommendedHeightMM={imported.response.recommendedHeightMM} aspectRatio={imported.response.aspectRatio} initial={answers} busy={busy}
      matchToThreadLibrary={matchToThreadLibrary} onMatchToThreadLibraryChange={(on) => setPrefs({ ...prefs, matchToThreadLibrary: on })}
      onFinish={onSetupFinish} onCancel={onStartOver} />{sheets}</>;
  }

  if (phase === "editor" && document && answers) {
    return (
      <>
        <Editor catalog={catalog} document={document} digitized={digitized} stale={stale} busy={busy} error={error} status={status}
          prefs={prefs} palette={palette} selectedIDs={selectedIDs} tool={tool} canUndo={undoStack.length > 0}
          hoop={answers.hoop} fabric={answers.fabric} colorPreset={answers.colorPreset} isVector={imported?.isVector ?? true} hasSource={!!imported}
          matchToThreadLibrary={matchToThreadLibrary} globalSatinDensityMM={globalSatin} globalFillSpacingMM={globalFill}
          previewURL={imported?.decoded?.previewURL ?? null} accountMenu={accountMenu} canSave={me.authEnabled} savedAt={savedAt}
          canSendToProofs={canSendToProofs && !returnTo} onSendToProofs={onSendToProofs}
          onTool={setTool} onPrefs={setPrefs} onSelect={onSelect} onTranslate={onTranslate} onScale={onScale} onStroke={onStroke}
          onObject={onObject} onDeleteSelected={onDeleteSelected} onMergeShapes={onMergeShapes} onResize={onResize} onHoop={onHoop} onFabric={onFabric}
          onColorPreset={onColorPreset} onMatchLibrary={onMatchLibrary} onExtendedDensity={(on) => setPrefs({ ...prefs, allowExtendedDensity: on })}
          onGlobalSatinDensity={onGlobalSatin} onGlobalFillSpacing={onGlobalFill} onTargetStitchCount={onTargetStitchCount} onStartAtCenter={onStartAtCenter} onLaydown={onLaydown} onThreadWeight={onThreadWeight} onAddOutlines={onAddOutlines} onAddBorder={onAddBorder} onUndo={onUndo} onNew={onNew} onRedo={onRedo} onSave={onSaveProject}
          onExport={onExport} onOpenSheet={setSheet} onSendFeedback={onOpenFeedback} onOpenProjects={onOpenProjectsSheet} />
        {sheets}
      </>
    );
  }

  return (
    <>
      {error && <div className="error-bar floating">{error}</div>}
      {notice && <div className="notice-bar floating" onClick={() => setNotice(null)}>{notice}</div>}
      <div className="start-account">{accountMenu}<button className="btn ghost" onClick={() => setSheet("settings")}>⚙ Settings</button><button className="btn ghost" onClick={() => setSheet("help")}>? Help</button></div>
      <DropZone onFile={onFile} busy={busy} projects={me.authEnabled ? projects : null} onOpenProject={onOpenProject} onDeleteProject={onDeleteProject}
        showTips={!!prefs.onboarding?.skippedAt && !prefs.startTipsDismissed} onDismissTips={() => setPrefs({ ...prefs, startTipsDismissed: true })} onOpenHelp={() => setSheet("help")} />
      {sheets}
    </>
  );
}
