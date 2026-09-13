import { useEffect, useMemo, useState } from "react";
import glossary from "../glossary.json";
import type { AccountState, Catalog, ColorPresetId, EmbroideryObject, FabricType, RGBColor, ThreadColor } from "../types";
import { LETTERING_FONTS, generateLetteringShapes, type LetteringSpec } from "../lettering";
import { hexRGB, rgbCSS, rgbHex, type Preferences } from "../prefs";
import { AccountMenu, PromoBox, price, statusLine } from "./Account";
import { api } from "../api";

export function Modal({ title, onClose, children, wide }: { title: string; onClose: () => void; children: React.ReactNode; wide?: boolean }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  return (
    <div className="modal-backdrop" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className={"modal" + (wide ? " wide" : "")} role="dialog" aria-label={title}>
        <header className="modal-head"><h2>{title}</h2><button className="icon-btn" onClick={onClose} aria-label="Close">×</button></header>
        <div className="modal-body">{children}</div>
      </div>
    </div>
  );
}

// --- Help: the Mac app's glossary, verbatim (src/glossary.json) --------------

export function HelpSheet({ onClose }: { onClose: () => void }) {
  const [q, setQ] = useState("");
  const sections = useMemo(() => {
    const needle = q.trim().toLowerCase();
    if (!needle) return glossary;
    return glossary.map((s) => ({ ...s, entries: s.entries.filter((e) => e.term.toLowerCase().includes(needle) || e.definition.toLowerCase().includes(needle)) })).filter((s) => s.entries.length > 0);
  }, [q]);
  return (
    <Modal title="Help — digitizing terms" onClose={onClose} wide>
      <input className="search" autoFocus placeholder="Search terms and definitions…" value={q} onChange={(e) => setQ(e.target.value)} />
      <p className="hint">Every term this app uses, what it means, and why it matters for how a design sews out. Same reference as the Mac app.</p>
      {sections.length === 0 && <p className="hint">Nothing matches "{q}".</p>}
      {sections.map((s) => (
        <section key={s.title} className="help-section">
          <h3>{s.title}</h3>
          {s.entries.map((e) => <div key={e.term} className="help-entry"><b>{e.term}</b><p>{e.definition}</p></div>)}
        </section>
      ))}
    </Modal>
  );
}

// --- Add Lettering --------------------------------------------------------------

export function LetteringSheet({ palette, selectedCount, onClose, onAdd }: {
  palette: ThreadColor[]; selectedCount: number; onClose: () => void;
  onAdd: (spec: LetteringSpec, threadColor: ThreadColor, replaceSelected: boolean) => Promise<void>;
}) {
  const [text, setText] = useState("");
  const [fontID, setFontID] = useState(LETTERING_FONTS[0].id);
  const [sizeMM, setSizeMM] = useState(20);
  const [spacingMM, setSpacingMM] = useState(0);
  const [curved, setCurved] = useState(false);
  const [radiusMM, setRadiusMM] = useState(40);
  const [hex, setHex] = useState("#1144aa");
  const [replace, setReplace] = useState(selectedCount > 0);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [preview, setPreview] = useState<string | null>(null);

  // Live outline preview, drawn as SVG from the same generator that feeds the engine.
  useEffect(() => {
    let cancelled = false;
    if (!text.trim()) { setPreview(null); return; }
    generateLetteringShapes({ text, fontID, fontSizeMM: sizeMM, letterSpacingMM: spacingMM, arcRadiusMM: curved ? radiusMM : null }).then((shapes) => {
      if (cancelled) return;
      let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
      const d = shapes.map((s) => s.subPaths.map((sp) => sp.points.map((p, i) => { minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x); minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y); return `${i ? "L" : "M"}${p.x.toFixed(2)} ${p.y.toFixed(2)}`; }).join(" ") + "Z").join(" ")).join(" ");
      const pad = 2;
      setPreview(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="${minX - pad} ${minY - pad} ${maxX - minX + pad * 2} ${maxY - minY + pad * 2}"><path d="${d}" fill="${hex}" fill-rule="evenodd"/></svg>`);
      setError(null);
    }).catch((e) => { if (!cancelled) { setPreview(null); setError(e.message); } });
    return () => { cancelled = true; };
  }, [text, fontID, sizeMM, spacingMM, curved, radiusMM, hex]);

  const groups = Array.from(new Set(LETTERING_FONTS.map((f) => f.group)));
  const submit = async () => {
    setBusy(true); setError(null);
    try {
      const rgb = hexRGB(hex);
      const match = palette.find((c) => c.rgb.r === rgb.r && c.rgb.g === rgb.g && c.rgb.b === rgb.b);
      const threadColor: ThreadColor = match ?? { id: crypto.randomUUID(), name: "Lettering Colour", rgb };
      await onAdd({ text, fontID, fontSizeMM: sizeMM, letterSpacingMM: spacingMM, arcRadiusMM: curved ? radiusMM : null }, threadColor, replace);
      onClose();
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); } finally { setBusy(false); }
  };

  return (
    <Modal title="Add lettering" onClose={onClose}>
      <p className="hint">Clean satin letters generated from the font's own outline — sharp at any size or curve, unlike tracing an image of text.</p>
      <label className="field">Text<input autoFocus value={text} onChange={(e) => setText(e.target.value)} placeholder="Type the text to add" /></label>
      <label className="field">Font
        <select value={fontID} onChange={(e) => setFontID(e.target.value)}>
          {groups.map((g) => <optgroup key={g} label={g}>{LETTERING_FONTS.filter((f) => f.group === g).map((f) => <option key={f.id} value={f.id}>{f.displayName}</option>)}</optgroup>)}
        </select>
      </label>
      <div className="slider-row"><div className="slider-head"><span>Letter height</span><b>{(sizeMM / 10).toFixed(2)} cm</b></div><input type="range" min={2} max={60} step={0.5} value={sizeMM} onChange={(e) => setSizeMM(Number(e.target.value))} /></div>
      <div className="slider-row"><div className="slider-head"><span>Letter spacing</span><b>{(spacingMM / 10).toFixed(2)} cm</b></div><input type="range" min={-1} max={10} step={0.1} value={spacingMM} onChange={(e) => setSpacingMM(Number(e.target.value))} /></div>
      <label className="check"><input type="checkbox" checked={curved} onChange={(e) => setCurved(e.target.checked)} /> Curve along a ring</label>
      {curved && <div className="slider-row"><div className="slider-head"><span>Curve radius</span><b>{(radiusMM / 10).toFixed(1)} cm</b></div><input type="range" min={5} max={200} step={1} value={radiusMM} onChange={(e) => setRadiusMM(Number(e.target.value))} /></div>}
      <label className="row">Thread colour
        <span className="color-pick"><input type="color" value={hex} onChange={(e) => setHex(e.target.value)} />
          <select value="" onChange={(e) => { const c = palette.find((x) => x.name === e.target.value); if (c) setHex(rgbHex(c.rgb)); }}>
            <option value="">From thread library…</option>{palette.map((c) => <option key={c.name + c.rgb.r} value={c.name}>{c.name}</option>)}
          </select></span>
      </label>
      {selectedCount > 0 && <label className="check"><input type="checkbox" checked={replace} onChange={(e) => setReplace(e.target.checked)} /> Replace {selectedCount} selected object{selectedCount === 1 ? "" : "s"}</label>}
      <div className="lettering-preview">{preview ? <div dangerouslySetInnerHTML={{ __html: preview }} /> : <span className="hint">Preview appears here</span>}</div>
      {error && <div className="error-text">{error}</div>}
      <div className="modal-foot"><button className="btn ghost" onClick={onClose}>Cancel</button><button className="btn primary" disabled={busy || !text.trim()} onClick={submit}>{busy ? "Adding…" : "Add"}</button></div>
    </Modal>
  );
}

// --- Merge Colours ------------------------------------------------------------

export function MergeColorsSheet({ objects, palette, onClose, onMerge }: {
  objects: EmbroideryObject[]; palette: ThreadColor[]; onClose: () => void; onMerge: (sources: RGBColor[], target: ThreadColor) => void;
}) {
  const distinct = useMemo(() => {
    const seen = new Map<string, { color: ThreadColor; count: number }>();
    for (const o of objects) { const k = rgbCSS(o.threadColor.rgb); const e = seen.get(k); if (e) e.count++; else seen.set(k, { color: o.threadColor, count: 1 }); }
    return Array.from(seen.values());
  }, [objects]);
  const [chosen, setChosen] = useState<Set<string>>(new Set());
  const [targetKey, setTargetKey] = useState<string>("");
  const targets = [...distinct.map((d) => d.color), ...palette];
  const target = targets.find((c) => `${c.name}|${rgbCSS(c.rgb)}` === targetKey) ?? null;
  return (
    <Modal title="Merge colours" onClose={onClose}>
      <p className="hint">Tick the colours to merge, then pick the thread they should all become. Fewer colours means fewer thread changes.</p>
      <ul className="merge-list">
        {distinct.map((d) => { const k = rgbCSS(d.color.rgb); return (
          <li key={k}><label className="check"><input type="checkbox" checked={chosen.has(k)} onChange={(e) => { const n = new Set(chosen); e.target.checked ? n.add(k) : n.delete(k); setChosen(n); }} />
            <span className="swatch" style={{ background: k }} /> {d.color.name} <small>· {d.count} object{d.count === 1 ? "" : "s"}</small></label></li>); })}
      </ul>
      <label className="row">Merge into
        <select value={targetKey} onChange={(e) => setTargetKey(e.target.value)}>
          <option value="">Choose a thread…</option>
          <optgroup label="Colours in this design">{distinct.map((d) => { const k = `${d.color.name}|${rgbCSS(d.color.rgb)}`; return <option key={k} value={k}>{d.color.name}</option>; })}</optgroup>
          <optgroup label="Thread library">{palette.map((c) => { const k = `${c.name}|${rgbCSS(c.rgb)}`; return <option key={k} value={k}>{c.name}{c.catalogNumber ? ` (${c.catalogNumber})` : ""}</option>; })}</optgroup>
        </select>
      </label>
      <div className="modal-foot"><button className="btn ghost" onClick={onClose}>Cancel</button>
        <button className="btn primary" disabled={chosen.size === 0 || !target} onClick={() => { onMerge(distinct.filter((d) => chosen.has(rgbCSS(d.color.rgb))).map((d) => d.color.rgb), target!); onClose(); }}>Merge {chosen.size || ""} colour{chosen.size === 1 ? "" : "s"}</button></div>
    </Modal>
  );
}

// --- Thread Library -------------------------------------------------------------

export function ThreadLibraryEditor({ library, onChange }: { library: ThreadColor[]; onChange: (lib: ThreadColor[]) => void }) {
  const [name, setName] = useState("");
  const [hex, setHex] = useState("#c0392b");
  const add = () => { if (!name.trim()) return; onChange([...library, { id: crypto.randomUUID(), name: name.trim(), rgb: hexRGB(hex) }]); setName(""); };
  return (
    <div className="stack">
      <p className="hint">Your own thread inventory. When it has colours, imports and the colour pickers match against <b>only</b> these instead of the built-in palette. Leave it empty to use the built-in palette.</p>
      <ul className="merge-list">
        {library.map((c) => <li key={c.id}><span className="swatch" style={{ background: rgbCSS(c.rgb) }} /> {c.name} <span className="grow" /><button className="icon-btn" title="Remove" onClick={() => onChange(library.filter((x) => x.id !== c.id))}>×</button></li>)}
        {library.length === 0 && <li className="hint">No custom colours yet — using the built-in palette.</li>}
      </ul>
      <div className="row-inline"><input type="color" value={hex} onChange={(e) => setHex(e.target.value)} /><input placeholder="Thread name, e.g. Madeira 1147 Red" value={name} onChange={(e) => setName(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter") add(); }} /><button className="btn small" onClick={add} disabled={!name.trim()}>Add</button></div>
    </div>
  );
}

export function ThreadLibrarySheet({ library, onChange, onClose }: { library: ThreadColor[]; onChange: (lib: ThreadColor[]) => void; onClose: () => void }) {
  return <Modal title="Thread library" onClose={onClose}><ThreadLibraryEditor library={library} onChange={onChange} /><div className="modal-foot"><button className="btn primary" onClick={onClose}>Done</button></div></Modal>;
}

// --- Settings ---------------------------------------------------------------------

export function SettingsSheet({ catalog, prefs, account, onPrefs, onClose, onSignOut, onRefreshAccount }: {
  catalog: Catalog; prefs: Preferences; account: AccountState | null; onPrefs: (p: Preferences) => void; onClose: () => void; onSignOut: () => void; onRefreshAccount: () => void;
}) {
  const [tab, setTab] = useState<"account" | "preferences" | "threads">(account ? "account" : "preferences");
  const [error, setError] = useState<string | null>(null);
  const [promo, setPromo] = useState<{ code: string | null; description: string | null }>({ code: null, description: null });
  const go = async (fn: () => Promise<string>) => { try { window.location.assign(await fn()); } catch (e) { setError(e instanceof Error ? e.message : String(e)); } };
  const set = <K extends keyof Preferences>(k: K, v: Preferences[K]) => onPrefs({ ...prefs, [k]: v });
  return (
    <Modal title="Settings" onClose={onClose} wide>
      <div className="tabs">
        {account && <button className={tab === "account" ? "on" : ""} onClick={() => setTab("account")}>Account & billing</button>}
        <button className={tab === "preferences" ? "on" : ""} onClick={() => setTab("preferences")}>Preferences</button>
        <button className={tab === "threads" ? "on" : ""} onClick={() => setTab("threads")}>Thread library</button>
      </div>
      {tab === "account" && account && (
        <div className="stack">
          <div className="kv"><span>Signed in as</span><b>{account.email}</b></div>
          <div className="kv"><span>Name</span><b>{account.name}</b></div>
          <div className="kv"><span>Plan</span><b>{statusLine(account)}</b></div>
          <div className="kv"><span>Price</span><b>{price(account)}</b></div>
          {account.status === "trialing" && <PromoBox onChange={(code, description) => setPromo({ code, description })} />}
          <div className="btn-row">
            {account.status === "trialing" && <button className="btn primary" onClick={() => go(() => api.checkoutURL(promo.code ?? undefined))}>Subscribe · {promo.description ?? price(account)}</button>}
            <a className="btn ghost" href="https://www.piperstitch.com/" target="_blank" rel="noopener">piperstitch.com</a>
            {account.has_billing && <button className="btn" onClick={() => go(api.billingPortalURL)}>Manage billing, card & invoices</button>}
            {account.has_billing && account.status === "active" && !account.cancel_at_period_end && <button className="btn ghost" onClick={() => go(api.billingPortalURL)}>Cancel subscription</button>}
            <button className="btn ghost" onClick={onRefreshAccount}>Refresh status</button>
          </div>
          <p className="hint">Card, invoices, and cancelling are handled on Stripe's secure billing page. Cancelling keeps the app working until the end of the paid period; downloaded files keep working forever.</p>
          {error && <div className="error-text">{error}</div>}
          <div><button className="btn ghost" onClick={onSignOut}>Sign out</button></div>
        </div>
      )}
      {tab === "preferences" && (
        <div className="stack">
          <label className="row">Default hoop
            <select value={prefs.defaultHoopName ?? ""} onChange={(e) => set("defaultHoopName", e.target.value || null)}>
              <option value="">None</option>{catalog.hoops.map((h) => <option key={h.name} value={h.name}>{h.name}</option>)}
            </select></label>
          <label className="row">Default fabric
            <select value={prefs.defaultFabric} onChange={(e) => set("defaultFabric", e.target.value as FabricType)}>{catalog.fabrics.map((f) => <option key={f.id} value={f.id}>{f.displayName}</option>)}</select></label>
          <label className="row">Default colour reduction
            <select value={prefs.defaultColorPreset} onChange={(e) => set("defaultColorPreset", e.target.value as ColorPresetId)}>{catalog.colorPresets.map((c) => <option key={c.id} value={c.id}>{c.id === "preserveArtwork" ? "Keep every colour" : c.id === "normalEmbroidery" ? "Normal embroidery" : c.id === "productionEfficient" ? "Production efficient" : "As few as possible"}</option>)}</select></label>
          <label className="check"><input type="checkbox" checked={prefs.matchToThreadLibrary} onChange={(e) => set("matchToThreadLibrary", e.target.checked)} /> Match imported colours to the thread library</label>
          <label className="check"><input type="checkbox" checked={prefs.allowExtendedDensity} onChange={(e) => set("allowExtendedDensity", e.target.checked)} /> Allow density past normal limits</label>
          <label className="check"><input type="checkbox" checked={prefs.showJumps} onChange={(e) => set("showJumps", e.target.checked)} /> Show jump stitches in the preview</label>
          <p className="hint">Defaults apply to the next design you import. Everything can still be changed per design.</p>
        </div>
      )}
      {tab === "threads" && <ThreadLibraryEditor library={prefs.threadLibrary} onChange={(lib) => set("threadLibrary", lib)} />}
      <div className="modal-foot"><button className="btn primary" onClick={onClose}>Done</button></div>
    </Modal>
  );
}

export { AccountMenu };
