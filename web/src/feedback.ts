// "Send feedback": renders a clean picture of the digitized result (not
// whatever the canvas happens to be showing mid-edit -- no selection
// handles, no hoop outline, no pan/zoom) and turns the original artwork
// into a picture too, so both can go to PiperStitch as plain images
// alongside the embroidery file itself never leaving the browser.

import type { DigitizeResponse, StitchDocument } from "./types";
import { drawPlan, fitView, PAPER } from "./render";

const MAX_EDGE = 900;

export function renderDigitizedPNGDataURL(doc: StitchDocument, digitized: DigitizeResponse): string {
  const aspect = doc.physicalWidthMM > 0 && doc.physicalHeightMM > 0 ? doc.physicalWidthMM / doc.physicalHeightMM : 1;
  const w = aspect >= 1 ? MAX_EDGE : Math.max(1, Math.round(MAX_EDGE * aspect));
  const h = aspect >= 1 ? Math.max(1, Math.round(MAX_EDGE / aspect)) : MAX_EDGE;
  const canvas = document.createElement("canvas");
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext("2d");
  if (!ctx) return "";
  ctx.fillStyle = PAPER;
  ctx.fillRect(0, 0, w, h);
  const view = fitView(w, h, doc.physicalWidthMM, doc.physicalHeightMM, 20);
  drawPlan(ctx, digitized.plan.commands, digitized.colors, view, { showJumps: false });
  return canvas.toDataURL("image/png");
}

/** Rasterizes SVG source (a vector import has no picture of its own) to a PNG data URL, or null if the browser can't. */
export function renderSVGPNGDataURL(svgText: string): Promise<string | null> {
  return new Promise((resolve) => {
    const img = new Image();
    const url = URL.createObjectURL(new Blob([svgText], { type: "image/svg+xml" }));
    const done = (result: string | null) => { URL.revokeObjectURL(url); resolve(result); };
    img.onload = () => {
      const iw = img.naturalWidth || MAX_EDGE, ih = img.naturalHeight || MAX_EDGE;
      const scale = Math.min(1, MAX_EDGE / Math.max(iw, ih)) || 1;
      const w = Math.max(1, Math.round(iw * scale)), h = Math.max(1, Math.round(ih * scale));
      const canvas = document.createElement("canvas");
      canvas.width = w;
      canvas.height = h;
      const ctx = canvas.getContext("2d");
      if (!ctx) { done(null); return; }
      ctx.fillStyle = "#ffffff";
      ctx.fillRect(0, 0, w, h);
      ctx.drawImage(img, 0, 0, w, h);
      done(canvas.toDataURL("image/png"));
    };
    img.onerror = () => done(null);
    img.src = url;
  });
}

/** blob: URL (the original raster upload's own preview) -> data URL, or null if it's gone. */
export async function blobURLToPNGDataURL(url: string): Promise<string | null> {
  try {
    const res = await fetch(url);
    const blob = await res.blob();
    return await new Promise<string>((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result as string);
      reader.onerror = () => reject(reader.error);
      reader.readAsDataURL(blob);
    });
  } catch {
    return null;
  }
}

export function dataURLToBase64(dataURL: string): { base64: string; type: string } {
  const comma = dataURL.indexOf(",");
  const header = dataURL.slice(0, comma);
  const type = /data:(.*?);base64/.exec(header)?.[1] ?? "image/png";
  return { base64: dataURL.slice(comma + 1), type };
}
