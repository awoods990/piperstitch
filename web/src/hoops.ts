import type { CatalogSize } from "./types";

/** Hoops grouped for display: the generic sizes first, then each branded
 *  line under its own heading, so a 40-entry list reads as three short
 *  ones. Order within a group is the catalog's own. */
export function hoopGroups(hoops: CatalogSize[]): [string, CatalogSize[]][] {
  const mighty = hoops.filter((h) => h.name.startsWith("Mighty Hoop"));
  const durkee = hoops.filter((h) => h.name.startsWith("Durkee"));
  const standard = hoops.filter((h) => !mighty.includes(h) && !durkee.includes(h));
  return ([["Standard hoops", standard], ["Mighty Hoop (magnetic)", mighty], ["Durkee EZ Frame", durkee]] as [string, CatalogSize[]][])
    .filter(([, list]) => list.length > 0);
}

const isBranded = (h: CatalogSize) => h.name.startsWith("Mighty Hoop") || h.name.startsWith("Durkee");

/** The smallest hoop the design fits in. Prefers the generic sizes, which
 *  nearly every machine has, over a branded frame the user may not own --
 *  a branded one is only picked when no generic hoop fits at all. */
export function smallestHoopThatFits(hoops: CatalogSize[], widthMM: number, heightMM: number): CatalogSize | null {
  const fits = hoops.filter((h) => h.widthMM >= widthMM && h.heightMM >= heightMM);
  const byArea = (a: CatalogSize, b: CatalogSize) => a.widthMM * a.heightMM - b.widthMM * b.heightMM;
  const generic = fits.filter((h) => !isBranded(h)).sort(byArea);
  if (generic.length > 0) return generic[0];
  return fits.sort(byArea)[0] ?? null;
}
