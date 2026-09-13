import type { Catalog, DigitizeResponse, FabricType, ImportResponse, MeResponse, Point2D, ProjectSummary, RGBColor, StitchDocument, ThreadColor, VectorShape } from "./types";

export interface EditResponse { document: StitchDocument; selectedIDs: string[]; status: string }
export interface PendingMerge { pendingMerge: { targetID: string; targetName: string } }

const BASE = "/api/v1";

class ApiError extends Error {
  status: number;
  constructor(message: string, status: number) { super(message); this.status = status; }
  /** Signed out, or the trial/subscription ended: the app must re-check the account. */
  get isAccountProblem() { return this.status === 401 || this.status === 402; }
}

async function check(res: Response): Promise<Response> {
  if (res.ok) return res;
  let reason = res.statusText;
  try {
    const body = await res.json();
    if (body && typeof body.reason === "string") reason = body.reason;
  } catch { /* not JSON */ }
  throw new ApiError(reason || `Request failed (${res.status})`, res.status);
}

async function jsonOrEmpty<T>(res: Response): Promise<T> {
  return res.status === 204 ? (undefined as T) : res.json();
}

async function postJSON<T>(path: string, body: unknown): Promise<T> {
  const res = await fetch(BASE + path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return jsonOrEmpty<T>(await check(res));
}

export const api = {
  // --- accounts ---
  me: async (refresh = false): Promise<MeResponse> => (await check(await fetch(`${BASE}/auth/me${refresh ? "?refresh=1" : ""}`))).json(),
  requestCode: (email: string) => postJSON<{ sent: boolean }>("/auth/request", { email }),
  verifyCode: (email: string, code: string) => postJSON<MeResponse>("/auth/verify", { email, code }),
  signOut: () => postJSON<void>("/auth/signout", {}),
  checkoutURL: async () => (await postJSON<{ url: string }>("/auth/checkout", {})).url,
  billingPortalURL: async () => (await postJSON<{ url: string }>("/auth/billing-portal", {})).url,

  // --- projects ---
  listProjects: async (): Promise<ProjectSummary[]> => (await check(await fetch(`${BASE}/projects`))).json(),
  getProject: async (id: string): Promise<{ id: string; name: string; updatedAt: string; document: StitchDocument }> =>
    (await check(await fetch(`${BASE}/projects/${id}`))).json(),
  saveProject: async (id: string, name: string, document: StitchDocument): Promise<{ created: boolean }> => {
    const res = await fetch(`${BASE}/projects/${id}`, { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name, document }) });
    return (await check(res)).json();
  },
  deleteProject: async (id: string) => { await check(await fetch(`${BASE}/projects/${id}`, { method: "DELETE" })); },

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

  // --- editing that needs the engine's geometry (server/EditRoutes.swift) ---
  mergeShapes: (document: StitchDocument, objectIDs: string[]) => postJSON<EditResponse>("/edit/merge-shapes", { document, objectIDs }),
  erase: (document: StitchDocument, points: Point2D[], radiusMM: number, selectedIDs: string[]) =>
    postJSON<EditResponse>("/edit/erase", { document, points, radiusMM, selectedIDs }),
  paint: (body: {
    document: StitchDocument; points: Point2D[]; radiusMM: number; mode?: "auto" | "extend" | "separate"; targetID?: string;
    selectedID?: string; paintColor: RGBColor; matchToThreadLibrary: boolean; palette?: ThreadColor[];
  }) => postJSON<EditResponse | PendingMerge>("/edit/paint", body),
  classify: (document: StitchDocument, objectIDs: string[]) => postJSON<EditResponse>("/edit/classify", { document, objectIDs }),
  lettering: (body: { document: StitchDocument; shapes: VectorShape[]; capHeightMM: number; threadColor: ThreadColor; targetCenter: Point2D; replaceIDs?: string[] }) =>
    postJSON<EditResponse>("/edit/lettering", body),

  async export(document: StitchDocument, format: string): Promise<Blob> {
    const res = await fetch(`${BASE}/export/${format}`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ document }),
    });
    return (await check(res)).blob();
  },
};

export { ApiError };
