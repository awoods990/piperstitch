// "Get Piper": PiperStitch as an icon on the Dock, taskbar, desktop or home
// screen that opens the app in its own window. The app is a web app, so
// the mechanism is the browser's own "install" -- a manifest (index.html)
// plus a service worker that caches nothing (public/sw.js). Where a
// browser can't install (Firefox, Safari on macOS 13 and earlier), a
// shortcut file does the same job with a generic icon.

export type InstallState =
  | "installed"      // already running as the installed app
  | "prompt"         // Chrome / Edge / Android: we can open the install dialog ourselves
  | "safari-mac"     // Safari 17+: File > Add to Dock
  | "ios"            // iPhone / iPad: Share > Add to Home Screen
  | "manual";        // everything else: a shortcut file

interface BeforeInstallPromptEvent extends Event {
  prompt(): Promise<void>;
  userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
}

let deferred: BeforeInstallPromptEvent | null = null;
const listeners = new Set<() => void>();

export function setUpInstall() {
  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.register("/sw.js").catch(() => { /* not fatal: the app works without it */ });
  }
  window.addEventListener("beforeinstallprompt", (e) => {
    e.preventDefault();
    deferred = e as BeforeInstallPromptEvent;
    listeners.forEach((l) => l());
  });
  window.addEventListener("appinstalled", () => { deferred = null; listeners.forEach((l) => l()); });
}

export function onInstallChange(l: () => void) { listeners.add(l); return () => { listeners.delete(l); }; }

export function isInstalled(): boolean {
  return matchMedia("(display-mode: standalone)").matches || (navigator as unknown as { standalone?: boolean }).standalone === true;
}

export function installState(): InstallState {
  if (isInstalled()) return "installed";
  if (deferred) return "prompt";
  const ua = navigator.userAgent;
  const isIOS = /iPhone|iPad|iPod/.test(ua) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  if (isIOS) return "ios";
  const isSafari = /Safari/.test(ua) && !/Chrome|Chromium|Edg|OPR|Firefox/.test(ua);
  if (isSafari && /Mac/.test(navigator.platform)) return "safari-mac";
  return "manual";
}

/** Opens the browser's install dialog. Resolves true when accepted. */
export async function promptInstall(): Promise<boolean> {
  if (!deferred) return false;
  const ev = deferred;
  await ev.prompt();
  const choice = await ev.userChoice;
  if (choice.outcome === "accepted") deferred = null;
  listeners.forEach((l) => l());
  return choice.outcome === "accepted";
}

export const isMac = () => /Mac/.test(navigator.platform) && navigator.maxTouchPoints <= 1;
export const isWindows = () => /Win/.test(navigator.platform);

/** A double-clickable shortcut to the app: .webloc on a Mac, .url on
 *  Windows (both are tiny text files the OS understands natively). */
export function downloadShortcut() {
  const url = `${location.origin}/?source=shortcut`;
  let name: string, body: string, type: string;
  if (isWindows()) {
    name = "PiperStitch.url";
    body = `[InternetShortcut]\r\nURL=${url}\r\nIconFile=${location.origin}/favicon.ico\r\nIconIndex=0\r\n`;
    type = "application/internet-shortcut";
  } else {
    name = "PiperStitch.webloc";
    body = `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>URL</key><string>${url}</string></dict></plist>\n`;
    type = "application/xml";
  }
  const blob = new Blob([body], { type });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob); a.download = name; a.rel = "noopener";
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 2000);
}
