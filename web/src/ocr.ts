// Reading a detected text line with Tesseract, in the browser, to pre-fill
// the Text step. The library and its English data load from a CDN the
// first time a line is read (a few megabytes, cached by the browser), so
// nothing is fetched for artwork without text. The guess is only ever a
// pre-fill: blurry 3 mm text reads unreliably, and the user confirms every
// line before it becomes lettering. Nothing here is sent to our server.

import type { BoundingBox } from "./types";
import type { DecodedImage } from "./decode";

export interface OCRGuess { text: string; confidence: number }

type Worker = { recognize: (image: HTMLCanvasElement, options?: object) => Promise<{ data: { text: string; confidence: number } }>; setParameters: (p: Record<string, string>) => Promise<unknown>; terminate: () => Promise<unknown> };
let workerPromise: Promise<Worker> | null = null;

async function worker(): Promise<Worker> {
  if (!workerPromise) {
    workerPromise = (async () => {
      const Tesseract = await import("tesseract.js");
      const w = (await Tesseract.createWorker("eng")) as unknown as Worker;
      // One line of text, letters and the usual punctuation only.
      await w.setParameters({ tessedit_pageseg_mode: "7" });
      return w;
    })();
  }
  return workerPromise;
}

/** The line's pixels, padded, upscaled to a comfortable reading height and
 *  turned to grey on white -- what OCR wants, whatever the artwork's colours. */
export function cropLine(image: DecodedImage, box: BoundingBox, rotationDegrees = 0): HTMLCanvasElement {
  const pad = Math.max(2, (box.maxY - box.minY) * 0.35);
  const x0 = Math.max(0, Math.floor(box.minX - pad)), y0 = Math.max(0, Math.floor(box.minY - pad));
  const x1 = Math.min(image.width, Math.ceil(box.maxX + pad)), y1 = Math.min(image.height, Math.ceil(box.maxY + pad));
  const w = Math.max(1, x1 - x0), h = Math.max(1, y1 - y0);
  const src = document.createElement("canvas"); src.width = w; src.height = h;
  const sctx = src.getContext("2d")!;
  const data = sctx.createImageData(w, h);
  // Grey, with the dominant (background) tone forced light so dark or
  // light text both read as dark-on-white.
  let sum = 0;
  const grey = new Float32Array(w * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const i = ((y0 + y) * image.width + (x0 + x)) * 4;
    const g = 0.299 * image.rgba[i] + 0.587 * image.rgba[i + 1] + 0.114 * image.rgba[i + 2];
    grey[y * w + x] = g; sum += g;
  }
  const mean = sum / (w * h);
  // Text is the minority: if the crop is mostly dark, invert.
  let dark = 0; for (let i = 0; i < grey.length; i++) if (grey[i] < mean) dark++;
  const invert = dark > grey.length / 2;
  for (let i = 0; i < grey.length; i++) {
    const v = invert ? 255 - grey[i] : grey[i];
    data.data[i * 4] = data.data[i * 4 + 1] = data.data[i * 4 + 2] = v; data.data[i * 4 + 3] = 255;
  }
  sctx.putImageData(data, 0, 0);
  const scale = Math.min(8, Math.max(1, 60 / (box.maxY - box.minY)));
  const out = document.createElement("canvas"); out.width = Math.round(w * scale); out.height = Math.round(h * scale);
  const octx = out.getContext("2d")!;
  octx.fillStyle = "#fff"; octx.fillRect(0, 0, out.width, out.height);
  octx.imageSmoothingEnabled = true;
  if (Math.abs(rotationDegrees) > 2) {
    octx.translate(out.width / 2, out.height / 2); octx.rotate(-rotationDegrees * Math.PI / 180); octx.translate(-out.width / 2, -out.height / 2);
  }
  octx.drawImage(src, 0, 0, out.width, out.height);
  return out;
}

/** Best guess at the words on one line; empty text when nothing legible. */
export async function readLine(canvas: HTMLCanvasElement): Promise<OCRGuess> {
  try {
    const w = await worker();
    const { data } = await w.recognize(canvas);
    const text = data.text.replace(/\s+/g, " ").trim();
    return { text: /[A-Za-z0-9]/.test(text) ? text : "", confidence: data.confidence ?? 0 };
  } catch {
    return { text: "", confidence: 0 };
  }
}
