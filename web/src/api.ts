import type { Catalog, DigitizeResponse, FabricType, ImportResponse, StitchDocument, ThreadColor } from "./types";

const BASE = "/api/v1";

class ApiError extends Error {}

async function check(res: Response): Promise<Response> {
  if (res.ok) return res;
  let reason = res.statusText;
  try {
    const body = await res.json();
    if (body && typeof body.reason === "string") reason = body.reason;
  } catch { /* not JSON */ }
  throw new ApiError(reason || `Request failed (${res.status})`);
}

async function postJSON<T>(path: string, body: unknown): Promise<T> {
  const res = await fetch(BASE + path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return (await check(res)).json();
}

export const api = {
  catalog: async (): Promise<Catalog> => (await check(await fetch(BASE + "/catalog"))).json(),

  /** Straight-alpha RGBA the browser decoded, gzipped when the browser can. */
  async importRaster(
    rgba: Uint8Array<ArrayBuffer>, width: number, height: number,
    opts: { maxColors: number; hoopWidthMM?: number; hoopHeightMM?: number },
  ): Promise<ImportResponse> {
    const q = new URLSearchParams({ width: String(width), height: String(height), maxColors: String(opts.maxColors) });
    if (opts.hoopWidthMM) q.set("hoopWidthMM", String(opts.hoopWidthMM));
    if (opts.hoopHeightMM) q.set("hoopHeightMM", String(opts.hoopHeightMM));
    const headers: Record<string, string> = { "Content-Type": "application/octet-stream" };
    let body: BodyInit = rgba;
    if ("CompressionStream" in window) {
      // Flat-color artwork compresses 20-50x; the server inflates it before
      // the engine ever sees it.
      const stream = new Blob([rgba]).stream().pipeThrough(new CompressionStream("gzip"));
      body = await new Response(stream).arrayBuffer();
      headers["Content-Encoding"] = "gzip";
    }
    const res = await fetch(`${BASE}/import/raster?${q}`, { method: "POST", headers, body });
    return (await check(res)).json();
  },

  async importSVG(text: string, opts: { hoopWidthMM?: number; hoopHeightMM?: number }): Promise<ImportResponse> {
    const q = new URLSearchParams();
    if (opts.hoopWidthMM) q.set("hoopWidthMM", String(opts.hoopWidthMM));
    if (opts.hoopHeightMM) q.set("hoopHeightMM", String(opts.hoopHeightMM));
    const res = await fetch(`${BASE}/import/svg?${q}`, { method: "POST", headers: { "Content-Type": "image/svg+xml" }, body: text });
    return (await check(res)).json();
  },

  build: (body: {
    source: ImportResponse["source"]; name: string; widthMM: number; heightMM: number;
    matchToThreadLibrary?: boolean; palette?: ThreadColor[]; fabricType?: FabricType;
  }) => postJSON<{ document: StitchDocument }>("/build", body),

  resize: (document: StitchDocument, widthMM: number, heightMM: number) =>
    postJSON<{ document: StitchDocument }>("/resize", { document, widthMM, heightMM }),

  digitize: (document: StitchDocument, hoopWidthMM?: number, hoopHeightMM?: number) =>
    postJSON<DigitizeResponse>("/digitize", { document, hoopWidthMM, hoopHeightMM }),

  async export(document: StitchDocument, format: string): Promise<Blob> {
    const res = await fetch(`${BASE}/export/${format}`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ document }),
    });
    return (await check(res)).blob();
  },
};

export { ApiError };
