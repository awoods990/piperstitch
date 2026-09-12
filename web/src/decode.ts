// The browser is the image decoder for the web edition: it reads whatever
// the user drops (PNG, JPEG, WebP, GIF, BMP, HEIC on Safari...), downsizes
// anything larger than the engine can use, and hands straight-alpha RGBA
// to the server -- the same bytes ImageIO gives the Mac app after
// unpremultiplying (ImageImporter.importShapes(rgba:...)).

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

export async function decodeImage(file: File): Promise<DecodedImage> {
  const bitmap = await createImageBitmap(file).catch(() => {
    throw new Error("Couldn't decode this image. It may be corrupted or an unsupported variant of its format.");
  });
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
  return { rgba: new Uint8Array(data.buffer as ArrayBuffer, data.byteOffset, data.byteLength), width, height, previewURL: URL.createObjectURL(file) };
}

export function isSVGFile(file: File): boolean {
  return file.type === "image/svg+xml" || /\.svg$/i.test(file.name);
}
