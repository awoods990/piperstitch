// Lettering in the browser: a port of StitchPilotCore's LetteringGenerator
// with opentype.js standing in for CoreText. Produces one VectorShape per
// glyph in millimetres (Y down), sized so the font's cap height equals
// `fontSizeMM`, optionally remapped onto an arc -- the same numbers the Mac
// app gets from CTFontCreatePathForGlyph, flattened at the same 28
// segments per curve. The server then classifies the run and builds the
// objects (POST /api/v1/edit/lettering), exactly as AppState does.

import { parse as parseFont, type Font } from "opentype.js";
import type { Point2D, VectorShape } from "./types";

import roboto from "@fontsource/roboto/files/roboto-latin-700-normal.woff?url";
import openSans from "@fontsource/open-sans/files/open-sans-latin-700-normal.woff?url";
import montserrat from "@fontsource/montserrat/files/montserrat-latin-700-normal.woff?url";
import oswald from "@fontsource/oswald/files/oswald-latin-700-normal.woff?url";
import playfair from "@fontsource/playfair-display/files/playfair-display-latin-700-normal.woff?url";
import merriweather from "@fontsource/merriweather/files/merriweather-latin-700-normal.woff?url";
import alfaSlab from "@fontsource/alfa-slab-one/files/alfa-slab-one-latin-400-normal.woff?url";
import anton from "@fontsource/anton/files/anton-latin-400-normal.woff?url";
import bebas from "@fontsource/bebas-neue/files/bebas-neue-latin-400-normal.woff?url";
import lobster from "@fontsource/lobster/files/lobster-latin-400-normal.woff?url";
import pacifico from "@fontsource/pacifico/files/pacifico-latin-400-normal.woff?url";
import dancing from "@fontsource/dancing-script/files/dancing-script-latin-700-normal.woff?url";

export interface LetteringFont { id: string; displayName: string; group: string; url: string }

/** Bold weights where the family has one -- embroidery wants stroke width. */
export const LETTERING_FONTS: LetteringFont[] = [
  { id: "roboto", displayName: "Roboto Bold", group: "Sans-serif", url: roboto },
  { id: "open-sans", displayName: "Open Sans Bold", group: "Sans-serif", url: openSans },
  { id: "montserrat", displayName: "Montserrat Bold", group: "Sans-serif", url: montserrat },
  { id: "oswald", displayName: "Oswald Bold", group: "Sans-serif", url: oswald },
  { id: "anton", displayName: "Anton", group: "Sans-serif", url: anton },
  { id: "bebas-neue", displayName: "Bebas Neue", group: "Sans-serif", url: bebas },
  { id: "playfair", displayName: "Playfair Display Bold", group: "Serif", url: playfair },
  { id: "merriweather", displayName: "Merriweather Bold", group: "Serif", url: merriweather },
  { id: "alfa-slab", displayName: "Alfa Slab One", group: "Serif", url: alfaSlab },
  { id: "lobster", displayName: "Lobster", group: "Script", url: lobster },
  { id: "pacifico", displayName: "Pacifico", group: "Script", url: pacifico },
  { id: "dancing-script", displayName: "Dancing Script Bold", group: "Script", url: dancing },
];

export interface LetteringSpec {
  text: string;
  fontID: string;
  /** Capital-letter height in mm (not a point size). */
  fontSizeMM: number;
  letterSpacingMM: number;
  /** null = straight baseline; otherwise the ring radius in mm. */
  arcRadiusMM: number | null;
}

const CURVE_SEGMENTS = 28;
const REFERENCE_SIZE = 200;
const fontCache = new Map<string, Promise<Font>>();

export function loadFont(id: string): Promise<Font> {
  const entry = LETTERING_FONTS.find((f) => f.id === id);
  if (!entry) return Promise.reject(new Error(`Couldn't find the font "${id}".`));
  let p = fontCache.get(id);
  if (!p) {
    p = fetch(entry.url).then((r) => r.arrayBuffer()).then((buf) => parseFont(buf));
    fontCache.set(id, p);
  }
  return p;
}

/** The font's cap height in font units, measured from "H" when the OS/2 table doesn't say. */
function capHeightUnits(font: Font): number {
  const os2 = (font.tables as { os2?: { sCapHeight?: number } }).os2;
  if (os2?.sCapHeight && os2.sCapHeight > 0) return os2.sCapHeight;
  const h = font.charToGlyph("H");
  const bb = h.getBoundingBox();
  return bb.y2 - bb.y1 > 0 ? bb.y2 - bb.y1 : font.unitsPerEm * 0.7;
}

export async function generateLetteringShapes(spec: LetteringSpec): Promise<VectorShape[]> {
  if (!spec.text) throw new Error("Enter some text to generate lettering.");
  const font = await loadFont(spec.fontID);
  const capHeightPt = (capHeightUnits(font) / font.unitsPerEm) * REFERENCE_SIZE;
  const mmPerPoint = spec.fontSizeMM / capHeightPt;
  const extraSpacingPt = mmPerPoint > 0 ? spec.letterSpacingMM / mmPerPoint : 0;

  const straight: Point2D[][] = [];
  const glyphSubPathCounts: number[] = [];
  let maxAdvanceX = 0;
  let x = 0;
  // One glyph per character, no substitution pass: ligatures would fuse
  // letters into one object (and opentype.js can't parse some fonts'
  // ligature tables at all). Kerning is still applied below.
  const glyphs = Array.from(spec.text).map((ch) => font.charToGlyph(ch));
  const scale = REFERENCE_SIZE / font.unitsPerEm;
  for (let i = 0; i < glyphs.length; i++) {
    const glyph = glyphs[i];
    const originX = x + i * extraSpacingPt;
    maxAdvanceX = Math.max(maxAdvanceX, originX);
    const path = glyph.getPath(0, 0, REFERENCE_SIZE); // font units -> points, Y up
    const subPaths = flatten(path.commands);
    if (subPaths.length > 0) {
      for (const sp of subPaths) straight.push(sp.map((p) => ({ x: (p.x + originX) * mmPerPoint, y: (p.y) * mmPerPoint })));
      glyphSubPathCounts.push(subPaths.length);
    }
    let advance = (glyph.advanceWidth ?? 0) * scale;
    if (i + 1 < glyphs.length) { try { advance += font.getKerningValue(glyph, glyphs[i + 1]) * scale; } catch { /* no usable kern table */ } }
    x += advance;
  }
  if (straight.length === 0) throw new Error("This text produced no visible letterforms (all whitespace, or characters this font doesn't have).");

  const totalWidthMM = maxAdvanceX * mmPerPoint;
  const remapped = spec.arcRadiusMM ? straight.map((sp) => sp.map((p) => remapToArc(p, totalWidthMM, spec.arcRadiusMM!))) : straight;

  const shapes: VectorShape[] = [];
  let cursor = 0;
  for (const count of glyphSubPathCounts) {
    const subPaths = [];
    for (let k = 0; k < count; k++) subPaths.push({ points: remapped[cursor++], closed: true });
    shapes.push({ subPaths });
  }
  return shapes;
}

function remapToArc(point: Point2D, totalWidthMM: number, radiusMM: number): Point2D {
  if (radiusMM === 0) return point;
  const centeredX = point.x - totalWidthMM / 2;
  const theta = centeredX / radiusMM;
  const effectiveRadius = radiusMM - point.y;
  return { x: effectiveRadius * Math.sin(theta), y: effectiveRadius * (1 - Math.cos(theta)) - (effectiveRadius - radiusMM) };
}

type Cmd = { type: string; x?: number; y?: number; x1?: number; y1?: number; x2?: number; y2?: number };

/** opentype.js paths are already Y-down (it flips for canvas), matching our convention. */
function flatten(commands: Cmd[]): Point2D[][] {
  const subPaths: Point2D[][] = [];
  let current: Point2D[] = [];
  let cur: Point2D = { x: 0, y: 0 };
  let start: Point2D = { x: 0, y: 0 };
  const finish = () => { if (current.length > 2) subPaths.push(current); current = []; };
  for (const c of commands) {
    switch (c.type) {
      case "M": finish(); cur = start = { x: c.x!, y: c.y! }; current = [cur]; break;
      case "L": cur = { x: c.x!, y: c.y! }; current.push(cur); break;
      case "Q": {
        const p0 = cur, p1 = { x: c.x1!, y: c.y1! }, p2 = { x: c.x!, y: c.y! };
        for (let i = 1; i <= CURVE_SEGMENTS; i++) {
          const t = i / CURVE_SEGMENTS, mt = 1 - t, a = mt * mt, b = 2 * mt * t, d = t * t;
          current.push({ x: a * p0.x + b * p1.x + d * p2.x, y: a * p0.y + b * p1.y + d * p2.y });
        }
        cur = p2; break;
      }
      case "C": {
        const p0 = cur, p1 = { x: c.x1!, y: c.y1! }, p2 = { x: c.x2!, y: c.y2! }, p3 = { x: c.x!, y: c.y! };
        for (let i = 1; i <= CURVE_SEGMENTS; i++) {
          const t = i / CURVE_SEGMENTS, mt = 1 - t, a = mt ** 3, b = 3 * mt * mt * t, d = 3 * mt * t * t, e = t ** 3;
          current.push({ x: a * p0.x + b * p1.x + d * p2.x + e * p3.x, y: a * p0.y + b * p1.y + d * p2.y + e * p3.y });
        }
        cur = p3; break;
      }
      case "Z": cur = start; break;
    }
  }
  finish();
  return subPaths;
}
