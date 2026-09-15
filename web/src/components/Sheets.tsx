import { useEffect, useMemo, useState } from "react";
import glossary from "../glossary.json";
import type { AccountState, Catalog, ColorPresetId, EmbroideryObject, FabricType, ProjectSummary, RGBColor, ThreadColor } from "../types";
import { LETTERING_FONTS, ensureFontFaces, fontFaceFamily, generateLetteringShapes, type LetteringSpec } from "../lettering";
import { hexRGB, rgbCSS, rgbHex, type Preferences } from "../prefs";
import { AccountMenu, PromoBox, price, statusLine } from "./Account";
import { THREAD_SUPPLIERS, type ThreadSupplier } from "../threadSuppliers";
import { cm } from "../format";
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

// --- Open a saved project ----------------------------------------------------------

export function OpenProjectsSheet({ projects, busy, onOpen, onDelete, onClose }: {
  /** null: still loading; []: none saved yet. */
  projects: ProjectSummary[] | null; busy: string | null;
  onOpen: (p: ProjectSummary) => void; onDelete: (p: ProjectSummary) => void; onClose: () => void;
}) {
  return (
    <Modal title="Open a saved project" onClose={onClose}>
      {!projects && <p className="hint">Loading your saved projects…</p>}
      {projects && projects.length === 0 && <p className="hint">Nothing saved yet — use Save in the toolbar once you're working on a design, and it'll show up here.</p>}
      {projects && projects.length > 0 && (
        <div className="projects">
          <ul>
            {projects.map((p) => (
              <li key={p.id}>
                <button className="project" onClick={() => { onOpen(p); onClose(); }} disabled={!!busy}>
                  <b>{p.name}</b>
                  <span>{cm(p.widthMM)} × {cm(p.heightMM)} cm · {p.objectCount} object{p.objectCount === 1 ? "" : "s"} · {new Date(p.updatedAt).toLocaleDateString()}</span>
                </button>
                <button className="icon-btn" title="Delete project" disabled={!!busy} onClick={() => onDelete(p)}>×</button>
              </li>
            ))}
          </ul>
        </div>
      )}
      <div className="modal-foot"><button className="btn ghost" onClick={onClose}>Cancel</button></div>
    </Modal>
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
      <p className="hint">Every term this app uses, what it means, and why it matters for how a design sews out.</p>
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
  useEffect(() => { ensureFontFaces().catch(() => { /* picker falls back to the system font */ }); }, []);
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
      <div className="field">Font
        <div className="font-picker">
          {groups.map((g) => (
            <div key={g} className="font-group">
              <div className="section-label">{g}</div>
              <div className="font-choices">
                {LETTERING_FONTS.filter((f) => f.group === g).map((f) => (
                  <button key={f.id} type="button" className={"font-choice" + (fontID === f.id ? " selected" : "")}
                    style={{ fontFamily: `"${fontFaceFamily(f.id)}", sans-serif` }} onClick={() => setFontID(f.id)} title={f.displayName}>
                    {f.displayName}
                  </button>
                ))}
              </div>
            </div>
          ))}
        </div>
      </div>
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

interface CatalogColor { number: string; name: string; r: number; g: number; b: number }

const catalogCache = new Map<string, CatalogColor[]>();

/** A browsable, searchable view of one supplier's catalog (fetched from
 *  web/public/thread-catalogs/*.json on first use, cached after that),
 *  each color a click away from landing in the user's own library --
 *  already-added ones show a checkmark and a tinted row instead of the
 *  add button, so it's obvious at a glance which ones are saved. */
function ThreadCatalogBrowser({ supplier, library, onAdd, onAddMany }: {
  supplier: ThreadSupplier; library: ThreadColor[];
  onAdd: (name: string, rgb: RGBColor) => void; onAddMany: (items: { name: string; rgb: RGBColor }[]) => void;
}) {
  const [lineIndex, setLineIndex] = useState(0);
  const [colors, setColors] = useState<CatalogColor[] | null>(null);
  const [query, setQuery] = useState("");
  const [error, setError] = useState<string | null>(null);
  const line = supplier.catalogs[lineIndex];
  const nameFor = (c: CatalogColor) => `${supplier.name}${line.label !== supplier.name ? " " + line.label : ""} ${c.number} ${c.name}`.trim();

  useEffect(() => {
    setQuery("");
    const cached = catalogCache.get(line.file);
    if (cached) { setColors(cached); setError(null); return; }
    setColors(null); setError(null);
    fetch(`/thread-catalogs/${line.file}`)
      .then((r) => { if (!r.ok) throw new Error(`${r.status}`); return r.json() as Promise<CatalogColor[]>; })
      .then((data) => { catalogCache.set(line.file, data); setColors(data); })
      .catch(() => setError("Couldn't load this catalog — try again in a moment."));
  }, [line.file]);

  const filtered = useMemo(() => {
    if (!colors) return [];
    const q = query.trim().toLowerCase();
    return q ? colors.filter((c) => c.name.toLowerCase().includes(q) || c.number.includes(q)) : colors;
  }, [colors, query]);
  const shown = filtered.slice(0, 100);
  const libraryNames = useMemo(() => new Set(library.map((c) => c.name)), [library]);
  const notYetAdded = useMemo(() => filtered.filter((c) => !libraryNames.has(nameFor(c))), [filtered, libraryNames, line]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <div className="catalog-browser">
      {supplier.catalogs.length > 1 && (
        <div className="chip-row">
          {supplier.catalogs.map((c, i) => (
            <button key={c.file} type="button" className={"chip" + (i === lineIndex ? " on" : "")} onClick={() => setLineIndex(i)}>{c.label}</button>
          ))}
        </div>
      )}
      <div className="row-inline">
        <input className="catalog-search" placeholder={`Search ${colors ? colors.length.toLocaleString() : "…"} ${supplier.name} colours by name or number…`}
          value={query} onChange={(e) => setQuery(e.target.value)} />
        {colors && (
          <button type="button" className="btn small" disabled={notYetAdded.length === 0}
            onClick={() => onAddMany(notYetAdded.map((c) => ({ name: nameFor(c), rgb: { r: c.r, g: c.g, b: c.b } })))}>
            {notYetAdded.length === 0 ? "All added" : `Add all${query ? " matching" : ""} (${notYetAdded.length.toLocaleString()})`}
          </button>
        )}
      </div>
      {error && <div className="error-text">{error}</div>}
      {!colors && !error && <p className="hint">Loading catalog…</p>}
      {colors && (
        <ul className="catalog-list">
          {shown.map((c) => {
            const colorName = nameFor(c);
            const added = libraryNames.has(colorName);
            return (
              <li key={c.number + c.name} className={added ? "added" : undefined}>
                <span className="swatch" style={{ background: `rgb(${c.r},${c.g},${c.b})` }} />
                <span className="catalog-name">{c.name}{c.number && <span className="muted"> · {c.number}</span>}</span>
                {added
                  ? <span className="added-check" title="Already in your thread library">✓</span>
                  : <button type="button" className="icon-btn" title="Add to my thread library" onClick={() => onAdd(colorName, { r: c.r, g: c.g, b: c.b })}>+</button>}
              </li>
            );
          })}
          {filtered.length > shown.length && <li className="hint">Showing the first {shown.length} of {filtered.length.toLocaleString()} matches — keep typing to narrow it down.</li>}
          {query && filtered.length === 0 && <li className="hint">No colours match "{query}".</li>}
        </ul>
      )}
    </div>
  );
}

export function ThreadLibraryEditor({ library, onChange, suppliers, onSuppliersChange }: {
  library: ThreadColor[]; onChange: (lib: ThreadColor[]) => void;
  suppliers: string[]; onSuppliersChange: (ids: string[]) => void;
}) {
  const [name, setName] = useState("");
  const [hex, setHex] = useState("#c0392b");
  const [browsing, setBrowsing] = useState<string | null>(null);
  const addColors = (items: { name: string; rgb: RGBColor }[]) => {
    const existing = new Set(library.map((c) => c.name));
    const additions = items.filter((it) => !existing.has(it.name)).map((it) => ({ id: crypto.randomUUID(), name: it.name, rgb: it.rgb }));
    if (additions.length === 0) return;
    onChange([...library, ...additions]);
  };
  const addColor = (colorName: string, rgb: RGBColor) => addColors([{ name: colorName, rgb }]);
  const add = () => { if (!name.trim()) return; addColor(name.trim(), hexRGB(hex)); setName(""); };
  const toggleSupplier = (id: string) => {
    const next = suppliers.includes(id) ? suppliers.filter((s) => s !== id) : [...suppliers, id];
    onSuppliersChange(next);
    if (!next.includes(browsing ?? "")) setBrowsing(next.includes(id) ? id : null);
  };
  const selectedSuppliers = THREAD_SUPPLIERS.filter((s) => suppliers.includes(s.id));
  const browsingSupplier = selectedSuppliers.find((s) => s.id === browsing) ?? null;
  return (
    <div className="stack">
      <div>
        <p className="hint">Which thread manufacturer(s) do you sew with? Most jobs use just one or two — pick one to browse its catalog and pull in the specific shades you stock.</p>
        <div className="chip-row">
          {THREAD_SUPPLIERS.map((s) => (
            <button key={s.id} type="button" className={"chip" + (suppliers.includes(s.id) ? " on" : "")} onClick={() => toggleSupplier(s.id)}>{s.name}</button>
          ))}
        </div>
        {selectedSuppliers.length > 0 && (
          <div className="supplier-notes">
            {selectedSuppliers.map((s) => (
              <div key={s.id} className="supplier-note">
                <div className="row-inline">
                  <b>{s.name}</b> <span className="muted">· {s.lines}</span> <span className="grow" />
                  <button type="button" className="btn small" onClick={() => setBrowsing(browsing === s.id ? null : s.id)}>
                    {browsing === s.id ? "Hide catalog" : "Browse catalog"}
                  </button>
                </div>
                <p>{s.guidance}</p>
              </div>
            ))}
          </div>
        )}
        {browsingSupplier && <ThreadCatalogBrowser supplier={browsingSupplier} library={library} onAdd={addColor} onAddMany={addColors} />}
      </div>
      <p className="hint">Your own thread inventory. When it has colours, imports and the colour pickers match against <b>only</b> these instead of the built-in palette. Leave it empty to use the built-in palette. Pull colours from a catalog above, or add your own by eye or against a physical color card.</p>
      <ul className="merge-list">
        {library.map((c) => <li key={c.id}><span className="swatch" style={{ background: rgbCSS(c.rgb) }} /> {c.name} <span className="grow" /><button className="icon-btn" title="Remove" onClick={() => onChange(library.filter((x) => x.id !== c.id))}>×</button></li>)}
        {library.length === 0 && <li className="hint">No custom colours yet — using the built-in palette.</li>}
      </ul>
      <div className="row-inline"><input type="color" value={hex} onChange={(e) => setHex(e.target.value)} /><input placeholder="Thread name, e.g. Madeira 1147 Red" value={name} onChange={(e) => setName(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter") add(); }} /><button className="btn small" onClick={add} disabled={!name.trim()}>Add</button></div>
    </div>
  );
}

export function ThreadLibrarySheet({ library, onChange, suppliers, onSuppliersChange, onClose }: {
  library: ThreadColor[]; onChange: (lib: ThreadColor[]) => void; suppliers: string[]; onSuppliersChange: (ids: string[]) => void; onClose: () => void;
}) {
  return <Modal title="Thread library" onClose={onClose}><ThreadLibraryEditor library={library} onChange={onChange} suppliers={suppliers} onSuppliersChange={onSuppliersChange} /><div className="modal-foot"><button className="btn primary" onClick={onClose}>Done</button></div></Modal>;
}

// --- Send Feedback ----------------------------------------------------------------

export function FeedbackSheet({ originalImage, digitizedImage, designName, stitchCount, onClose, onSend }: {
  originalImage: string | null; digitizedImage: string; designName: string; stitchCount: number;
  onClose: () => void; onSend: (note: string) => Promise<void>;
}) {
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const send = async () => {
    setBusy(true); setError(null);
    try { await onSend(note); setSent(true); }
    catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); }
  };

  if (sent) {
    return (
      <Modal title="Feedback sent" onClose={onClose}>
        <p>Thanks — we've got both images and will take a look. You'll get an email confirming that, and another if we use it to make a change.</p>
        <div className="modal-foot"><button className="btn primary" onClick={onClose}>Done</button></div>
      </Modal>
    );
  }

  return (
    <Modal title="Send feedback" onClose={onClose}>
      <p className="hint">Sends PiperStitch's team the original artwork and a picture of the digitized result — not the embroidery file itself — so we can see where the automatic digitizing did well or poorly and make it better. "{designName}" · {stitchCount.toLocaleString()} stitches.</p>
      <div className="feedback-previews">
        <div>
          <div className="feedback-preview-label">Original artwork</div>
          {originalImage ? <img src={originalImage} alt="Original artwork" /> : <div className="feedback-preview-missing">No separate original to show (this design was made from a font)</div>}
        </div>
        <div>
          <div className="feedback-preview-label">Digitized result</div>
          <img src={digitizedImage} alt="Digitized result" />
        </div>
      </div>
      <label htmlFor="feedback-note">What looked wrong? (optional)</label>
      <textarea id="feedback-note" rows={3} placeholder="e.g. the satin on the O looks lumpy, the colors didn't carry over…" value={note} onChange={(e) => setNote(e.target.value)} disabled={busy} />
      {error && <div className="error-text">{error}</div>}
      <div className="modal-foot">
        <button className="btn ghost" onClick={onClose} disabled={busy}>Cancel</button>
        <button className="btn primary" onClick={send} disabled={busy}>{busy ? "Sending…" : "Send feedback"}</button>
      </div>
    </Modal>
  );
}

// --- Send a file --------------------------------------------------------------------

export function SendSheet({ designName, onClose, onSend }: { designName: string; onClose: () => void; onSend: (format: string, toEmail: string, message: string) => Promise<void> }) {
  const [to, setTo] = useState("");
  const [format, setFormat] = useState("dst");
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);
  const formats: [string, string][] = [["dst", "Tajima (.dst) — most machines"], ["pes", "Brother / Baby Lock (.pes)"], ["jef", "Janome (.jef)"], ["exp", "Melco / Bernina (.exp)"], ["vp3", "Husqvarna Viking / Pfaff (.vp3)"]];
  const submit = async () => {
    setBusy(true); setError(null);
    try { await onSend(format, to, message); setDone(true); }
    catch (e) { setError(e instanceof Error ? e.message : String(e)); } finally { setBusy(false); }
  };
  return (
    <Modal title="Send the embroidery file" onClose={onClose}>
      {done ? (
        <>
          <p>Sent <b>{designName}.{format}</b> to <b>{to}</b>. They'll get it from hello@piperstitch.com with you as the reply-to.</p>
          <div className="modal-foot"><button className="btn primary" onClick={onClose}>Done</button></div>
        </>
      ) : (
        <>
          <p className="hint">Emails the finished machine file to a customer, a colleague, or yourself — the same file the Download button gives you.</p>
          <label className="field">Send to<input type="email" autoFocus value={to} onChange={(e) => setTo(e.target.value)} placeholder="name@example.com" /></label>
          <label className="field">Machine format<select value={format} onChange={(e) => setFormat(e.target.value)}>{formats.map(([id, label]) => <option key={id} value={id}>{label}</option>)}</select></label>
          <label className="field">Note (optional)<textarea rows={3} value={message} onChange={(e) => setMessage(e.target.value)} placeholder="Here's the logo we talked about — 10 × 10 cm for a 4×4 hoop." /></label>
          {error && <div className="error-text">{error}</div>}
          <div className="modal-foot"><button className="btn ghost" onClick={onClose}>Cancel</button><button className="btn primary" disabled={busy || !to.includes("@")} onClick={submit}>{busy ? "Sending…" : "Send"}</button></div>
        </>
      )}
    </Modal>
  );
}

// --- Settings ---------------------------------------------------------------------

export function SettingsSheet({ catalog, prefs, account, onPrefs, onClose, onSignOut, onRefreshAccount, onAccount }: {
  catalog: Catalog; prefs: Preferences; account: AccountState | null; onPrefs: (p: Preferences) => void; onClose: () => void; onSignOut: () => void; onRefreshAccount: () => void;
  onAccount: (a: AccountState) => void;
}) {
  const [error, setError] = useState<string | null>(null);
  const [name, setName] = useState(account?.name ?? "");
  const [savingName, setSavingName] = useState(false);
  const saveName = async () => {
    setSavingName(true); setError(null);
    try { const me = await api.updateName(name); if (me.account) onAccount(me.account); }
    catch (e) { setError(e instanceof Error ? e.message : String(e)); } finally { setSavingName(false); }
  };
  const [tab, setTab] = useState<"account" | "preferences" | "threads">(account ? "account" : "preferences");
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
          <div className="kv"><span>Your name</span><span className="row-inline"><input value={name} onChange={(e) => setName(e.target.value)} placeholder="Shown on files you send" style={{ minWidth: 200 }} />
            <button className="btn small" disabled={savingName || !name.trim() || name.trim() === account.name} onClick={saveName}>{savingName ? "Saving…" : "Save"}</button></span></div>
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
      {tab === "threads" && <ThreadLibraryEditor library={prefs.threadLibrary} onChange={(lib) => set("threadLibrary", lib)} suppliers={prefs.threadSuppliers} onSuppliersChange={(ids) => set("threadSuppliers", ids)} />}
      <div className="modal-foot"><button className="btn primary" onClick={onClose}>Done</button></div>
    </Modal>
  );
}

export { AccountMenu };
