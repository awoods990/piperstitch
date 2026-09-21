// Guided setup for a new account: which product(s) they're here for, who
// the business is, the machines and hoops they own, their thread stock,
// and the defaults every design starts from -- so both apps open already
// configured for them. Same card, dots and Next-in-one-place pattern as
// the per-design SetupFlow, so it reads as the same product.
//
// Everything it collects lands in `Preferences` (prefs.ts), which the app
// mirrors to the account; PiperStitch Proofs reads the same record
// (`business`, `proofsDefaults`). Nothing here is required: every step
// can be skipped, and Settings can change any of it or run this again.

import { useEffect, useMemo, useRef, useState } from "react";
import GetPiper from "./GetPiper";
import { api } from "../api";
import type { AccountState, Catalog, ColorPresetId, FabricType, ThreadColor } from "../types";
import type { Preferences, Units } from "../prefs";
import { hoopGroups } from "../hoops";
import { size } from "../format";
import { Choice } from "./SetupFlow";
import { ThreadLibraryEditor } from "./Sheets";
import {
  BUSINESS_TYPES, EXPORT_FORMAT_LABELS, MACHINE_BRANDS, ONBOARDING_VERSION, type Product, type StepId,
  anyCommercial, defaultFormat, estimateMinutes, stepsFor, suggestedHoops,
} from "../onboarding";
import { headlineTips } from "../gettingStarted";

interface Props {
  account: AccountState | null;
  catalog: Catalog;
  prefs: Preferences;
  onPrefs: (p: Preferences) => void;
  /** Jump straight in (records the skip so this isn't shown again). */
  onSkip: () => void;
  /** Finished the guided flow. */
  onDone: (products: Product[]) => void;
  /** Re-running from Settings: no welcome screen, back out to the app. */
  rerun?: boolean;
  onCancel?: () => void;
  /** Signed out and starting a free trial: the account is created inside
   *  the flow (email, then the emailed code). `verifyCode` resolves once the
   *  app is signed in and the account's preferences have been pulled. */
  signUp?: { requestCode: (email: string) => Promise<void>; verifyCode: (email: string, code: string) => Promise<void> };
  /** Where "Already a member? Sign in" goes. */
  onSignInInstead?: () => void;
  /** Arrived from the sign-up email's link: skip the welcome, land on the
   *  code step with both filled in, verify automatically. */
  signUpLink?: { email: string; code: string } | null;
}

const TITLES: Record<StepId, string> = {
  account: "First, your email",
  products: "One account, the whole workflow",
  business: "Tell us about your business",
  machine: "What do you sew on?",
  hoops: "Which hoops do you have?",
  threads: "Your thread library",
  defaults: "How you like to work",
  proofs: "Sending proofs to customers",
  tips: "Three things worth knowing",
  done: "",
};

/** Forty pieces of CSS confetti, positions and timing fixed so the screen
 *  renders the same every time; the animation itself runs once. */
/** The finish: Piper lands, spins and lets off fireworks -- the closing
 *  shot of the PiperStitch introduction video, cut out with its
 *  background keyed to transparent (`public/setup-finale.webp`, 40
 *  frames, plays once). Falls back to the last frame as a still when
 *  the browser can't animate WebP or the person prefers reduced motion. */
function FinalePiper() {
  const reduced = typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
  // A new element each mount so the once-only animation starts from
  // frame 0 every time the finish screen appears.
  const [nonce] = useState(() => Date.now());
  return (
    <img src={reduced ? "/setup-finale.png" : `/setup-finale.webp?t=${nonce}`} alt="" width={240} height={240} className="done-finale" draggable={false} />
  );
}

const CONFETTI = Array.from({ length: 40 }, (_, i) => {
  const r = (n: number) => ((Math.sin(i * 12.9898 + n * 78.233) * 43758.5453) % 1 + 1) % 1;
  const colors = ["#1a6fd1", "#c0722a", "#2f6b41", "#e0b13b", "#a3312a", "#3b8ee6"];
  return { left: `${r(1) * 100}%`, delay: `${r(2) * 1.2}s`, duration: `${2.2 + r(3) * 1.6}s`, color: colors[i % colors.length], rotate: `${r(4) * 360}deg`, size: 6 + Math.round(r(5) * 6) };
});

export default function Onboarding(props: Props) {
  const { account, catalog, prefs } = props;
  const [welcome, setWelcome] = useState(!props.rerun && !props.signUpLink);
  const [products, setProducts] = useState<Product[]>(prefs.onboarding?.products ?? ["core", "proofs"]);
  // Creating the account is the first step when the visitor arrived signed
  // out; it stays in the step count after they're in, so "Step 2 of 6"
  // doesn't turn into "Step 1 of 5" the moment the code is accepted.
  const [startedSignedOut] = useState(!!props.signUp && !account);
  const needsAccount = startedSignedOut && !account;
  const steps = useMemo(() => stepsFor(products, startedSignedOut), [products, startedSignedOut]);
  const [step, setStep] = useState<StepId>(needsAccount ? "account" : "products");
  // "Jump right in" chosen before the account existed: finish right after the code.
  const [jumpAfterSignUp, setJumpAfterSignUp] = useState(false);
  const [email, setEmail] = useState(props.signUpLink?.email ?? "");
  const [code, setCode] = useState(props.signUpLink?.code ?? "");
  const [codeSent, setCodeSent] = useState(!!props.signUpLink);
  const autoVerified = useRef(false);
  const latestPrefs = useRef(prefs);
  latestPrefs.current = prefs;
  const stepIndex = Math.max(0, steps.indexOf(step));
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [moreHoops, setMoreHoops] = useState(false);
  const [moreContact, setMoreContact] = useState(false);
  const bodyRef = useRef<HTMLDivElement>(null);
  useEffect(() => { bodyRef.current?.scrollTo(0, 0); }, [step]);

  // The working copy: written through to preferences on every Next, so
  // closing the tab halfway loses nothing already answered.
  const [draft, setDraft] = useState<Preferences>(prefs);
  const set = <K extends keyof Preferences>(key: K, value: Preferences[K]) => setDraft((d) => ({ ...d, [key]: value }));
  const setBusiness = (patch: Partial<Preferences["business"]>) => setDraft((d) => ({ ...d, business: { ...d.business, ...patch } }));
  const setProofs = (patch: Partial<Preferences["proofsDefaults"]>) => setDraft((d) => ({ ...d, proofsDefaults: { ...d.proofsDefaults, ...patch } }));

  // Sensible starting points from the account.
  useEffect(() => {
    setDraft((d) => ({
      ...d,
      business: { ...d.business, contactName: d.business.contactName || account?.name || "" },
      proofsDefaults: { ...d.proofsDefaults, replyTo: d.proofsDefaults.replyTo || account?.email || "" },
    }));
  }, [account?.name, account?.email]);

  const hoopNames = catalog.hoops.map((h) => h.name);
  const suggested = useMemo(() => suggestedHoops(draft.business.machineBrands, hoopNames), [draft.business.machineBrands, hoopNames.join("|")]); // eslint-disable-line react-hooks/exhaustive-deps

  const commit = (next: Preferences) => { setDraft(next); props.onPrefs(next); };

  const goNext = async () => {
    setError(null);
    let next = { ...draft };
    if (step === "machine") {
      // Their machines decide the file format and the starting hoop list.
      next.defaultExportFormat = defaultFormat(next.business.machineBrands);
      if (next.ownedHoopNames.length === 0) next.ownedHoopNames = suggestedHoops(next.business.machineBrands, hoopNames);
    }
    if (step === "business") {
      // One question, asked once: the business name IS the shop name on proofs.
      next.proofsDefaults = { ...next.proofsDefaults, shopName: next.business.name };
      // The account's own name is what goes on files they send.
      const contact = next.business.contactName.trim();
      if (account && contact && contact !== account.name) {
        setSaving(true);
        try { await api.updateName(contact); } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
        finally { setSaving(false); }
      }
    }
    if (step === "hoops") {
      if (next.defaultHoopName && !next.ownedHoopNames.includes(next.defaultHoopName)) next.defaultHoopName = next.ownedHoopNames[0] ?? next.defaultHoopName;
    }
    const nextStep = steps[stepIndex + 1];
    if (nextStep === "done") {
      next.onboarding = { version: ONBOARDING_VERSION, completedAt: new Date().toISOString(), skippedAt: null, products };
    }
    commit(next);
    setStep(nextStep);
  };
  const goBack = () => setStep(steps[Math.max(0, stepIndex - 1)]);

  const skipAll = () => {
    if (needsAccount) { setJumpAfterSignUp(true); setWelcome(false); setStep("account"); return; }
    commit({ ...draft, onboarding: { version: ONBOARDING_VERSION, completedAt: null, skippedAt: new Date().toISOString(), products } });
    props.onSkip();
  };

  // The account step: request the code, then verify it. Once verified the
  // app is signed in and has pulled the account's preferences, so the
  // draft is re-seeded from them (an existing member using the trial door
  // keeps their business, hoops and threads).
  const requestCode = async () => {
    setSaving(true); setError(null);
    try { await props.signUp!.requestCode(email.trim()); setCodeSent(true); }
    catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setSaving(false); }
  };
  const verifyCode = async (emailToUse = email, codeToUse = code) => {
    setSaving(true); setError(null);
    try {
      await props.signUp!.verifyCode(emailToUse.trim(), codeToUse.trim());
      // Let React commit the pulled preferences before reading them.
      await new Promise((r) => setTimeout(r, 0));
      const fresh = latestPrefs.current;
      setDraft(fresh);
      if (jumpAfterSignUp) {
        commit({ ...fresh, onboarding: { version: ONBOARDING_VERSION, completedAt: null, skippedAt: new Date().toISOString(), products } });
        props.onSkip();
        return;
      }
      setStep("products");
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setSaving(false); }
  };

  // PiperStitch is the base subscription; Proofs is an add-on to it.
  const setWithProofs = (on: boolean) => setProducts(on ? ["core", "proofs"] : ["core"]);
  // The email link: verify as soon as the flow is on screen. A wrong or
  // expired code just shows the code step with the email filled in.
  useEffect(() => {
    if (props.signUpLink && needsAccount && !autoVerified.current) {
      autoVerified.current = true;
      verifyCode(props.signUpLink.email, props.signUpLink.code);
    }
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const toggleBrand = (id: string) => {
    const cur = draft.business.machineBrands;
    setBusiness({ machineBrands: cur.includes(id) ? cur.filter((b) => b !== id) : [...cur, id] });
    set("ownedHoopNames", []); // re-suggest from the new brand list on Next
  };
  const toggleHoop = (name: string) => set("ownedHoopNames", draft.ownedHoopNames.includes(name) ? draft.ownedHoopNames.filter((h) => h !== name) : [...draft.ownedHoopNames, name]);

  const proofsFree = account?.proofs?.free_granted ?? 3;
  const trialDays = account?.trial_days ?? 14;

  if (welcome) {
    return (
      <div className="setup onboarding">
        <div className="setup-card welcome-card">
          <div className="welcome-brand">
            <img src="/icon.png" alt="" width={56} height={56} />
            <h2>{needsAccount ? "Welcome — let's start your free trial" : `Welcome to PiperStitch${account?.name ? `, ${account.name.split(" ")[0]}` : ""}`}</h2>
            <p className="setup-sub">{needsAccount
              ? `${trialDays} days of everything, no card needed. Your email is your account — we send a code, no password to remember. Then a few questions set PiperStitch up for your business, or skip them and set things up as you go.`
              : "A few questions and PiperStitch opens already set up for your business — machines, hoops, thread and defaults filled in, and Proofs too if you add it. Or skip this and set things up as you go."}</p>
          </div>
          <div className="choices two welcome-choices">
            <Choice title={`Set up PiperStitch for my business · about ${estimateMinutes(["core", "proofs"], needsAccount)} minutes`}
              subtitle="Recommended. Machines, hoops, thread library, defaults — and Proofs, if you'll use it." selected={false} onClick={() => setWelcome(false)} />
            <Choice title="Jump right in" subtitle={needsAccount ? "Just your email, then start with a design. Everything here is in Settings whenever you want it." : "Start with a design now. Everything here is in Settings whenever you want it."} selected={false} onClick={skipAll} />
          </div>
          <p className="hint welcome-foot">{needsAccount
            ? <>Already a member? <button type="button" className="linkish" onClick={props.onSignInInstead}>Sign in</button></>
            : <>Your {trialDays}-day free trial has started — no card needed. {account?.email && <>Signed in as {account.email}.</>}</>}</p>
        </div>
      </div>
    );
  }

  const subtitle: Record<StepId, string> = {
    account: codeSent ? (props.signUpLink && saving ? `Checking the code from your email…` : `We emailed a six-digit code to ${email.trim()}. It's good for 15 minutes — check spam if it's slow.`) : "No password: a fresh code is emailed each time you sign in. Your free trial starts as soon as you're in.",
    products: `Digitizing is included — ${trialDays} days free, no card. Most shops add Proofs: it's how the file you just made gets approved and paid for before it's sewn.`,
    business: "What customers see on the files and proofs you send.",
    machine: "Pick every brand you run. This sets the file format you download and the hoops you'll see first.",
    hoops: draft.business.machineBrands.length > 0 ? "Pre-ticked from your machines. Untick any you don't have and add the rest — these show first everywhere." : "Tick the hoops you own — these show first everywhere.",
    threads: "The colours you actually stock. Imports match against your library instead of a generic palette.",
    defaults: "Where every new design starts. All of it can be changed per design.",
    proofs: `Proofs go out as ${draft.business.name || "your business"}${draft.business.phone ? ` · ${draft.business.phone}` : ""}. Three more things, then Proofs is ready to use.`,
    tips: "Half a minute now saves a wasted hoop later. The full guide is always under Help.",
    done: "",
  };

  return (
    <div className="setup onboarding">
      <div className="setup-card">
        <header className="setup-head">
          <div>
            <div className="setup-kicker">Guided setup</div>
            <div className="setup-file">{step === "done" ? "Done" : `About ${estimateMinutes(products)} minutes · ${Math.max(0, Math.round(estimateMinutes(products) * (1 - stepIndex / (steps.length - 1))))} to go`}</div>
          </div>
          <div className="setup-dots" aria-hidden>
            {steps.map((s, i) => <span key={s} className={"dot" + (i <= stepIndex ? " on" : "") + (s === step ? " cur" : "")} />)}
          </div>
        </header>

        <h2>{step === "tips" ? `${products.includes("proofs") ? "Four" : "Three"} things worth knowing` : TITLES[step]}</h2>
        {subtitle[step] && <p className="setup-sub">{subtitle[step]}</p>}

        <div className="setup-body" ref={bodyRef}>
          {step === "account" && (
            <form className="stack form-grid account-step" onSubmit={(e) => { e.preventDefault(); if (codeSent) verifyCode(); else requestCode(); }}>
              {!codeSent ? (
                <label className="field">Email address
                  <input type="email" required autoFocus autoComplete="email" placeholder="you@example.com" value={email} onChange={(e) => setEmail(e.target.value)} />
                </label>
              ) : (
                <>
                  <label className="field">Sign-in code
                    <input inputMode="numeric" pattern="[0-9]*" maxLength={6} required autoFocus autoComplete="one-time-code" placeholder="123456" className="code" value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))} />
                  </label>
                  <div className="row-inline">
                    <button type="button" className="btn ghost small" disabled={saving} onClick={requestCode}>Resend code</button>
                    <button type="button" className="btn ghost small" disabled={saving} onClick={() => { setCodeSent(false); setCode(""); setError(null); }}>Use a different email</button>
                  </div>
                </>
              )}
              <p className="hint">By continuing you accept the <a href="https://www.piperstitch.com/terms.html" target="_blank" rel="noopener">Terms</a> and <a href="https://www.piperstitch.com/privacy-policy.html" target="_blank" rel="noopener">Privacy Policy</a>.</p>
              <button type="submit" hidden aria-hidden="true" />
            </form>
          )}

          {step === "products" && (
            <div className="stack">
              <div className="workflow" aria-hidden="true">
                <span className="wf-step"><b>1</b>Digitize the artwork</span><span className="wf-arrow">→</span>
                <span className="wf-step proofs"><b>2</b>Send a proof</span><span className="wf-arrow">→</span>
                <span className="wf-step proofs"><b>3</b>Customer approves on their phone</span><span className="wf-arrow">→</span>
                <span className="wf-step"><b>4</b>Sew it, signed off</span>
              </div>
              <div className="choices two">
                <Choice title="PiperStitch + Proofs" subtitle={`Steps 1–4. A stitch-accurate proof your customer approves on their phone — with the thread colours, size and placement — plus reminders and a signed approval record. First ${proofsFree} proofs free, then billed on the same card.`}
                  selected={products.includes("proofs")} onClick={() => setWithProofs(true)} />
                <Choice title="Just PiperStitch for now" subtitle="Step 1 only: turn artwork into stitch files and download them. You can add Proofs any time from Settings."
                  selected={!products.includes("proofs")} onClick={() => setWithProofs(false)} />
              </div>
            </div>
          )}

          {step === "business" && (
            <div className="stack">
              <div className="two-up">
                <label className="field">Business name
                  <input value={draft.business.name} autoFocus placeholder="Piper's Custom Embroidery" onChange={(e) => setBusiness({ name: e.target.value })} />
                </label>
                <label className="field">Your name
                  <input value={draft.business.contactName} placeholder="Shown on files you send" onChange={(e) => setBusiness({ contactName: e.target.value })} />
                </label>
              </div>
              <div>
                <div className="section-label">Which sounds most like you?</div>
                <div className="choices">
                  {BUSINESS_TYPES.map((t) => <Choice key={t.id} title={t.name} subtitle={t.hint} selected={draft.business.type === t.id} onClick={() => setBusiness({ type: t.id })} />)}
                </div>
              </div>
              {!moreContact ? (
                <button type="button" className="btn ghost more" onClick={() => setMoreContact(true)}>Add phone, website or location — optional ▾</button>
              ) : (
                <div className="three-up">
                  <label className="field">Phone<input value={draft.business.phone} inputMode="tel" onChange={(e) => setBusiness({ phone: e.target.value })} /></label>
                  <label className="field">Website<input value={draft.business.website} inputMode="url" placeholder="example.com" onChange={(e) => setBusiness({ website: e.target.value })} /></label>
                  <label className="field">City / region<input value={draft.business.city} onChange={(e) => setBusiness({ city: e.target.value })} /></label>
                </div>
              )}
            </div>
          )}

          {step === "machine" && (
            <div className="stack">
              <div className="choices brands">
                {MACHINE_BRANDS.map((m) => <Choice key={m.id} title={m.name} subtitle={m.formatLabel} selected={draft.business.machineBrands.includes(m.id)} onClick={() => toggleBrand(m.id)} />)}
              </div>
              {draft.business.machineBrands.length > 0 && (
                <p className="hint">Files will download as <b>{EXPORT_FORMAT_LABELS[defaultFormat(draft.business.machineBrands)]}</b> — every other format stays one click away.</p>
              )}
              <input className="notes" value={draft.business.machineNotes} placeholder="Model(s), if you like — e.g. PR1055X, 15-needle (optional)" onChange={(e) => setBusiness({ machineNotes: e.target.value })} />
            </div>
          )}

          {step === "hoops" && (
            <div className="stack">
              {draft.ownedHoopNames.length > 0 && (
                <label className="row">Default hoop for new designs
                  <select value={draft.ownedHoopNames.includes(draft.defaultHoopName ?? "") ? draft.defaultHoopName ?? "" : draft.ownedHoopNames[0]} onChange={(e) => set("defaultHoopName", e.target.value)}>
                    {draft.ownedHoopNames.map((n) => <option key={n} value={n}>{n}</option>)}
                  </select>
                </label>
              )}
              {hoopGroups(catalog.hoops).map(([group, list], i) => (i === 0 || moreHoops || anyCommercial(draft.business.machineBrands)) && (
                <div key={group}>
                  <div className="section-label">{group}</div>
                  <div className="choices">
                    {list.map((h) => (
                      <Choice key={h.name} title={h.name.replace(/^(Mighty Hoop|Durkee EZ Frame) /, "")}
                        subtitle={size(h.widthMM, h.heightMM) + (suggested.includes(h.name) ? " · came with your machine" : "")}
                        selected={draft.ownedHoopNames.includes(h.name)} onClick={() => toggleHoop(h.name)} />
                    ))}
                  </div>
                </div>
              ))}
              {!moreHoops && !anyCommercial(draft.business.machineBrands) && (
                <button type="button" className="btn ghost more" onClick={() => setMoreHoops(true)}>More hoops &amp; frames — Mighty Hoop, Durkee EZ Frame ▾</button>
              )}
              {anyCommercial(draft.business.machineBrands) && <p className="hint">Mighty Hoop and Durkee sizes use the frame's sewing field, not its nominal size.</p>}
            </div>
          )}

          {step === "threads" && (
            <ThreadLibraryEditor library={draft.threadLibrary} onChange={(lib: ThreadColor[]) => set("threadLibrary", lib)}
              suppliers={draft.threadSuppliers} onSuppliersChange={(ids: string[]) => set("threadSuppliers", ids)} />
          )}

          {step === "defaults" && (
            <div className="stack">
              <label className="row">What you sew on most
                <select value={draft.defaultFabric} onChange={(e) => set("defaultFabric", e.target.value as FabricType)}>
                  {catalog.fabrics.map((f) => <option key={f.id} value={f.id}>{f.displayName}</option>)}
                </select>
              </label>
              <label className="row">Colour reduction
                <select value={draft.defaultColorPreset} onChange={(e) => set("defaultColorPreset", e.target.value as ColorPresetId)}>
                  {catalog.colorPresets.map((c) => <option key={c.id} value={c.id}>{c.id === "preserveArtwork" ? "Keep every colour" : c.id === "normalEmbroidery" ? "Normal embroidery (recommended)" : c.id === "productionEfficient" ? "Production efficient" : "As few as possible"}</option>)}
                </select>
              </label>
              <div>
                <div className="section-label">Measurements</div>
                <div className="choices two">
                  <Choice title="Centimetres" subtitle="10.2 × 10.2 cm" selected={draft.units === "cm"} onClick={() => set("units", "cm" as Units)} />
                  <Choice title="Inches" subtitle="4 × 4 in" selected={draft.units === "in"} onClick={() => set("units", "in" as Units)} />
                </div>
              </div>
              <label className="row">File format when you download
                <select value={draft.defaultExportFormat} onChange={(e) => set("defaultExportFormat", e.target.value as Preferences["defaultExportFormat"])}>
                  {(Object.keys(EXPORT_FORMAT_LABELS) as (keyof typeof EXPORT_FORMAT_LABELS)[]).map((f) => <option key={f} value={f}>{EXPORT_FORMAT_LABELS[f]}</option>)}
                </select>
              </label>
              <label className="check"><input type="checkbox" checked={draft.matchToThreadLibrary} onChange={(e) => set("matchToThreadLibrary", e.target.checked)} /> Match imported colours to my thread library</label>
            </div>
          )}

          {step === "proofs" && (
            <div className="stack form-grid">
              <div className="two-up">
                <label className="field">Customer replies go to
                  <input type="email" value={draft.proofsDefaults.replyTo} placeholder={account?.email ?? "you@yourshop.com"} onChange={(e) => setProofs({ replyTo: e.target.value })} />
                </label>
                <label className="row">Days a customer has to respond
                  <select value={draft.proofsDefaults.responseWindowDays} onChange={(e) => setProofs({ responseWindowDays: Number(e.target.value) })}>
                    {[2, 3, 5, 7, 10, 14].map((d) => <option key={d} value={d}>{d} days</option>)}
                  </select>
                </label>
              </div>
              <label className="row">Reminders
                <select value={draft.proofsDefaults.remindersEnabled ? "yes" : "no"} onChange={(e) => setProofs({ remindersEnabled: e.target.value === "yes" })}>
                  <option value="yes">On — chase the customer for me</option>
                  <option value="no">Off — I'll follow up myself</option>
                </select>
              </label>
              <div>
                <div className="section-label">Machine files before approval</div>
                <div className="choices">
                  <Choice title="Downloadable, stamped unapproved" subtitle="Recommended — you can prep, but it's marked until the customer approves." selected={draft.proofsDefaults.releaseGate === "soft"} onClick={() => setProofs({ releaseGate: "soft" })} />
                  <Choice title="Withheld until approved" subtitle="Nothing goes to the machine before sign-off." selected={draft.proofsDefaults.releaseGate === "hard"} onClick={() => setProofs({ releaseGate: "hard" })} />
                  <Choice title="No restriction" subtitle="Files are available whenever." selected={draft.proofsDefaults.releaseGate === "off"} onClick={() => setProofs({ releaseGate: "off" })} />
                </div>
              </div>
              <p className="hint">Your first {proofsFree} proofs are free; after that Proofs is billed on the same card as PiperStitch. Nothing is charged until you subscribe. Add your logo and approval terms in Proofs' settings.</p>
            </div>
          )}

          {step === "tips" && (
            <div className={"tip-cards" + (products.includes("proofs") ? " four" : "")}>
              {headlineTips(products.includes("proofs")).map((t, i) => (
                <div key={t.title} className="tip-card">
                  <span className="tip-num">{i + 1}</span>
                  <b>{t.title}</b>
                  <p>{t.short}</p>
                </div>
              ))}
            </div>
          )}

          {step === "done" && (
            <div className="stack done">
              <div className="celebrate" aria-hidden="true">
                {CONFETTI.map((c, i) => <span key={i} className="confetti" style={{ left: c.left, animationDelay: c.delay, animationDuration: c.duration, background: c.color, width: c.size, height: c.size * 0.6, transform: `rotate(${c.rotate})` }} />)}
              </div>
              <div className="done-hero tall">
                <FinalePiper />
                <h2 className="done-title">Congratulations{account?.name ? `, ${account.name.split(" ")[0]}` : ""} — you're ready to digitize!</h2>
                <p className="setup-sub">PiperStitch{products.includes("proofs") ? " and Proofs are" : " is"} set up for {draft.business.name || "your business"}. Drop in your first logo and it'll be stitch-ready in under a minute.</p>
                <p className="hint">Everything you chose lives under <b>Settings</b>; the guide is under <b>Help</b>.</p>
              </div>
              <GetPiper compact />
            </div>
          )}
          {error && <div className="error-text">{error}</div>}
        </div>

        <footer className="setup-foot">
          {step !== "done" && step !== "account" && step !== "tips" && <button className="btn ghost" onClick={props.rerun && props.onCancel ? props.onCancel : skipAll} disabled={saving}>{props.rerun ? "Cancel" : "Skip setup"}</button>}
          {step === "account" && <button className="btn ghost" onClick={props.onSignInInstead} disabled={saving}>Already a member? Sign in</button>}
          <div className="grow" />
          {stepIndex > 0 && step !== "done" && steps[stepIndex - 1] !== "account" && <button className="btn ghost" onClick={goBack} disabled={saving}>Back</button>}
          {step !== "done" && <span className="step-count">Step {stepIndex + 1} of {steps.length - 1}</span>}
          {step === "done" ? (
            <>
              {products.includes("proofs") && <button className="btn" onClick={() => api.proofsHandoffURL().then((u) => window.location.assign(u)).catch((e) => setError(e instanceof Error ? e.message : String(e)))}>Open Proofs ↗</button>}
              <button className="btn primary big" onClick={() => props.onDone(products)}>Start digitizing →</button>
            </>
          ) : step === "account" ? (
            codeSent
              ? <button className="btn primary" onClick={() => verifyCode()} disabled={saving || code.length !== 6}>{saving ? "Checking…" : jumpAfterSignUp ? "Start digitizing →" : "Continue"}</button>
              : <button className="btn primary" onClick={requestCode} disabled={saving || !email.includes("@")}>{saving ? "Sending…" : "Email me a code"}</button>
          ) : (
            <button className="btn primary" onClick={goNext} disabled={saving}>{saving ? "Saving…" : steps[stepIndex + 1] === "done" ? "Got it" : "Next"}</button>
          )}
        </footer>
      </div>
    </div>
  );
}
