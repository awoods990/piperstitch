"""The admin's view of a customer's saved project -- for support, and only
under the Privacy Policy's "when you ask us for help with a specific
project" exception: the page requires a stated reason and the access is
logged on the customer's timeline.

A saved project is the StitchDocument (traced shapes + every parameter),
never the original pixels (the policy says those are discarded), so the
"input" shown is the traced artwork outline. The stitch preview comes
from asking the app server to re-digitize the document."""

from __future__ import annotations

import html
import logging
from typing import Optional

import httpx

from . import config

log = logging.getLogger("license_admin")

STITCH_LABELS = {"runningStitch": "Running stitch", "tripleRun": "Triple run", "satin": "Satin", "tatamiFill": "Fill"}


def digitize(document: dict, *, hoop_width_mm: Optional[float] = None, hoop_height_mm: Optional[float] = None) -> Optional[dict]:
    """Asks the app server for the plan; None if it can't be reached."""
    try:
        r = httpx.post(f"{config.APP_SERVER_URL}/api/v1/internal/digitize", json={"document": document, "hoopWidthMM": hoop_width_mm, "hoopHeightMM": hoop_height_mm},
                       headers={"X-API-Key": config.WEB_API_KEY}, timeout=60)
        if r.status_code != 200:
            log.warning("App server digitize returned %s: %s", r.status_code, r.text[:200])
            return None
        return r.json()
    except httpx.HTTPError as e:
        log.warning("App server unreachable for project view: %s", e)
        return None


def _rgb(c: dict) -> str:
    return f"rgb({c['r']},{c['g']},{c['b']})"


def outlines_svg(document: dict) -> str:
    """The traced artwork: each object's outline filled in its thread colour."""
    w, h = float(document.get("physicalWidthMM") or 1), float(document.get("physicalHeightMM") or 1)
    parts = []
    for o in document.get("objects", []):
        d = " ".join("M" + " L".join(f"{p['x']:.2f} {p['y']:.2f}" for p in sp["points"]) + " Z" for sp in o["shape"]["subPaths"] if sp["points"])
        parts.append(f'<path d="{d}" fill="{_rgb(o["threadColor"]["rgb"])}" fill-opacity="0.85" stroke="rgba(0,0,0,0.35)" stroke-width="0.15" fill-rule="evenodd"><title>{html.escape(o["name"])}</title></path>')
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="-2 -2 {w + 4:.1f} {h + 4:.1f}" style="width:100%;height:auto;background:#f7f3ec;border-radius:8px"><rect x="0" y="0" width="{w:.1f}" height="{h:.1f}" fill="none" stroke="rgba(0,0,0,0.15)" stroke-width="0.2"/>{"".join(parts)}</svg>'


def plan_svg(document: dict, digitized: dict) -> str:
    """Stitches as thread-width polylines per colour run -- the same
    information as the app's canvas, drawn simply."""
    w, h = float(document.get("physicalWidthMM") or 1), float(document.get("physicalHeightMM") or 1)
    colors = digitized.get("colors") or []
    runs: list[tuple[int, list[str]]] = []
    color_index, current, last = 0, [], None
    for code, x, y in digitized["plan"]["commands"]:
        if code == 0:
            if last is not None:
                if not current:
                    current.append(f"{last[0]:.2f},{last[1]:.2f}")
                current.append(f"{x:.2f},{y:.2f}")
            last = (x, y)
        elif code == 1:
            if current:
                runs.append((color_index, current)); current = []
            last = (x, y)
        elif code == 2:
            if current:
                runs.append((color_index, current)); current = []
            color_index += 1; last = None
        elif code in (3, 4):
            if current:
                runs.append((color_index, current)); current = []
            last = None
    if current:
        runs.append((color_index, current))
    parts = []
    for ci, pts in runs:
        c = colors[min(ci, len(colors) - 1)]["rgb"] if colors else {"r": 40, "g": 40, "b": 40}
        parts.append(f'<polyline points="{" ".join(pts)}" fill="none" stroke="{_rgb(c)}" stroke-width="0.35" stroke-linecap="round" stroke-linejoin="round"/>')
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="-2 -2 {w + 4:.1f} {h + 4:.1f}" style="width:100%;height:auto;background:#f7f3ec;border-radius:8px"><rect x="0" y="0" width="{w:.1f}" height="{h:.1f}" fill="none" stroke="rgba(0,0,0,0.15)" stroke-width="0.2"/>{"".join(parts)}</svg>'


def object_rows(document: dict) -> list[dict]:
    """One row per object with the parameters that decide how it sews."""
    rows = []
    for o in document.get("objects", []):
        p = o.get("parameters", {})
        st = o.get("stitchType")
        if st == "satin":
            key = f"density {p.get('satinDensityMM', 0):.2f} mm · width {p.get('minSatinWidthMM', 0):.1f}–{p.get('maxSatinWidthMM', 0):.1f} mm"
        elif st == "tatamiFill":
            angle = p.get("fillAngleDegrees")
            key = f"row spacing {p.get('fillSpacingMM', 0):.2f} mm · {p.get('fillPattern', 'rows')} · angle {'auto' if angle is None else f'{angle:g}°'}"
        else:
            key = f"stitch length {p.get('stitchLengthMM', 0):.1f} mm"
        pull, push = p.get("pullCompensationMM"), p.get("pushCompensationMM")
        rows.append({
            "name": o.get("name"), "stitch_type": STITCH_LABELS.get(st, st), "manual": bool(o.get("stitchTypeIsManualOverride")),
            "color": o.get("threadColor", {}).get("name"), "rgb": _rgb(o.get("threadColor", {}).get("rgb", {"r": 0, "g": 0, "b": 0})),
            "key": key, "underlay": p.get("underlayType") or "automatic", "fabric": p.get("fabricType", "standard"),
            "compensation": f"pull {'auto' if pull is None else f'{pull:.2f} mm'} · push {'auto' if push is None else f'{push:.2f} mm'}",
            "applique": bool(o.get("isApplique")), "subpaths": len(o.get("shape", {}).get("subPaths", [])),
        })
    return rows
