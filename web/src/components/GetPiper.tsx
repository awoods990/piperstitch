// "Get Piper": put PiperStitch on the Dock / taskbar / desktop / home screen.
// Piper waves from a small canvas (the rig, live); the buttons do whatever
// this browser can -- the install dialog where there is one, otherwise the
// exact menu path, and a shortcut file as the fallback that works anywhere.
import { useEffect, useRef, useState } from "react";
import { bob, place, POSE, settle, easeOut } from "../piperRig";
import { downloadShortcut, installState, isInstalled, isMac, onInstallChange, promptInstall, type InstallState } from "../install";

/** Piper at rest: breathing, blinking, and every few seconds a small hop
 *  and a wave with the far wing -- enough life to read as "him", not a
 *  picture, without being busy. */
export function PiperIdle({ size = 120 }: { size?: number }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const cv = ref.current; if (!cv) return;
    const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
    const dpr = Math.min(devicePixelRatio || 1, 2), W = size * 1.5, H = size * 1.25;
    cv.width = W * dpr; cv.height = H * dpr; cv.style.width = W + "px"; cv.style.height = H + "px";
    const x = cv.getContext("2d")!; x.scale(dpr, dpr);
    let frame = 0, raf = 0, waveAt = 140;
    const draw = () => {
      x.clearRect(0, 0, W, H);
      const b = bob(frame), pose = { ...POSE.idle, hop: b.hop, head: b.head, blink: b.blink } as Record<string, unknown>;
      let fy = H * 0.9;
      const w = frame - waveAt;
      if (w >= 0 && w < 70) {                 // a hop with a wave, then back to resting
        if (w < 8) { const e = easeOut(w / 8); pose.sx = 1 + .2 * e; pose.sy = 1 - .18 * e; }
        else if (w < 36) { const q = (w - 8) / 28; fy -= Math.sin(q * Math.PI) * size * .32; pose.wing = 60 + 40 * Math.sin(q * Math.PI * 3); pose.wing2 = 120; pose.eye = "happy"; pose.beak = .4; pose.tail = 18; pose.hop = 1; }
        else if (w < 50) { const s = settle((w - 36) / 14); pose.sx = 1 + s; pose.sy = 1 - s; pose.eye = "happy"; }
        if (w === 69) waveAt = frame + 200 + Math.floor(Math.random() * 160);
      }
      place(x, W * .5, fy, size, pose);
      if (!reduce) raf = requestAnimationFrame(() => { frame++; draw(); });
    };
    draw();
    return () => cancelAnimationFrame(raf);
  }, [size]);
  return <canvas ref={ref} className="piper-idle" aria-hidden="true" />;
}

const HOW: Record<InstallState, { title: string; steps: string[] }> = {
  installed: { title: "Piper is on this device", steps: ["You're running the installed app — look for the PiperStitch icon in your Dock, taskbar or home screen."] },
  prompt: { title: "One click", steps: ["Click Install. Your browser puts a PiperStitch icon in your Dock, taskbar or Start menu, and the app opens in its own window."] },
  "safari-mac": { title: "Safari: add it to the Dock", steps: ["In Safari's menu bar choose File → Add to Dock…", "Click Add. PiperStitch appears in your Dock and opens in its own window, like any Mac app."] },
  ios: { title: "Add it to your home screen", steps: ["Tap the Share button (the square with an arrow).", "Choose Add to Home Screen, then Add."] },
  manual: { title: "A shortcut on your desktop", steps: ["Download the shortcut below and drag it to your desktop or Dock.", "Double-click it any time to open PiperStitch."] },
};

export default function GetPiper({ compact = false }: { compact?: boolean }) {
  const [state, setState] = useState<InstallState>(installState());
  const [done, setDone] = useState<string | null>(null);
  useEffect(() => onInstallChange(() => setState(installState())), []);
  const how = HOW[state];
  const install = async () => {
    const ok = await promptInstall();
    setDone(ok ? "Installed — look for the PiperStitch icon." : null);
    setState(installState());
  };
  return (
    <div className={"get-piper" + (compact ? " compact" : "")}>
      <PiperIdle size={compact ? 96 : 120} />
      <div className="get-piper-text">
        <b>{compact ? "Put Piper on your desktop" : how.title}</b>
        {!compact && <p className="hint">{isInstalled() ? how.steps[0] : "An icon that opens PiperStitch in its own window — no browser tabs to hunt through. It's the same app, always up to date."}</p>}
        {compact && <p className="hint">{state === "prompt" ? "One click adds a PiperStitch icon to your Dock or taskbar." : state === "safari-mac" ? "Safari: File → Add to Dock… puts PiperStitch in your Dock." : state === "ios" ? "Share → Add to Home Screen." : state === "installed" ? how.steps[0] : "A shortcut you can keep on your desktop or Dock."}</p>}
        {!compact && !isInstalled() && <ol className="get-piper-steps">{how.steps.map((s) => <li key={s}>{s}</li>)}</ol>}
        <div className="btn-row">
          {state === "prompt" && <button className="btn primary" onClick={install}>Install PiperStitch</button>}
          {state !== "installed" && state !== "ios" && <button className={"btn" + (state === "prompt" ? " ghost" : "")} onClick={downloadShortcut}>Download {isMac() ? "Mac" : "desktop"} shortcut</button>}
        </div>
        {done && <p className="hint ok">{done}</p>}
      </div>
    </div>
  );
}
