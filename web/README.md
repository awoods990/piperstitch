# PiperStitch web app

The browser edition of PiperStitch: React + TypeScript, built with Vite.
It drives the API in `server/`, which runs the same digitizing engine as
the Mac app. See `ARCHITECTURE.md` → "The web edition".

## Run it

Start the server first (see `server/README.md`), then:

```bash
cd web && npm install && npm run dev
```

Open <http://localhost:5173>. The dev server proxies `/api` to
`localhost:8080`, so there's no CORS setup.

`npm run build` type-checks and writes `dist/`, which the Docker image
copies into the server's `Public/` folder.

## Layout

```
src/
  App.tsx              The AppState of the web edition: import, answers, document, digitize result, phases
  api.ts               Typed client for server/'s endpoints
  types.ts             Mirrors of the Swift model + wire types (field names must match)
  decode.ts            File -> straight-alpha RGBA in the browser (the web edition's image decoder)
  render.ts            Stitch plan -> <canvas>, same technique as StitchRenderer
  components/
    DropZone.tsx       Start screen
    SetupFlow.tsx      The five after-import questions (mirrors ImportSetupSheet, same copy)
    Editor.tsx         Canvas + sidebar (readiness, downloads, stats, size, hoop, fabric, colours, objects)
    StitchCanvas.tsx   Pan/zoom canvas
  styles.css           Palette from the Mac app's Theme.swift
```

## How the two editions relate

Anything about *how it sews* lives in `StitchPilotCore` and reaches both
editions automatically. Anything about *how it looks or is operated* is
per-edition: SwiftUI in `Sources/StitchPilotApp`, React here. Keep
`types.ts` in step with the Swift model when fields are added.
