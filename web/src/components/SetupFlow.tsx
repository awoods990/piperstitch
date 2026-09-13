// The after-import questions, mirroring the Mac app's ImportSetupSheet:
// five steps of tappable choices, each answer nudging the next. The
// stitch preview is withheld until the last step so the first thing the
// user sees comes from their own answers, not unconfirmed defaults.

import { useMemo, useState } from "react";
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

/** Only placements whose name names a garment/material commit to a guess. */
export function predictedFabric(preset: CatalogSize): FabricType | null {
  const n = preset.name.toLowerCase();
  if (n.includes("cap") || n.includes("hat")) return "structuredCap";
  if (n.includes("polo")) return "knit";
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
  const stepIndex = STEPS.indexOf(step);

  const isCap = a.placement && a.placement !== "custom" && /cap|hat/i.test(a.placement.name);

  const setSize = (w: number, h?: number) => {
    const width = Math.max(1, w);
    const height = h ?? (a.lockAspect && aspectRatio > 0 ? width / aspectRatio : a.heightMM);
    setA({ ...a, widthMM: width, heightMM: Math.max(1, height) });
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
        return isCap
          ? "Cap frames vary by machine — pick the closest size, or let me choose one that fits."
          : "I'll warn you if the design won't fit. Not sure? Let me pick the smallest one that does.";
      case "fabric":
        return isCap
          ? "For a cap front I've started with a structured cap. A stiff buckram front barely pulls; a soft cap or a knit beanie pulls a lot more, so I compensate differently for each."
          : "Stretchier material pulls more as it sews, so I widen the shapes more to keep the finished size true.";
      case "colors":
        return "Fewer colours means fewer thread changes and a faster sew-out. Vector artwork always keeps its own colours.";
    }
  }, [step, a.placement, isCap, recommendedWidthMM, recommendedHeightMM]);

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
                    const changed = a.placement === "custom" || a.placement?.name !== p.name;
                    const predicted = changed ? predictedFabric(p) : null;
                    setA({ ...a, placement: p, widthMM: p.widthMM, heightMM: p.heightMM, fabric: predicted ?? a.fabric });
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
                  onChange={(e) => setA({ ...a, heightMM: Math.max(1, Number(e.target.value) * 10), lockAspect: false })} /></label>
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
                    onClick={() => setA({ ...a, hoopMode: "specific", hoop: h })} />
                );
              })}
              <Choice title="Choose one for me" subtitle="the smallest that fits" selected={a.hoopMode === "recommend"}
                onClick={() => setA({ ...a, hoopMode: "recommend" })} />
              <Choice title="Skip for now" subtitle="no fit check" selected={a.hoopMode === "none"}
                onClick={() => setA({ ...a, hoopMode: "none", hoop: null })} />
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
                        onClick={() => setA({ ...a, fabric: f.id })} />
                    ))}
                  </div>
                </div>
              ))}
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
