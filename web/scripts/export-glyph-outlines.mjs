// Writes each lettering font's glyph outlines as flattened polygons in
// cap-height units (1000 per cap height, origin at the baseline's left,
// y down -- the frame the web app places glyphs in), for
// `DigitizeCLI --build-glyph-library`. Uses the very font files the app
// ships (@fontsource) through opentype.js, so the library matches what
// the browser draws.
//
//   node scripts/export-glyph-outlines.mjs <outDir>
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { createRequire } from "node:module";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const opentype = require("opentype.js");
const here = dirname(fileURLToPath(import.meta.url));
const outDir = resolve(process.argv[2] ?? resolve(here, "../glyph-outlines"));
mkdirSync(outDir, { recursive: true });

// Mirrors LETTERING_FONTS in src/lettering.ts (ids and files).
const FONTS = {
  "roboto": "@fontsource/roboto/files/roboto-latin-700-normal.woff",
  "open-sans": "@fontsource/open-sans/files/open-sans-latin-700-normal.woff",
  "montserrat": "@fontsource/montserrat/files/montserrat-latin-700-normal.woff",
  "oswald": "@fontsource/oswald/files/oswald-latin-700-normal.woff",
  "playfair": "@fontsource/playfair-display/files/playfair-display-latin-700-normal.woff",
  "merriweather": "@fontsource/merriweather/files/merriweather-latin-700-normal.woff",
  "alfa-slab": "@fontsource/alfa-slab-one/files/alfa-slab-one-latin-400-normal.woff",
  "anton": "@fontsource/anton/files/anton-latin-400-normal.woff",
  "bebas-neue": "@fontsource/bebas-neue/files/bebas-neue-latin-400-normal.woff",
  "lobster": "@fontsource/lobster/files/lobster-latin-400-normal.woff",
  "pacifico": "@fontsource/pacifico/files/pacifico-latin-400-normal.woff",
  "dancing-script": "@fontsource/dancing-script/files/dancing-script-latin-700-normal.woff",
};

const ASCII = Array.from({ length: 126 - 33 + 1 }, (_, i) => String.fromCharCode(33 + i));
const EXTRA = Array.from("‘’“”–—…•£€¥©®°ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÑÒÓÔÕÖØÙÚÛÜÝßàáâãäåæçèéêëìíîïñòóôõöøùúûüýÿŒœŠšŽž");
const CHARS = [...ASCII, ...EXTRA];

function capHeightUnits(font) {
  const os2 = font.tables.os2;
  if (os2?.sCapHeight > 0) return os2.sCapHeight;
  const bb = font.charToGlyph("H").getBoundingBox();
  return bb.y2 - bb.y1 > 0 ? bb.y2 - bb.y1 : font.unitsPerEm * 0.7;
}

// Flatten a path (opentype.js commands, already y-down) into closed polygons.
function flatten(commands) {
  const contours = []; let current = null; let last = null;
  const push = (p) => { if (current && (!last || Math.hypot(p.x - last.x, p.y - last.y) > 0.5)) { current.push(p); last = p; } };
  for (const c of commands) {
    if (c.type === "M") { if (current && current.length >= 3) contours.push(current); current = []; last = null; push({ x: c.x, y: c.y }); }
    else if (c.type === "L") push({ x: c.x, y: c.y });
    else if (c.type === "Q") { const p0 = last; for (let i = 1; i <= 8; i++) { const t = i / 8, u = 1 - t; push({ x: u*u*p0.x + 2*u*t*c.x1 + t*t*c.x, y: u*u*p0.y + 2*u*t*c.y1 + t*t*c.y }); } }
    else if (c.type === "C") { const p0 = last; for (let i = 1; i <= 10; i++) { const t = i / 10, u = 1 - t; push({ x: u*u*u*p0.x + 3*u*u*t*c.x1 + 3*u*t*t*c.x2 + t*t*t*c.x, y: u*u*u*p0.y + 3*u*u*t*c.y1 + 3*u*t*t*c.y2 + t*t*t*c.y }); } }
    else if (c.type === "Z") { if (current && current.length >= 3) contours.push(current); current = null; last = null; }
  }
  if (current && current.length >= 3) contours.push(current);
  return contours;
}

for (const [id, file] of Object.entries(FONTS)) {
  const buf = readFileSync(require.resolve(file));
  const font = opentype.parse(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));
  const cap = capHeightUnits(font);
  const fontSize = 1000 * font.unitsPerEm / cap; // so a capital is 1000 units tall
  const scale = fontSize / font.unitsPerEm;
  const glyphs = {};
  for (const ch of CHARS) {
    const glyph = font.charToGlyph(ch);
    if (!glyph || glyph.index === 0) continue;
    const contours = flatten(glyph.getPath(0, 0, fontSize).commands);
    if (contours.length === 0) continue;
    glyphs[ch] = { advance: Math.round((glyph.advanceWidth ?? 0) * scale), contours: contours.map((c) => c.map((p) => [Math.round(p.x * 10) / 10, Math.round(p.y * 10) / 10])) };
  }
  const out = resolve(outDir, `${id}.outlines.json`);
  writeFileSync(out, JSON.stringify({ fontID: id, capHeightUnits: 1000, glyphs }));
  console.log(`${id}: ${Object.keys(glyphs).length} glyphs -> ${out}`);
}
