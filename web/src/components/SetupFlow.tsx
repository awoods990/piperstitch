// The after-import questions, mirroring the Mac app's ImportSetupSheet:
// five steps of tappable choices, each answer nudging the next. The
// stitch preview is withheld until the last step so the first thing the
// user sees comes from their own answers, not unconfirmed defaults.

import { useEffect, useMemo, useRef, useState } from "react";
import { THREAD_WEIGHTS, type ThreadWeight } from "../types";
import type { Catalog, CatalogFabric, CatalogSize, ColorPresetId, FabricType, TextDecision, TextLine } from "../types";
import { approx, len, size, displayUnitLabel, toDisplay, fromDisplay } from "../format";
import { hoopGroups, smallestHoopThatFits } from "../hoops";
import { LETTERING_FONTS, THIN_STROKE_MIN_CAP_MM, ensureFontFaces, fontFaceFamily, suggestFont } from "../lettering";
import { cropLine, readLine } from "../ocr";
import type { DecodedImage } from "../decode";
import { minimumCapHeightMM, textLineScale } from "../textLines";


export interface SetupAnswers {
  placement: CatalogSize | "custom" | null;
  widthMM: number;
  heightMM: number;
  lockAspect: boolean;
  hoop: CatalogSize | null;
  hoopMode: "specific" | "recommend" | "none";
  fabric: FabricType;
  colorPreset: ColorPresetId;
  threadWeight: ThreadWeight;
  /** Sew a laydown first to flatten the nap (offered for terry). */
  laydown?: boolean;
  /** One per detected text line, in order; absent when the artwork has none. */
  textDecisions?: TextDecision[];
}

interface Props {
  catalog: Catalog;
  /** From guided setup: the only hoops shown until "See all", and preferred by "Choose one for me". */
  ownedHoopNames?: string[];
  onEditHoops?: () => void;
  fileName: string;
  isVector: boolean;
  recommendedWidthMM: number;
  recommendedHeightMM: number;
  aspectRatio: number;
  initial: SetupAnswers;
  busy: string | null;
  /** Text lines the importer found, with the image and its shape bounds to crop them from. */
  textLines?: TextLine[];
  image?: DecodedImage | null;
  sourceBounds?: { minX: number; minY: number; maxX: number; maxY: number };
  matchToThreadLibrary: boolean;
  onMatchToThreadLibraryChange: (on: boolean) => void;
  onFinish: (answers: SetupAnswers) => void;
  onCancel: () => void;
}

const ALL_STEPS = ["placement", "size", "text", "hoop", "fabric", "colors"] as const;
type Step = (typeof ALL_STEPS)[number];

const TITLES: Record<Step, string> = {
  placement: "Where is this going?",
  size: "How big should it be?",
  text: "There's text in this artwork",
  hoop: "Which hoop will you use?",
  fabric: "What will it be sewn on?",
  colors: "How many thread colours?",
};

const FABRIC_HINTS: Record<FabricType, string> = {
  standard: "not sure — a safe middle",
  stableWoven: "twill, canvas, denim",
  knit: "t-shirt, polo",
  stretchKnit: "athletic, spandex blend",
  terry: "towel, fleece",
  leatherOrVinyl: "firm, no stretch",
  structuredCap: "stiff buckram front",
  unstructuredCap: "soft dad hat, bucket hat",
  beanie: "stretchy knit hat",
};

export const PRESET_LABELS: Record<ColorPresetId, [string, string]> = {
  preserveArtwork: ["Keep every colour", "most faithful, most thread changes"],
  normalEmbroidery: ["Normal embroidery", "a good balance for most designs"],
  productionEfficient: ["Production efficient", "fewer changes, faster sew-out"],
  minimalColors: ["As few as possible", "simplest possible, quickest to sew"],
};

/** The fabric a placement most often means, so the fabric step arrives
 *  pre-answered: caps are structured, a polo/chest/sleeve is a knit, a full
 *  back is usually a jacket. The user can still change it. */
export function predictedFabric(preset: CatalogSize): FabricType | null {
  const n = preset.name.toLowerCase();
  if (n.includes("cap") || n.includes("hat")) return "structuredCap";
  if (n.includes("polo") || n.includes("chest") || n.includes("sleeve")) return "knit";
  if (n.includes("back")) return "stableWoven";
  return null;
}

export default function SetupFlow(props: Props) {
  const owned = props.ownedHoopNames ?? [];
  const { catalog, recommendedWidthMM, recommendedHeightMM, aspectRatio, isVector, busy } = props;
  const [step, setStep] = useState<Step>("placement");
  const [a, setA] = useState<SetupAnswers>(props.initial);
  // Steps the user has answered by hand. An earlier answer pre-fills a
  // later step (placement -> fabric, size -> hoop) only until the user
  // has chosen that later step themselves; after that their choice sticks.
  const [chosen, setChosen] = useState<{ hoop: boolean; fabric: boolean }>({ hoop: false, fabric: false });
  // The hoop step shows the standard sizes; the branded lines (Mighty
  // Hoop, Durkee EZ Frame) sit behind "More" -- opened up front if the
  // current hoop is already one of them, so it's never hidden.
  const [moreHoops, setMoreHoops] = useState(() => !!props.initial.hoop && /^(Mighty Hoop|Durkee)/.test(props.initial.hoop.name));
  const textLines = props.textLines ?? [];
  // The Text step exists only when the importer found text.
  const STEPS = useMemo(() => ALL_STEPS.filter((s) => s !== "text" || textLines.length > 0), [textLines.length]);
  const stepIndex = STEPS.indexOf(step);
  // Letter heights at the chosen size, and the size at which the smallest
  // line would sew as traced.
  const scale = props.sourceBounds ? textLineScale(props.sourceBounds, a.widthMM, a.heightMM) : 0;
  const minCap = minimumCapHeightMM(a.threadWeight);
  const capMM = (line: TextLine) => line.capHeightPixels * scale;
  const smallLines = textLines.filter((l) => capMM(l) < minCap);
  const widthForAllText = useMemo(() => {
    if (!smallLines.length || !props.sourceBounds) return null;
    const smallestCapPx = Math.min(...smallLines.map((l) => l.capHeightPixels));
    // scale needed = minCap / capPx; width = scale * bounds.width (aspect kept)
    const b = props.sourceBounds;
    return Math.ceil((minCap / smallestCapPx) * (b.maxX - b.minX));
  }, [smallLines, props.sourceBounds, minCap]);
  // The decision for each line: what the user chose, else the default for
  // the CURRENT size -- keep a line that sews as traced, leave out one that
  // doesn't. A kept line that the size has since made too small is left
  // out (keeping it is not an option any more).
  const defaultDecision = (l: TextLine): TextDecision => ({ action: "drop", text: "", fontID: suggestFont(l) });
  const decisions: TextDecision[] = textLines.map((l, i) => {
    const d = a.textDecisions?.[i] ?? defaultDecision(l);
    const tooSmall = capMM(l) < minCap;
    if (!a.textDecisions?.[i] && !tooSmall) return { ...d, action: "keep" };
    if (d.action === "keep" && tooSmall) return { ...d, action: "drop" };
    return d;
  });
  const setDecision = (i: number, patch: Partial<TextDecision>) => {
    const next = decisions.map((d, k) => (k === i ? { ...d, ...patch } : d));
    setA({ ...a, textDecisions: next });
  };
  const setFontForAll = (fontID: string) => setA({ ...a, textDecisions: decisions.map((d) => ({ ...d, fontID })) });
  useEffect(() => { if (textLines.length) ensureFontFaces().catch(() => { /* tiles fall back to the system font */ }); }, [textLines.length]);

  const isCap = a.placement && a.placement !== "custom" && /cap|hat/i.test(a.placement.name);

  /** The hoop answer that follows from a size: the smallest hoop that fits,
   *  unless the current one already does (a default from preferences, say). */
  const withPredictedHoop = (next: SetupAnswers): SetupAnswers => {
    if (chosen.hoop) return next;
    const fits = (h: CatalogSize | null) => !!h && h.widthMM >= next.widthMM && h.heightMM >= next.heightMM;
    // A cap front goes in a cap frame, whatever the preferred everyday hoop
    // is -- it's a different piece of hardware, not just a different size.
    const capPlacement = next.placement && next.placement !== "custom" && /cap|hat/i.test(next.placement.name);
    const capHoop = capPlacement ? catalog.hoops.find((h) => /cap|hat/i.test(h.name) && fits(h)) ?? null : null;
    if (capHoop) return { ...next, hoopMode: "specific", hoop: capHoop };
    if (next.hoopMode === "specific" && fits(next.hoop)) return next;
    const smallest = smallestHoopThatFits(catalog.hoops, next.widthMM, next.heightMM, owned);
    return smallest ? { ...next, hoopMode: "specific", hoop: smallest } : { ...next, hoopMode: "none", hoop: null };
  };

  const setSize = (w: number, h?: number) => {
    const width = Math.max(1, w);
    const height = h ?? (a.lockAspect && aspectRatio > 0 ? width / aspectRatio : a.heightMM);
    setA(withPredictedHoop({ ...a, widthMM: width, heightMM: Math.max(1, height) }));
  };

  const subtitle = useMemo(() => {
    switch (step) {
      case "placement":
        return "Pick the spot on the garment and I'll start from the size that's standard there.";
      case "text":
        return smallLines.length
          ? `${smallLines.length === textLines.length ? (textLines.length === 1 ? "It" : "All of it") : `${smallLines.length} of ${textLines.length} lines`} would sew smaller than ${len(minCap)} ${displayUnitLabel()} tall at ${size(a.widthMM, a.heightMM)} — too small for lettering to read. Type the words and I'll set them in a real font at a size that sews, or leave them out.`
          : "Every line is tall enough to sew as traced. Re-type any of them for cleaner lettering, or carry on.";
      case "size":
        if (a.placement && a.placement !== "custom") {
          const p = a.placement;
          return `Standard for ${p.name.toLowerCase()} is ${size(p.widthMM, p.heightMM)}. Adjust if you like — the finest detail in your artwork looks good down to about ${len(recommendedWidthMM)} ${displayUnitLabel()} wide.`;
        }
        return `Based on the finest detail in your artwork, I'd suggest about ${size(recommendedWidthMM, recommendedHeightMM)}. Type any size you want.`;
      case "hoop":
        if (!chosen.hoop && a.hoopMode === "specific" && a.hoop)
          return isCap && /cap|hat/i.test(a.hoop.name)
            ? `I've picked the ${a.hoop.name} since this is going on a cap. Cap frames vary by machine — change it if yours is a different size.`
            : `I've picked ${a.hoop.name} — it fits ${size(a.widthMM, a.heightMM)}. Change it if your machine uses a different one.`;
        return isCap
          ? "Cap frames vary by machine — pick the closest size, or let me choose one that fits."
          : "I'll warn you if the design won't fit. Not sure? Let me pick the smallest one that does.";
      case "fabric": {
        const predicted = !chosen.fabric && a.placement && a.placement !== "custom" ? predictedFabric(a.placement) : null;
        if (isCap)
          return "For a cap front I've started with a structured cap. A stiff buckram front barely pulls; a soft cap or a knit beanie pulls a lot more, so I compensate differently for each.";
        if (predicted && a.placement && a.placement !== "custom")
          return `For ${a.placement.name.toLowerCase()} I've started with ${catalog.fabrics.find((f) => f.id === predicted)?.shortName.toLowerCase() ?? predicted}. Stretchier material pulls more as it sews, so change it if that's not what you're using.`;
        return "Stretchier material pulls more as it sews, so I widen the shapes more to keep the finished size true.";
      }
      case "colors":
        return "Fewer colours means fewer thread changes and a faster sew-out. Vector artwork always keeps its own colours.";
    }
  }, [step, a.placement, a.hoopMode, a.hoop, a.widthMM, a.heightMM, chosen, isCap, catalog.fabrics, recommendedWidthMM, recommendedHeightMM]);

  const fabricGroups = useMemo(() => {
    const byId = (ids: FabricType[]) => ids.map((id) => catalog.fabrics.find((f) => f.id === id)).filter(Boolean) as CatalogFabric[];
    const headwear: [string, CatalogFabric[]] = ["Hats & caps", catalog.fabrics.filter((f) => f.isHeadwear)];
    const garments: [string, CatalogFabric[]] = ["Garments", byId(["standard", "stableWoven", "knit", "stretchKnit"])];
    const other: [string, CatalogFabric[]] = ["Other", byId(["terry", "leatherOrVinyl"])];
    return isCap ? [headwear, garments, other] : [garments, headwear, other];
  }, [catalog.fabrics, isCap]);

  const placementName = a.placement === "custom" ? "Custom size" : a.placement?.name ?? "—";
  const hoopName = a.hoopMode === "none" ? "no hoop" : a.hoopMode === "recommend"
    ? (smallestHoopThatFits(catalog.hoops, a.widthMM, a.heightMM, owned)?.name ?? "no hoop fits") + " (chosen for you)"
    : a.hoop?.name ?? "no hoop";
  const fabricName = catalog.fabrics.find((f) => f.id === a.fabric)?.displayName ?? a.fabric;

  const finish = () => {
    const hoop = a.hoopMode === "none" ? null : a.hoopMode === "recommend"
      ? smallestHoopThatFits(catalog.hoops, a.widthMM, a.heightMM, owned) : a.hoop;
    props.onFinish({ ...a, hoop, textDecisions: textLines.length ? decisions : undefined });
  };

  return (
    <div className="setup">
      <div className="setup-card">
        <header className="setup-head">
          <div>
            <div className="setup-kicker">Let's set up this design</div>
            <div className="setup-file">{props.fileName}</div>
          </div>
          <div className="setup-dots" aria-hidden>
            {STEPS.map((s, i) => <span key={s} className={"dot" + (i <= stepIndex ? " on" : "") + (s === step ? " cur" : "")} />)}
          </div>
        </header>

        <h2>{TITLES[step]}</h2>
        <p className="setup-sub">{subtitle}</p>

        <div className="setup-body">
          {step === "placement" && (
            <div className="choices">
              {catalog.garmentPresets.map((p) => (
                <Choice key={p.name} title={p.name} subtitle={`${size(p.widthMM, p.heightMM)}`}
                  selected={a.placement !== "custom" && a.placement?.name === p.name}
                  onClick={() => {
                    const predicted = chosen.fabric ? null : predictedFabric(p);
                    setA(withPredictedHoop({ ...a, placement: p, widthMM: p.widthMM, heightMM: p.heightMM, fabric: predicted ?? a.fabric }));
                  }} />
              ))}
              <Choice title="Something else" subtitle="I'll set the size myself" selected={a.placement === "custom"}
                onClick={() => setA({ ...a, placement: "custom" })} />
            </div>
          )}

          {step === "size" && (
            <div className="stack">
              <div className="choices two">
                {a.placement && a.placement !== "custom" && (
                  <Choice title={`Standard ${a.placement.name.toLowerCase()}`} subtitle={`${size(a.placement.widthMM, a.placement.heightMM)}`}
                    selected={approx(a.widthMM, a.placement.widthMM) && approx(a.heightMM, a.placement.heightMM)}
                    onClick={() => setSize(a.placement !== "custom" && a.placement ? a.placement.widthMM : a.widthMM, a.placement !== "custom" && a.placement ? a.placement.heightMM : undefined)} />
                )}
                <Choice title="Recommended for this artwork" subtitle={`${size(recommendedWidthMM, recommendedHeightMM)}`}
                  selected={approx(a.widthMM, recommendedWidthMM) && approx(a.heightMM, recommendedHeightMM)}
                  onClick={() => setSize(recommendedWidthMM, recommendedHeightMM)} />
              </div>
              <div className="size-row">
                <label>Width <input type="number" step={displayUnitLabel() === "in" ? "0.05" : "0.1"} min="0.2" value={toDisplay(a.widthMM)}
                  onChange={(e) => setSize(fromDisplay(Number(e.target.value)))} /></label>
                <span className="x">×</span>
                <label>Height <input type="number" step={displayUnitLabel() === "in" ? "0.05" : "0.1"} min="0.2" value={toDisplay(a.heightMM)}
                  onChange={(e) => setA(withPredictedHoop({ ...a, heightMM: Math.max(1, fromDisplay(Number(e.target.value))), lockAspect: false }))} /></label>
                <span className="unit">{displayUnitLabel()}</span>
                <label className="check"><input type="checkbox" checked={a.lockAspect}
                  onChange={(e) => {
                    const lock = e.target.checked;
                    setA({ ...a, lockAspect: lock, heightMM: lock && aspectRatio > 0 ? a.widthMM / aspectRatio : a.heightMM });
                  }} /> Keep proportions</label>
              </div>
            </div>
          )}

          {step === "text" && (
            <div className="stack">
              {widthForAllText && widthForAllText > a.widthMM && (
                <div className="text-enlarge">
                  Or make the whole design <b>{len(widthForAllText)} {displayUnitLabel()}</b> wide and every line sews as traced.
                  <button className="btn small" type="button" onClick={() => setSize(widthForAllText)}>Use {len(widthForAllText)} {displayUnitLabel()}</button>
                </div>
              )}
              {textLines.map((line, i) => (
                <TextLineRow key={i} line={line} decision={decisions[i]} capMM={capMM(line)} minCap={minCap}
                  image={props.image ?? null} onChange={(patch) => setDecision(i, patch)}
                  onFontForAll={textLines.length > 1 ? setFontForAll : undefined} />
              ))}
            </div>
          )}

          {step === "hoop" && (
            <div className="stack">
              <div className="choices">
                <Choice title="Choose one for me" subtitle="the smallest that fits" selected={a.hoopMode === "recommend"}
                  onClick={() => { setChosen({ ...chosen, hoop: true }); setA({ ...a, hoopMode: "recommend" }); }} />
                <Choice title="Skip for now" subtitle="no fit check" selected={a.hoopMode === "none"}
                  onClick={() => { setChosen({ ...chosen, hoop: true }); setA({ ...a, hoopMode: "none", hoop: null }); }} />
              </div>
              {hoopGroups(catalog.hoops, owned).map(([group, hoops], i) => (i === 0 || moreHoops) && (
                <div key={group}>
                  <div className="section-label">{group}</div>
                  <div className="choices">
                    {hoops.map((h) => {
                      const fits = h.widthMM >= a.widthMM && h.heightMM >= a.heightMM;
                      return (
                        <Choice key={h.name} title={h.name.replace(/^(Mighty Hoop|Durkee EZ Frame) /, "")}
                          subtitle={fits ? `${size(h.widthMM, h.heightMM)} · fits` : `too small for ${size(a.widthMM, a.heightMM)}`}
                          warning={!fits} selected={a.hoopMode === "specific" && a.hoop?.name === h.name}
                          onClick={() => { setChosen({ ...chosen, hoop: true }); setA({ ...a, hoopMode: "specific", hoop: h }); }} />
                      );
                    })}
                  </div>
                </div>
              ))}
              <div className="row-inline">
                {!moreHoops && hoopGroups(catalog.hoops, owned).length > 1 && (
                  <button type="button" className="btn ghost more" onClick={() => setMoreHoops(true)}>
                    {owned.length > 0 ? "See all hoops & frames ▾" : "More hoops & frames — Mighty Hoop, Durkee EZ Frame ▾"}
                  </button>
                )}
                {owned.length > 0 && props.onEditHoops && <button type="button" className="btn ghost more" onClick={props.onEditHoops}>Edit my hoops</button>}
              </div>
            </div>
          )}

          {step === "fabric" && (
            <div className="stack">
              {fabricGroups.map(([name, fabrics]) => (
                <div key={name}>
                  <div className="section-label">{name}</div>
                  <div className="choices">
                    {fabrics.map((f) => (
                      <Choice key={f.id} title={f.shortName} subtitle={FABRIC_HINTS[f.id]} selected={a.fabric === f.id}
                        onClick={() => { setChosen({ ...chosen, fabric: true }); setA({ ...a, fabric: f.id }); }} />
                    ))}
                  </div>
                </div>
              ))}
              {(() => { const f = catalog.fabrics.find((x) => x.id === a.fabric); return f ? (
                <p className="setup-note"><b>Stabilizer for {f.shortName.toLowerCase()}:</b> {f.stabilizer}</p>
              ) : null; })()}
              {a.fabric === "terry" && (
                <label className="check setup-check" title="A light, open fill sewn first over the whole design to flatten the pile so the stitching on top doesn't sink into it. You can change its thread colour later in the Laydown panel.">
                  <input type="checkbox" checked={a.laydown !== false} onChange={(e) => setA({ ...a, laydown: e.target.checked })} /> Flatten the nap first with a laydown stitch (recommended for towels and fleece)
                </label>
              )}
            </div>
          )}

          {step === "colors" && (
            <div className="stack">
              <div className="choices two">
                {catalog.colorPresets.map((p) => (
                  <Choice key={p.id} title={PRESET_LABELS[p.id][0]} subtitle={`${PRESET_LABELS[p.id][1]} · up to ${p.maxColors}`}
                    selected={a.colorPreset === p.id} disabled={isVector}
                    onClick={() => setA({ ...a, colorPreset: p.id })} />
                ))}
              </div>
              <label className="check">
                <input type="checkbox" checked={props.matchToThreadLibrary} disabled={isVector}
                  onChange={(e) => props.onMatchToThreadLibraryChange(e.target.checked)} />
                Match colours to my thread library
              </label>
              <div className="hint">
                {isVector
                  ? "Vector artwork always keeps its own exact colours — this only affects images."
                  : props.matchToThreadLibrary
                    ? "On: each detected colour is snapped to the nearest colour in your thread library (or a generic palette, if you haven't set one up). Turn this off to keep the exact colours from your file instead."
                    : "Off: keeps the exact colours detected in your file. Turn this on to snap them to real thread colours you can actually stitch with."}
              </div>
              <div className="choices two">
                {THREAD_WEIGHTS.map((w) => (
                  <Choice key={w.id} title={w.title} subtitle={w.subtitle} selected={a.threadWeight === w.id}
                    onClick={() => setA({ ...a, threadWeight: w.id })} />
                ))}
              </div>
              <div className="hint">
                {a.threadWeight === "wt40"
                  ? "40 wt is what every density setting is tuned for. Pick another weight only if that's really what's on the machine."
                  : "Every satin density and fill spacing is offset for this thread (thinner sews tighter, thicker wider) while the numbers you see stay 40 wt numbers. Change it later in the Density panel."}
              </div>
              <div className="summary">
                {placementName} · {size(a.widthMM, a.heightMM)} · {hoopName} · {fabricName} · {isVector ? "artwork colours" : PRESET_LABELS[a.colorPreset][0]}
              </div>
            </div>
          )}
        </div>

        <footer className="setup-foot">
          <button className="btn ghost" onClick={props.onCancel} disabled={!!busy}>Cancel</button>
          <div className="grow" />
          {stepIndex > 0 && <button className="btn ghost" onClick={() => setStep(STEPS[stepIndex - 1])} disabled={!!busy}>Back</button>}
          <span className="step-count">Step {stepIndex + 1} of {STEPS.length}</span>
          {step === "colors" ? (
            <button className="btn primary" onClick={finish} disabled={!!busy}>{busy ?? "Create embroidery"}</button>
          ) : (
            <button className="btn primary" onClick={() => setStep(STEPS[stepIndex + 1])}
              disabled={step === "placement" && a.placement === null}>Next</button>
          )}
        </footer>
      </div>
    </div>
  );
}

export function Choice({ title, subtitle, selected, warning, disabled, onClick }: {
  title: string; subtitle: string; selected: boolean; warning?: boolean; disabled?: boolean; onClick: () => void;
}) {
  return (
    <button type="button" className={"choice" + (selected ? " selected" : "") + (warning ? " warn" : "")} onClick={onClick} disabled={disabled}>
      <span className="choice-title">{title}</span>
      <span className="choice-sub">{subtitle}</span>
    </button>
  );
}

/** One detected line in the Text step: its crop, what it would sew at, and
 *  what to do with it. OCR pre-fills the words the first time the row shows. */
function TextLineRow({ line, decision, capMM, minCap, image, onChange, onFontForAll }: {
  line: TextLine; decision: TextDecision; capMM: number; minCap: number; image: DecodedImage | null;
  onChange: (patch: Partial<TextDecision>) => void;
  onFontForAll?: (fontID: string) => void;
}) {
  const canvasHost = useRef<HTMLDivElement>(null);
  const [reading, setReading] = useState(false);
  const [showWhole, setShowWhole] = useState(false);
  // Screen pixels per artwork pixel in the comparison crop, measured once
  // it is laid out (the canvas is scaled by CSS to fit its cell).
  const [cropDisplayScale, setCropDisplayScale] = useState<number | null>(null);
  const compareHost = useRef<HTMLDivElement>(null);
  const read = useRef(false);
  const tooSmall = capMM < minCap;
  const sewnCap = Math.max(capMM, minCap);
  useEffect(() => {
    if (!image || !canvasHost.current) return;
    const crop = cropLine(image, line.boundingBoxPixels, 0);
    crop.className = "text-crop";
    canvasHost.current.replaceChildren(crop);
  }, [image, line]);
  // Read the words once, when they will be needed: a line that cannot sew
  // as traced, or one the user has chosen to re-type.
  useEffect(() => {
    if (!image || read.current || decision.text || (!tooSmall && decision.action !== "retype")) return;
    read.current = true;
    let cancelled = false;
    setReading(true);
    readLine(cropLine(image, line.boundingBoxPixels, line.rotationDegrees)).then((guess) => {
      if (cancelled) return;
      setReading(false);
      if (guess.text && guess.confidence >= 55) onChange({ text: guess.text, action: "retype" });
    });
    return () => { cancelled = true; };
  }, [image, line, tooSmall, decision.action]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    const host = compareHost.current;
    if (!image || !host || decision.action !== "retype") return;
    const crop = cropLine(image, line.boundingBoxPixels, 0);
    crop.className = "text-crop";
    host.replaceChildren(crop);
    const canvasScale = Math.min(8, Math.max(1, 60 / (line.boundingBoxPixels.maxY - line.boundingBoxPixels.minY)));
    const measure = () => { if (crop.height > 0) setCropDisplayScale(canvasScale * (crop.clientHeight / crop.height)); };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(crop);
    return () => ro.disconnect();
  }, [image, line, decision.action]);

  const suggested = suggestFont(line);
  const groups = ["Sans-serif", "Serif", "Script"].map((g) => ({
    group: g,
    fonts: LETTERING_FONTS.filter((f) => f.group === g).sort((x, y) => (x.id === suggested ? -1 : y.id === suggested ? 1 : 0)),
  }));
  const sample = decision.text.trim() || "Sample";
  const chosen = LETTERING_FONTS.find((f) => f.id === decision.fontID);
  // The crop shows the line's letters at a known screen height; the
  // comparison sample is set so its capitals match, and condensed the
  // same way the run will be on the fabric.
  const box = line.boundingBoxPixels;
  const cropScale = cropDisplayScale ?? Math.min(64 / ((box.maxY - box.minY) * 1.7), 1e9);
  // The face is compared at the original's on-screen height; the label
  // carries the height it will actually sew at, and the condensing is
  // worked out at that size.
  const letterPx = Math.max(10, Math.min(60, line.capHeightPixels * cropScale));
  const enlarge = sewnCap / Math.max(1e-6, capMM);
  const naturalWidthPx = letterPx * 0.62 * Math.max(1, Array.from(sample).length) * (chosen?.width === "condensed" ? 0.8 : chosen?.width === "wide" ? 1.15 : 1);
  const targetWidthPx = (box.maxX - box.minX) * cropScale * enlarge;
  const condense = Math.max(0.75, Math.min(1, targetWidthPx / Math.max(1, naturalWidthPx)));
  const wholeBox = image ? {
    left: `${(box.minX / image.width) * 100}%`, top: `${(box.minY / image.height) * 100}%`,
    width: `${((box.maxX - box.minX) / image.width) * 100}%`, height: `${((box.maxY - box.minY) / image.height) * 100}%`,
  } : null;

  return (
    <div className={"text-line" + (tooSmall ? " small" : "")}>
      <div className="text-line-head">
        <div ref={canvasHost} className="text-crop-host" />
        <div className="text-line-meta">
          <b>{line.shapeIndices.length} letters{line.curved ? ", on a curve" : ""}{line.mixedCase === false ? ", capitals" : ""}</b>
          <span className={"text-status" + (tooSmall ? " warn" : "")}>
            {tooSmall ? `about ${len(capMM)} ${displayUnitLabel()} tall here — needs ${len(minCap)}` : `about ${len(capMM)} ${displayUnitLabel()} tall — sews as traced`}
          </span>
          {image && <button type="button" className="text-link" onClick={() => setShowWhole((v) => !v)}>{showWhole ? "Hide the whole artwork" : "Show where this is in the artwork"}</button>}
        </div>
      </div>
      {showWhole && image && wholeBox && (
        <div className="text-whole">
          <img src={image.previewURL} alt="" />
          <span className="text-whole-box" style={wholeBox} />
        </div>
      )}
      <div className="text-line-actions">
        <label className={"text-action" + (decision.action === "retype" ? " on" : "")}>
          <input type="radio" name={`text-${line.shapeIndices[0]}`} checked={decision.action === "retype"} onChange={() => onChange({ action: "retype" })} />
          <span>Re-type as lettering</span>
        </label>
        <label className={"text-action" + (decision.action === "drop" ? " on" : "")}>
          <input type="radio" name={`text-${line.shapeIndices[0]}`} checked={decision.action === "drop"} onChange={() => onChange({ action: "drop" })} />
          <span>Leave it out</span>
        </label>
        <label className={"text-action" + (decision.action === "keep" ? " on" : "") + (tooSmall ? " disabled" : "")} title={tooSmall ? "Too small to sew as traced at this size" : undefined}>
          <input type="radio" name={`text-${line.shapeIndices[0]}`} checked={decision.action === "keep"} disabled={tooSmall} onChange={() => onChange({ action: "keep" })} />
          <span>Keep as traced</span>
        </label>
      </div>
      {decision.action === "retype" && (
        <div className="text-retype">
          <input type="text" value={decision.text} placeholder={reading ? "Reading the artwork…" : "Type the words exactly as they should sew"}
            onChange={(e) => onChange({ text: e.target.value })} maxLength={80} />
          <div className="text-compare">
            <div className="text-compare-cell"><span className="text-compare-label">Original</span><div className="text-compare-crop" ref={compareHost} /></div>
            <div className="text-compare-cell">
              <span className="text-compare-label">{chosen?.displayName ?? "Lettering"} · {len(sewnCap)} {displayUnitLabel()} tall{condense < 0.99 ? ` · condensed ${Math.round((1 - condense) * 100)}%` : ""}</span>
              <div className="text-compare-sample" style={{ fontFamily: `"${fontFaceFamily(decision.fontID)}", sans-serif`, fontSize: `${letterPx / 0.7}px`, transform: `scaleX(${condense})` }}>{chosen?.capsOnly ? sample.toUpperCase() : sample}</div>
            </div>
          </div>
          {groups.map((g) => (
            <div key={g.group} className="font-group">
              <div className="font-group-name">{g.group}</div>
              <div className="font-tiles">
                {g.fonts.map((f) => {
                  const thin = !!f.thinStrokes && sewnCap < THIN_STROKE_MIN_CAP_MM;
                  return (
                    <button key={f.id} type="button" className={"font-tile" + (decision.fontID === f.id ? " on" : "") + (thin ? " thin" : "")}
                      onClick={() => onChange({ fontID: f.id })} title={f.displayName + (thin ? ` — thin strokes need ${len(THIN_STROKE_MIN_CAP_MM)} ${displayUnitLabel()} to hold` : "")}>
                      <span className="font-tile-sample" style={{ fontFamily: `"${fontFaceFamily(f.id)}", sans-serif` }}>{f.capsOnly ? sample.toUpperCase() : sample}</span>
                      <span className="font-tile-name">{f.displayName}{f.id === suggested ? " · suggested" : ""}{thin ? " · too fine at this size" : ""}</span>
                    </button>
                  );
                })}
              </div>
            </div>
          ))}
          <span className="hint">
            Set at {len(sewnCap)} {displayUnitLabel()} tall{line.curved ? ", following the curve" : ""}, in the artwork's colour, where the original sits.
            {onFontForAll && <> <button type="button" className="text-link" onClick={() => onFontForAll(decision.fontID)}>Use this font for every line</button></>}
          </span>
        </div>
      )}
    </div>
  );
}
