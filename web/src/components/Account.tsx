// Sign-in, the subscribe wall, and the account menu. The server decides
// everything (see server/Sources/StitchPilotServer/Auth.swift); these
// only show its answers and send the two sign-in requests.

import { useState } from "react";
import { api } from "../api";
import type { AccountState } from "../types";

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

// --- sign in ----------------------------------------------------------------

export function SignIn({ onSignedIn }: { onSignedIn: (account: AccountState) => void }) {
  // The marketing site's "Start your free trial" form hands the address over
  // as ?email= so the visitor doesn't type it twice.
  const [email, setEmail] = useState(() => {
    const e = new URLSearchParams(window.location.search).get("email")?.trim() ?? "";
    if (e) window.history.replaceState(null, "", window.location.pathname);
    return e;
  });
  const [code, setCode] = useState("");
  const [sent, setSent] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const request = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true); setError(null);
    try { await api.requestCode(email); setSent(true); }
    catch (err) { setError(err instanceof Error ? err.message : String(err)); }
    finally { setBusy(false); }
  };

  const verify = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true); setError(null);
    try {
      const me = await api.verifyCode(email, code);
      if (me.account) onSignedIn(me.account);
    } catch (err) { setError(err instanceof Error ? err.message : String(err)); }
    finally { setBusy(false); }
  };

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
            <div className="auth-foot">By continuing you accept the <a href="https://www.piperstitch.com/terms.html" target="_blank" rel="noopener">Terms</a> and <a href="https://www.piperstitch.com/privacy-policy.html" target="_blank" rel="noopener">Privacy Policy</a>.</div>
          </>
        ) : (
          <>
            <div className="auth-sent">We emailed a six-digit code to <b>{email}</b>. It's good for 15 minutes.</div>
            <label className="field">Sign-in code
              <input inputMode="numeric" pattern="[0-9]*" maxLength={6} required autoFocus autoComplete="one-time-code" placeholder="123456" value={code}
                onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))} className="code" />
            </label>
            <button className="btn primary wide" disabled={busy || code.length !== 6}>{busy ? "Checking…" : "Sign in"}</button>
            <button type="button" className="btn ghost wide" disabled={busy} onClick={() => { setSent(false); setCode(""); setError(null); }}>Use a different email</button>
          </>
        )}
        {error && <div className="error-text">{error}</div>}
      </form>
      <div className="start-hints">
        <div><strong>No password:</strong> a fresh code is emailed each time you sign in.</div>
        <div><strong>Already subscribed on the Mac app?</strong> Use the same email — it's one subscription.</div>
      </div>
    </div>
  );
}

// --- the wall ---------------------------------------------------------------

export function SubscribeWall({ account, onSignOut, onRefresh }: { account: AccountState; onSignOut: () => void; onRefresh: () => void }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
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
          <button className="btn primary wide" disabled={busy} onClick={() => go(api.checkoutURL)}>{busy ? "Opening…" : `Subscribe · ${price(account)}`}</button>
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
        <span className="account-dot" />{trial ? statusLine(account) : account.email}
      </button>
      {open && (
        <div className="menu" onMouseLeave={() => setOpen(false)}>
          <div className="menu-head"><b>{account.name}</b><span>{account.email}</span><span className="menu-status">{statusLine(account)}</span></div>
          {trial && <button onClick={() => go(api.checkoutURL)}>Subscribe · {price(account)}</button>}
          {account.has_billing && <button onClick={() => go(api.billingPortalURL)}>Manage billing</button>}
          <button onClick={onSignOut}>Sign out</button>
          {error && <div className="error-text menu-error">{error}</div>}
        </div>
      )}
    </div>
  );
}
