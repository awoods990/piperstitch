import type { CatalogSize } from "./types";

/** Hoops grouped for display: the generic sizes first, then each branded
 *  line under its own heading, so a 40-entry list reads as three short
 *  ones. Order within a group is the catalog's own. */
export function hoopGroups(hoops: CatalogSize[], ownedNames: string[] = []): [string, CatalogSize[]][] {
  const owned = ownedNames.length > 0 ? hoops.filter((h) => ownedNames.includes(h.name)) : [];
  const rest = hoops.filter((h) => !owned.includes(h));
  const mighty = rest.filter((h) => h.name.startsWith("Mighty Hoop"));
  const durkee = rest.filter((h) => h.name.startsWith("Durkee"));
  const standard = rest.filter((h) => !mighty.includes(h) && !durkee.includes(h));
  // The hoops the business told guided setup it owns come first, under
  // their own heading; everything else keeps its catalog grouping.
  return ([["Your hoops", owned], ["Standard hoops", standard], ["Mighty Hoop (magnetic)", mighty], ["Durkee EZ Frame", durkee]] as [string, CatalogSize[]][])
    .filter(([, list]) => list.length > 0);
}

const isBranded = (h: CatalogSize) => h.name.startsWith("Mighty Hoop") || h.name.startsWith("Durkee");

/** The smallest hoop the design fits in. Prefers the generic sizes, which
 *  nearly every machine has, over a branded frame the user may not own --
 *  a branded one is only picked when no generic hoop fits at all. */
export function smallestHoopThatFits(hoops: CatalogSize[], widthMM: number, heightMM: number, ownedNames: string[] = []): CatalogSize | null {
  const fits = hoops.filter((h) => h.widthMM >= widthMM && h.heightMM >= heightMM);
  const byArea = (a: CatalogSize, b: CatalogSize) => a.widthMM * a.heightMM - b.widthMM * b.heightMM;
  // A hoop they actually own beats any generic size.
  const owned = fits.filter((h) => ownedNames.includes(h.name)).sort(byArea);
  if (owned.length > 0) return owned[0];
  const generic = fits.filter((h) => !isBranded(h)).sort(byArea);
  if (generic.length > 0) return generic[0];
  return fits.sort(byArea)[0] ?? null;
}
