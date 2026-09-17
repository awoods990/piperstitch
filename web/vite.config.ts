import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// In development the API is the Swift server on :8080 (server/); proxying
// /api keeps the browser on one origin so there's no CORS to think about.
// In production the server itself serves this build (see Dockerfile).
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    // API_TARGET lets a dev point /api at something else (e.g. a mock of the
    // account endpoints in front of the real engine) without editing this.
    proxy: { "/api": { target: process.env.API_TARGET ?? "http://localhost:8080", changeOrigin: true } },
  },
  build: { outDir: "dist", sourcemap: false },
});
