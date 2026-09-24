// The browser is the image decoder for the web edition: it reads whatever
// the user drops (PNG, JPEG, WebP, GIF, BMP), downsizes anything larger
// than the engine can use, and hands straight-alpha RGBA to the server --
// the same bytes ImageIO gives the Mac app after unpremultiplying
// (ImageImporter.importShapes(rgba:...)).
//
// HEIC is the exception. Safari decodes it; Chrome, Edge and Firefox do
// not, which meant the same photo from the same phone worked for one
// customer and failed for the next with a message about corruption. So we
// carry a decoder for it -- see decodeHEIC below.

/** The engine traces at ~12 px/mm and a 400 mm hoop is the ceiling, so
 *  nothing above this edge length adds detail -- only upload time. */
const MAX_EDGE = 2400;

export interface DecodedImage {
  rgba: Uint8Array<ArrayBuffer>;
  width: number;
  height: number;
  /** For showing the original alongside the stitches. */
  previewURL: string;
}

/** HEIC files say so in their ISO-BMFF brand, four bytes at offset 8. The
 *  name and the MIME type are checked first because they cost nothing, but
 *  a file dragged out of some tools arrives with neither. */
const HEIC_BRANDS = ["heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1"];

async function looksLikeHEIC(file: File): Promise<boolean> {
  if (/^image\/hei[cf]/i.test(file.type) || /\.(heic|heif)$/i.test(file.name)) return true;
  try {
    const head = new Uint8Array(await file.slice(0, 12).arrayBuffer());
    if (String.fromCharCode(...head.subarray(4, 8)) !== "ftyp") return false;
    return HEIC_BRANDS.includes(String.fromCharCode(...head.subarray(8, 12)).toLowerCase());
  } catch { return false; }
}

/** libheif, compiled to WebAssembly. It is a couple of megabytes, so it is
 *  imported here rather than at the top of the file: Vite gives it its own
 *  chunk, and it is fetched only by someone who actually hands us a HEIC.
 *  Everyone else never downloads a byte of it.
 *
 *  IF A CONTENT-SECURITY-POLICY IS EVER ADDED TO THIS APP, it must allow
 *  `worker-src blob:` and `script-src blob:`. The decoder builds its worker
 *  with `new Worker(URL.createObjectURL(...))`, and a policy without those
 *  would break HEIC alone, silently, for the one group of people who need
 *  it -- everyone else would never notice. It needs no SharedArrayBuffer
 *  and no cross-origin isolation, so COOP/COEP are not required. */
async function decodeHEIC(file: File): Promise<ImageBitmap> {
  const { heicTo } = await import("heic-to");
  return heicTo({ blob: file, type: "bitmap" });
}

export async function decodeImage(file: File): Promise<DecodedImage> {
  let bitmap = await createImageBitmap(file).catch(() => null);
  // Safari decodes HEIC itself and never gets here.
  const wasHEIC = bitmap === null && await looksLikeHEIC(file);
  if (wasHEIC) {
    bitmap = await decodeHEIC(file).catch(() => null);
    if (!bitmap) throw new Error("Couldn't read this HEIC photo. Exporting it from Photos as JPEG will always work.");
  }
  if (!bitmap) throw new Error("Couldn't decode this image. It may be corrupted or an unsupported variant of its format.");
  const scale = Math.min(1, MAX_EDGE / Math.max(bitmap.width, bitmap.height));
  const width = Math.max(2, Math.round(bitmap.width * scale));
  const height = Math.max(2, Math.round(bitmap.height * scale));
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  if (!ctx) throw new Error("This browser can't read image pixels.");
  ctx.imageSmoothingQuality = "high";
  ctx.drawImage(bitmap, 0, 0, width, height);
  bitmap.close();
  // getImageData is un-premultiplied by spec: exactly what the engine wants.
  const data = ctx.getImageData(0, 0, width, height).data;
  // "Show original" needs something the browser can paint. For a HEIC that
  // is not the file itself -- the same browser that could not decode it
  // cannot display it either -- so the preview comes off the canvas.
  let previewURL = URL.createObjectURL(file);
  if (wasHEIC) {
    const png = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/png"));
    if (png) previewURL = URL.createObjectURL(png);
  }
  return { rgba: new Uint8Array(data.buffer as ArrayBuffer, data.byteOffset, data.byteLength), width, height, previewURL };
}

/** An SVG drawn to pixels, with the factor from its user units (which the
 *  engine's shapes are in, origin at the viewBox corner) to those pixels:
 *  the Text step's crops and the editor's "show original" need a picture. */
export async function rasterizeSVG(svgText: string): Promise<{ image: DecodedImage; unitsToPixels: number } | null> {
  try {
    const doc = new DOMParser().parseFromString(svgText, "image/svg+xml");
    const svg = doc.documentElement;
    if (svg.tagName.toLowerCase() !== "svg") return null;
    const viewBox = (svg.getAttribute("viewBox") ?? "").split(/[\s,]+/).map(Number).filter((n) => !isNaN(n));
    const attrLength = (name: string) => { const v = parseFloat(svg.getAttribute(name) ?? ""); return isFinite(v) && v > 0 ? v : null; };
    let unitsW = viewBox.length === 4 ? viewBox[2] : attrLength("width");
    let unitsH = viewBox.length === 4 ? viewBox[3] : attrLength("height");
    if (!unitsW || !unitsH) return null;
    // Draw it at a comfortable size regardless of how the file is scaled.
    const k = Math.min(8, Math.max(1 / 8, 1600 / Math.max(unitsW, unitsH)));
    const width = Math.max(2, Math.round(unitsW * k)), height = Math.max(2, Math.round(unitsH * k));
    if (viewBox.length !== 4) svg.setAttribute("viewBox", `0 0 ${unitsW} ${unitsH}`);
    svg.setAttribute("width", String(width)); svg.setAttribute("height", String(height));
    const blob = new Blob([new XMLSerializer().serializeToString(doc)], { type: "image/svg+xml" });
    const url = URL.createObjectURL(blob);
    const img = new Image();
    await new Promise<void>((resolve, reject) => { img.onload = () => resolve(); img.onerror = () => reject(new Error("svg")); img.src = url; });
    const canvas = document.createElement("canvas");
    canvas.width = width; canvas.height = height;
    const ctx = canvas.getContext("2d", { willReadFrequently: true });
    if (!ctx) return null;
    ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, width, height);
    ctx.drawImage(img, 0, 0, width, height);
    URL.revokeObjectURL(url);
    const data = ctx.getImageData(0, 0, width, height).data;
    const png = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/png"));
    if (!png) return null;
    return { image: { rgba: new Uint8Array(data.buffer as ArrayBuffer, data.byteOffset, data.byteLength), width, height, previewURL: URL.createObjectURL(png) }, unitsToPixels: k };
  } catch { return null; }
}

export function isSVGFile(file: File): boolean {
  return file.type === "image/svg+xml" || /\.svg$/i.test(file.name);
}
