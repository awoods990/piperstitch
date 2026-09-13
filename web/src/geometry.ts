import type { BoundingBox, EmbroideryObject, Point2D, VectorShape } from "./types";

export const EMPTY_BOX: BoundingBox = { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };

export function shapeBounds(shape: VectorShape): BoundingBox {
  let b = { ...EMPTY_BOX };
  for (const sp of shape.subPaths) for (const p of sp.points) {
    if (p.x < b.minX) b.minX = p.x; if (p.x > b.maxX) b.maxX = p.x;
    if (p.y < b.minY) b.minY = p.y; if (p.y > b.maxY) b.maxY = p.y;
  }
  return b;
}

export function unionBounds(a: BoundingBox, b: BoundingBox): BoundingBox {
  return { minX: Math.min(a.minX, b.minX), minY: Math.min(a.minY, b.minY), maxX: Math.max(a.maxX, b.maxX), maxY: Math.max(a.maxY, b.maxY) };
}

export const boxIsEmpty = (b: BoundingBox) => b.minX > b.maxX || b.minY > b.maxY;
export const boxesIntersect = (a: BoundingBox, b: BoundingBox) => a.minX <= b.maxX && b.minX <= a.maxX && a.minY <= b.maxY && b.minY <= a.maxY;

/** Even-odd rule across every sub-path, so a letter's counter reads as a hole. */
export function shapeContains(shape: VectorShape, p: Point2D): boolean {
  let inside = false;
  for (const sp of shape.subPaths) {
    const pts = sp.points;
    for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
      const a = pts[i], b = pts[j];
      if ((a.y > p.y) !== (b.y > p.y) && p.x < ((b.x - a.x) * (p.y - a.y)) / (b.y - a.y) + a.x) inside = !inside;
    }
  }
  return inside;
}

/** Topmost object under the point (later objects sew on top). */
export function objectAt(objects: EmbroideryObject[], p: Point2D): EmbroideryObject | null {
  for (let i = objects.length - 1; i >= 0; i--) {
    const b = shapeBounds(objects[i].shape);
    if (p.x < b.minX || p.x > b.maxX || p.y < b.minY || p.y > b.maxY) continue;
    if (shapeContains(objects[i].shape, p)) return objects[i];
  }
  return null;
}

export function transformShape(shape: VectorShape, fn: (p: Point2D) => Point2D): VectorShape {
  return { subPaths: shape.subPaths.map((sp) => ({ ...sp, points: sp.points.map(fn) })) };
}

export function selectionBounds(objects: EmbroideryObject[], ids: Set<string>): BoundingBox {
  let b = { ...EMPTY_BOX };
  for (const o of objects) if (ids.has(o.id)) b = unionBounds(b, shapeBounds(o.shape));
  return b;
}
