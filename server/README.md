# PiperStitch web server

The web edition's HTTP API: a thin [Vapor](https://vapor.codes) wrapper
around the very same `StitchPilotCore` the Mac app uses. This is its own
SwiftPM package, depending on the root package by path, so nothing about
the root package or the Mac app changes for the web's sake. See
`ARCHITECTURE.md` → "The web edition" for how the pieces fit.

## Run it locally (macOS)

```bash
cd server && swift build -c release && .build/release/StitchPilotServer serve --env development
```

The API is on `http://localhost:8080/api/v1/` (`/health` to check). Use a
release build — the image tracing and fills are 30–50× slower in debug.
Then run the browser app from `web/` (its dev server proxies `/api` here).

Environment: `PORT` (8080), `HOST` (0.0.0.0), `CORS_ORIGINS`
(comma-separated; defaults to the Vite dev server's origins). In
production the server serves the built browser app from `Public/` on the
same origin, so CORS is normally moot.

### Accounts

With `LICENSE_ADMIN_URL` unset the server runs **without accounts**: every
route is open and `/api/v1/auth/me` reports `authEnabled: false`. Fine for
development, never for production. To turn accounts on:

| Variable | Meaning |
|---|---|
| `LICENSE_ADMIN_URL` | Base URL of License Admin (e.g. `https://admin.piperstitch.com`) |
| `WEB_API_KEY` | The same value as License Admin's `WEB_API_KEY` |
| `SESSION_SECRET` | 32+ random characters; signs the browser's session cookie |

License Admin is the authority (customers, the 14-day trial, Stripe's
mirror, saved projects); this server calls its `/api/web/*` endpoints
server-to-server and gives the browser an HttpOnly, signed `ps_session`
cookie carrying the License Admin session token plus a cached copy of the
account's standing, re-checked every 2 hours or as soon as the cached
period expires. The engine routes require a signed-in, entitled account;
`catalog` and `health` never do. See `LICENSING.md` → "The web edition".

To run the whole thing locally, start License Admin with a file outbox
so sign-in codes land in a folder instead of a mailbox:

```bash
cd license-admin && EMAIL_OUTBOX_DIR=./outbox WEB_API_KEY=devwebkey DATABASE_PATH=./dev.db .venv/bin/python -m uvicorn app.main:app --port 8000
```

```bash
cd server && LICENSE_ADMIN_URL=http://localhost:8000 WEB_API_KEY=devwebkey SESSION_SECRET=0123456789abcdef0123456789abcdef .build/release/StitchPilotServer serve
```

## Build for Linux (Docker, from the repo root)

```bash
docker build -f server/Dockerfile -t piperstitch-web .
```

```bash
docker run --rm -p 8080:8080 piperstitch-web
```

The image contains the release server binary and the built `web/` app
(served from `/app/Public`). `.github/workflows/web.yml` builds all of
this on every push, which is how the Linux build is verified from a Mac
without Docker installed.

## API

Everything is stateless: the browser holds the document and sends it
back. All bodies and responses are JSON except the two imports (raw
bytes in) and export (file bytes out).

| Method & path | In | Out |
|---|---|---|
| `GET /api/v1/health` | — | `{status:"ok"}` |
| `GET /api/v1/catalog` | — | hoops, garment presets, fabrics, colour presets, thread palette, stitch types, fill patterns, underlay types, export formats, default parameters |
| `POST /api/v1/import/raster?width=&height=&maxColors=&hoopWidthMM=&hoopHeightMM=` | straight-alpha RGBA, row-major, top row first; `Content-Encoding: gzip` welcome | `{source, recommendedWidthMM, recommendedHeightMM, aspectRatio}` |
| `POST /api/v1/import/svg?hoopWidthMM=&hoopHeightMM=` | SVG text | same |
| `POST /api/v1/build` | `{source, name, widthMM, heightMM, matchToThreadLibrary?, palette?, fabricType?}` | `{document}` |
| `POST /api/v1/resize` | `{document, widthMM, heightMM}` | `{document}` |
| `POST /api/v1/digitize` | `{document, hoopWidthMM?, hoopHeightMM?}` | `{plan:{commands:[[code,x,y]…]}, colors, report, stats, elapsedMS}` |
| `POST /api/v1/export/{dst|pes|jef|exp|vp3}` | `{document}` | the machine file (`Content-Disposition: attachment`) |
| `GET /api/v1/auth/me[?refresh=1]` | — | `{authEnabled, signedIn, account?}` |
| `POST /api/v1/auth/request` | `{email}` | `{sent}` — emails a six-digit code |
| `POST /api/v1/auth/verify` | `{email, code}` | sets the session cookie; same shape as `me`. First verified sign-in starts the trial |
| `POST /api/v1/auth/signout` | — | 204, cookie cleared |
| `POST /api/v1/auth/checkout` | — | `{url}` — Stripe Checkout for this account |
| `POST /api/v1/auth/billing-portal` | — | `{url}` — Stripe's portal (404 on a trial) |
| `GET /api/v1/projects` | — | `[{id, name, widthMM, heightMM, objectCount, createdAt, updatedAt}]` |
| `GET /api/v1/projects/{id}` | — | `{id, name, updatedAt, document}` |
| `PUT /api/v1/projects/{id}` | `{name, document}` | `{created}` — id is the browser's UUID, so a re-save is idempotent |
| `DELETE /api/v1/projects/{id}` | — | `{deleted}` |

Plan command codes: 0 stitch, 1 jump, 2 colour change, 3 trim, 4 stop,
5 end. Coordinates are design millimetres rounded to 0.01.

Which `AppState` method each endpoint mirrors is noted in
`Sources/StitchPilotServer/Engine.swift`; when the Mac app's import or
resize logic changes, change it there too (or better, move the shared
piece into `StitchPilotCore`).
