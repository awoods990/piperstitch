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

Plan command codes: 0 stitch, 1 jump, 2 colour change, 3 trim, 4 stop,
5 end. Coordinates are design millimetres rounded to 0.01.

Which `AppState` method each endpoint mirrors is noted in
`Sources/StitchPilotServer/Engine.swift`; when the Mac app's import or
resize logic changes, change it there too (or better, move the shared
piece into `StitchPilotCore`).
