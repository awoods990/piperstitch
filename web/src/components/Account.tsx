// Sign-in, the subscribe wall, and the account menu. The server decides
// everything (see server/Sources/StitchPilotServer/Auth.swift); these
// only show its answers and send the two sign-in requests.

import { useEffect, useRef, useState } from "react";
import { api } from "../api";
import type { AccountState, PromoValidation } from "../types";

export function daysLeft(account: AccountState): number | null {
  const end = account.valid_until ?? account.period_end;
  if (!end) return null;
  return Math.max(0, Math.ceil((new Date(end).getTime() - Date.now()) / 86_400_000));
}

export function price(account: AccountState): string {
  const v = account.price_cents / 100;
  return `$${Number.isInteger(v) ? v.toFixed(0) : v.toFixed(2)}/month`;
}

export function statusLine(account: AccountState): string {
  const d = daysLeft(account);
  switch (account.status) {
    case "trialing": return d === null ? "Free trial" : d === 0 ? "Free trial ends today" : `Free trial · ${d} day${d === 1 ? "" : "s"} left`;
    case "active": return account.cancel_at_period_end ? `Subscribed · ends ${fmt(account.period_end)}` : `Subscribed · renews ${fmt(account.period_end)}`;
    case "past_due": return "Payment problem · update your card";
    case "comp": return `Complimentary access · through ${fmt(account.period_end)}`;
    case "ended": return "Subscription ended";
    default: return "No subscription";
  }
}

const fmt = (iso: string | null) => iso ? new Date(iso).toLocaleDateString(undefined, { month: "short", day: "numeric" }) : "";

// --- promo codes -----------------------------------------------------------------

const PROMO_KEY = "piperstitch.promo";

/** A code from a promoter's link (?promo=CODE) is remembered until it's used. */
export function capturePromoFromURL() {
  const code = new URLSearchParams(window.location.search).get("promo")?.trim().toUpperCase();
  if (code) { try { localStorage.setItem(PROMO_KEY, code); } catch { /* ignore */ } }
}
export const rememberedPromo = () => { try { return localStorage.getItem(PROMO_KEY) ?? ""; } catch { return ""; } };
export const forgetPromo = () => { try { localStorage.removeItem(PROMO_KEY); } catch { /* ignore */ } };

/** Code entry with live validation; reports the accepted code upward. */
export function PromoBox({ onChange }: { onChange: (code: string | null, description: string | null) => void }) {
  const [code, setCode] = useState(rememberedPromo());
  const [result, setResult] = useState<PromoValidation | null>(null);
  const [busy, setBusy] = useState(false);
  const check = async (value: string) => {
    const c = value.trim().toUpperCase();
    if (!c) { setResult(null); onChange(null, null); return; }
    setBusy(true);
    try {
      const r = await api.validatePromo(c);
      setResult(r);
      if (r.valid) { try { localStorage.setItem(PROMO_KEY, c); } catch { /* ignore */ } }
      onChange(r.valid ? c : null, r.valid ? (r.description ?? null) : null);
    } catch (e) { setResult({ valid: false, message: e instanceof Error ? e.message : String(e) }); onChange(null, null); }
    finally { setBusy(false); }
  };
  useEffect(() => { if (code) check(code); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <div className="promo-box">
      <label className="field">Promo code
        <span className="row-inline"><input value={code} placeholder="Have a code?" onChange={(e) => setCode(e.target.value.toUpperCase())} onBlur={() => check(code)} onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); check(code); } }} />
          <button type="button" className="btn small" disabled={busy || !code.trim()} onClick={() => check(code)}>{busy ? "…" : "Apply"}</button></span>
      </label>
      {result && (result.valid ? <div className="promo-ok">✓ {result.code}: {result.description}</div> : <div className="error-text">{result.message}</div>)}
    </div>
  );
}

// --- sign in ----------------------------------------------------------------

export function SignIn({ onSignedIn, proofsURL }: { onSignedIn: (account: AccountState) => void; proofsURL?: string }) {
  // The marketing site's "Start your free trial" form hands the address
  // over as ?email= so the visitor doesn't type it twice; the sign-in
  // email's own "Sign in instantly" link hands over ?email= and &code=
  // together, so this can skip straight to verifying instead of making
  // them type the code back in. Read both once, synchronously, and clear
  // the URL in the same pass -- splitting this across two separate
  // useState initializers would race, since the first one's own
  // history.replaceState already wipes what the second would try to read.
  const [initial] = useState(() => {
    const params = new URLSearchParams(window.location.search);
    const e = params.get("email")?.trim() ?? "";
    const c = params.get("code")?.trim() ?? "";
    if (e || c) window.history.replaceState(null, "", window.location.pathname);
    return { email: e, code: c };
  });
  const [email, setEmail] = useState(initial.email);
  const [code, setCode] = useState("");
  const [sent, setSent] = useState(false);
  const [resent, setResent] = useState(false);
  const [busy, setBusy] = useState(!!initial.code);
  const [error, setError] = useState<string | null>(null);
  const [linkFailed, setLinkFailed] = useState(false);
  const autoVerifyRan = useRef(false);

  const doVerify = async (emailToUse: string, codeToUse: string) => {
    setBusy(true); setError(null);
    try {
      const me = await api.verifyCode(emailToUse, codeToUse);
      if (me.account) onSignedIn(me.account);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
      setSent(true); // falls back to manual code entry, email already filled in
      setLinkFailed(true);
    } finally { setBusy(false); }
  };

  useEffect(() => {
    if (initial.code && !autoVerifyRan.current) { autoVerifyRan.current = true; doVerify(initial.email, initial.code); }
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const request = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true); setError(null);
    try { await api.requestCode(email); setSent(true); }
    catch (err) { setError(err instanceof Error ? err.message : String(err)); }
    finally { setBusy(false); }
  };

  const resend = async () => {
    setBusy(true); setError(null); setResent(false);
    try { await api.requestCode(email); setCode(""); setResent(true); }
    catch (err) { setError(err instanceof Error ? err.message : String(err)); }
    finally { setBusy(false); }
  };

  const verify = async (e: React.FormEvent) => {
    e.preventDefault();
    await doVerify(email, code);
  };

  if (initial.code && busy && !linkFailed) {
    return (
      <div className="start">
        <div className="start-brand">
          <img src="/icon.png" alt="" width={64} height={64} />
          <h1>PiperStitch</h1>
        </div>
        <div className="auth-card"><p>Signing you in…</p></div>
      </div>
    );
  }

  return (
    <div className="start">
      <div className="start-brand">
        <img src="/icon.png" alt="" width={64} height={64} />
        <h1>PiperStitch</h1>
        <p>Turn any image into embroidery. Sign in with your email to start — every new account gets a free trial, no card needed.</p>
      </div>
      <form className="auth-card" onSubmit={sent ? verify : request}>
        {!sent ? (
          <>
            <label className="field">Email address
              <input type="email" required autoFocus autoComplete="email" placeholder="you@example.com" value={email} onChange={(e) => setEmail(e.target.value)} />
            </label>
            <button className="btn primary wide" disabled={busy || !email.includes("@")}>{busy ? "Sending…" : "Email me a sign-in code"}</button>
          </>
        ) : (
          <>
            <div className="auth-sent">{resent ? <>We sent a fresh code to <b>{email}</b>.</> : <>We emailed a six-digit code to <b>{email}</b>.</>} It's good for 15 minutes.</div>
            <p className="hint">Don't see it right away? Check your junk or spam folder — it sometimes lands there.</p>
            <label className="field">Sign-in code
              <input inputMode="numeric" pattern="[0-9]*" maxLength={6} required autoFocus autoComplete="one-time-code" placeholder="123456" value={code}
                onChange={(e) => { setCode(e.target.value.replace(/\D/g, "")); setResent(false); }} className="code" />
            </label>
            <button className="btn primary wide" disabled={busy || code.length !== 6}>{busy ? "Checking…" : "Sign in"}</button>
            <button type="button" className="btn ghost wide" disabled={busy} onClick={resend}>{busy ? "Sending…" : "Resend code"}</button>
            <button type="button" className="btn ghost wide" disabled={busy} onClick={() => { setSent(false); setCode(""); setResent(false); setError(null); }}>Use a different email</button>
          </>
        )}
        {error && <div className="error-text">{error}</div>}
        <div className="auth-foot">By continuing you accept the <a href="https://www.piperstitch.com/terms.html" target="_blank" rel="noopener">Terms</a> and <a href="https://www.piperstitch.com/privacy-policy.html" target="_blank" rel="noopener">Privacy Policy</a>.</div>
      </form>
      <div className="start-hints">
        <div><strong>No password:</strong> a fresh code is emailed each time you sign in.</div>
        {proofsURL && <div className="proofs-signin-link">Looking for <strong>PiperStitch Proofs</strong> — customer proof approval? <a href={`${proofsURL}/signin`}>Sign in to Proofs →</a></div>}
      </div>
    </div>
  );
}

// --- the wall ---------------------------------------------------------------

export function SubscribeWall({ account, onSignOut, onRefresh }: { account: AccountState; onSignOut: () => void; onRefresh: () => void }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [promo, setPromo] = useState<{ code: string | null; description: string | null }>({ code: null, description: null });
  const go = async (fn: () => Promise<string>) => {
    setBusy(true); setError(null);
    try { window.location.assign(await fn()); }
    catch (err) { setError(err instanceof Error ? err.message : String(err)); setBusy(false); }
  };
  const ended = account.status === "ended" || account.status === "trialing";
  return (
    <div className="start">
      <div className="start-brand">
        <img src="/icon.png" alt="" width={64} height={64} />
        <h1>{ended ? "Your free trial has ended" : account.status === "past_due" ? "There's a payment problem" : "Subscribe to keep going"}</h1>
        <p>{account.status === "past_due"
          ? "Your last payment didn't go through. Update your card and you're back in right away."
          : `PiperStitch is ${price(account)}, cancel any time. Everything you've already downloaded keeps working forever.`}</p>
      </div>
      <div className="auth-card">
        {account.status === "past_due" || account.has_billing
          ? <button className="btn primary wide" disabled={busy} onClick={() => go(api.billingPortalURL)}>{busy ? "Opening…" : "Manage billing"}</button>
          : null}
        {account.status !== "past_due" && (
          <>
            <PromoBox onChange={(code, description) => setPromo({ code, description })} />
            <button className="btn primary wide" disabled={busy} onClick={() => go(() => api.checkoutURL(promo.code ?? undefined))}>{busy ? "Opening…" : promo.description ? `Subscribe · ${promo.description}` : `Subscribe · ${price(account)}`}</button>
          </>
        )}
        <button className="btn ghost wide" onClick={onRefresh} disabled={busy}>I've already subscribed — check again</button>
        {error && <div className="error-text">{error}</div>}
        <div className="auth-foot">Signed in as {account.email} · <button className="linkish" onClick={onSignOut}>Sign out</button></div>
      </div>
    </div>
  );
}

// --- the menu ---------------------------------------------------------------

export function AccountMenu({ account, onSignOut }: { account: AccountState; onSignOut: () => void }) {
  const [open, setOpen] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const go = async (fn: () => Promise<string>) => {
    try { window.location.assign(await fn()); } catch (err) { setError(err instanceof Error ? err.message : String(err)); }
  };
  const trial = account.status === "trialing";
  return (
    <div className="account">
      <button className={"btn ghost account-btn" + (trial ? " trial" : "")} onClick={() => setOpen((o) => !o)} title={account.email}>
        <span className="account-dot" /><b>{account.name || account.email}</b>{trial && <span className="account-sub">· {statusLine(account)}</span>}
      </button>
      {open && (
        <div className="menu" onMouseLeave={() => setOpen(false)}>
          <div className="menu-head"><b>{account.name}</b><span>{account.email}</span><span className="menu-status">{statusLine(account)}</span></div>
          {trial && <button onClick={() => go(api.checkoutURL)}>Subscribe · {price(account)}</button>}
          {account.has_billing && <button onClick={() => go(api.billingPortalURL)}>Manage billing</button>}
          {account.proofs && (account.proofs.subscribed || account.proofs.free_used > 0) && (
            <button onClick={() => go(api.proofsHandoffURL)}>Open PiperStitch Proofs ↗</button>
          )}
          <button onClick={onSignOut}>Sign out</button>
          {error && <div className="error-text menu-error">{error}</div>}
        </div>
      )}
    </div>
  );
}
