// The after-import questions, mirroring the Mac app's ImportSetupSheet:
// five steps of tappable choices, each answer nudging the next. The
// stitch preview is withheld until the last step so the first thing the
// user sees comes from their own answers, not unconfirmed defaults.

import { useMemo, useState } from "react";
import { THREAD_WEIGHTS, type ThreadWeight } from "../types";
import type { Catalog, CatalogFabric, CatalogSize, ColorPresetId, FabricType } from "../types";
import { approx, cm } from "../format";


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
}

interface Props {
  catalog: Catalog;
  fileName: string;
  isVector: boolean;
  recommendedWidthMM: number;
  recommendedHeightMM: number;
  aspectRatio: number;
  initial: SetupAnswers;
  busy: string | null;
  matchToThreadLibrary: boolean;
  onMatchToThreadLibraryChange: (on: boolean) => void;
  onFinish: (answers: SetupAnswers) => void;
  onCancel: () => void;
}

const STEPS = ["placement", "size", "hoop", "fabric", "colors"] as const;
type Step = (typeof STEPS)[number];

const TITLES: Record<Step, string> = {
  placement: "Where is this going?",
  size: "How big should it be?",
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

export function smallestHoopThatFits(hoops: CatalogSize[], widthMM: number, heightMM: number): CatalogSize | null {
  const fits = hoops.filter((h) => h.widthMM >= widthMM && h.heightMM >= heightMM);
  fits.sort((a, b) => a.widthMM * a.heightMM - b.widthMM * b.heightMM);
  return fits[0] ?? null;
}

export default function SetupFlow(props: Props) {
  const { catalog, recommendedWidthMM, recommendedHeightMM, aspectRatio, isVector, busy } = props;
  const [step, setStep] = useState<Step>("placement");
  const [a, setA] = useState<SetupAnswers>(props.initial);
  // Steps the user has answered by hand. An earlier answer pre-fills a
  // later step (placement -> fabric, size -> hoop) only until the user
  // has chosen that later step themselves; after that their choice sticks.
  const [chosen, setChosen] = useState<{ hoop: boolean; fabric: boolean }>({ hoop: false, fabric: false });
  const stepIndex = STEPS.indexOf(step);

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
    const smallest = smallestHoopThatFits(catalog.hoops, next.widthMM, next.heightMM);
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
      case "size":
        if (a.placement && a.placement !== "custom") {
          const p = a.placement;
          return `Standard for ${p.name.toLowerCase()} is ${cm(p.widthMM)} × ${cm(p.heightMM)} cm. Adjust if you like — the finest detail in your artwork looks good down to about ${cm(recommendedWidthMM)} cm wide.`;
        }
        return `Based on the finest detail in your artwork, I'd suggest about ${cm(recommendedWidthMM)} × ${cm(recommendedHeightMM)} cm. Type any size you want.`;
      case "hoop":
        if (!chosen.hoop && a.hoopMode === "specific" && a.hoop)
          return isCap && /cap|hat/i.test(a.hoop.name)
            ? `I've picked the ${a.hoop.name} since this is going on a cap. Cap frames vary by machine — change it if yours is a different size.`
            : `I've picked ${a.hoop.name} — it fits ${cm(a.widthMM)} × ${cm(a.heightMM)} cm. Change it if your machine uses a different one.`;
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
    ? (smallestHoopThatFits(catalog.hoops, a.widthMM, a.heightMM)?.name ?? "no hoop fits") + " (chosen for you)"
    : a.hoop?.name ?? "no hoop";
  const fabricName = catalog.fabrics.find((f) => f.id === a.fabric)?.displayName ?? a.fabric;

  const finish = () => {
    const hoop = a.hoopMode === "none" ? null : a.hoopMode === "recommend"
      ? smallestHoopThatFits(catalog.hoops, a.widthMM, a.heightMM) : a.hoop;
    props.onFinish({ ...a, hoop });
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
                <Choice key={p.name} title={p.name} subtitle={`${cm(p.widthMM)} × ${cm(p.heightMM)} cm`}
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
                  <Choice title={`Standard ${a.placement.name.toLowerCase()}`} subtitle={`${cm(a.placement.widthMM)} × ${cm(a.placement.heightMM)} cm`}
                    selected={approx(a.widthMM, a.placement.widthMM) && approx(a.heightMM, a.placement.heightMM)}
                    onClick={() => setSize(a.placement !== "custom" && a.placement ? a.placement.widthMM : a.widthMM, a.placement !== "custom" && a.placement ? a.placement.heightMM : undefined)} />
                )}
                <Choice title="Recommended for this artwork" subtitle={`${cm(recommendedWidthMM)} × ${cm(recommendedHeightMM)} cm`}
                  selected={approx(a.widthMM, recommendedWidthMM) && approx(a.heightMM, recommendedHeightMM)}
                  onClick={() => setSize(recommendedWidthMM, recommendedHeightMM)} />
              </div>
              <div className="size-row">
                <label>Width <input type="number" step="0.1" min="0.5" value={+(a.widthMM / 10).toFixed(1)}
                  onChange={(e) => setSize(Number(e.target.value) * 10)} /></label>
                <span className="x">×</span>
                <label>Height <input type="number" step="0.1" min="0.5" value={+(a.heightMM / 10).toFixed(1)}
                  onChange={(e) => setA(withPredictedHoop({ ...a, heightMM: Math.max(1, Number(e.target.value) * 10), lockAspect: false }))} /></label>
                <span className="unit">cm</span>
                <label className="check"><input type="checkbox" checked={a.lockAspect}
                  onChange={(e) => {
                    const lock = e.target.checked;
                    setA({ ...a, lockAspect: lock, heightMM: lock && aspectRatio > 0 ? a.widthMM / aspectRatio : a.heightMM });
                  }} /> Keep proportions</label>
              </div>
            </div>
          )}

          {step === "hoop" && (
            <div className="choices">
              {catalog.hoops.map((h) => {
                const fits = h.widthMM >= a.widthMM && h.heightMM >= a.heightMM;
                return (
                  <Choice key={h.name} title={h.name}
                    subtitle={fits ? `${cm(h.widthMM)} × ${cm(h.heightMM)} cm · fits` : `too small for ${cm(a.widthMM)} × ${cm(a.heightMM)} cm`}
                    warning={!fits} selected={a.hoopMode === "specific" && a.hoop?.name === h.name}
                    onClick={() => { setChosen({ ...chosen, hoop: true }); setA({ ...a, hoopMode: "specific", hoop: h }); }} />
                );
              })}
              <Choice title="Choose one for me" subtitle="the smallest that fits" selected={a.hoopMode === "recommend"}
                onClick={() => { setChosen({ ...chosen, hoop: true }); setA({ ...a, hoopMode: "recommend" }); }} />
              <Choice title="Skip for now" subtitle="no fit check" selected={a.hoopMode === "none"}
                onClick={() => { setChosen({ ...chosen, hoop: true }); setA({ ...a, hoopMode: "none", hoop: null }); }} />
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
                {placementName} · {cm(a.widthMM)} × {cm(a.heightMM)} cm · {hoopName} · {fabricName} · {isVector ? "artwork colours" : PRESET_LABELS[a.colorPreset][0]}
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
