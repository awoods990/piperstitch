// Which thread manufacturer(s) a user actually sews with, shown alongside
// the Thread Library editor: the reference notes below (fiber/weight,
// well-known handling differences), plus a browsable catalog per line so
// the color names they type in ("Madeira 1147 Red") mean something and
// they can pull in the specific numbered shades they actually stock
// instead of typing every one by hand.
//
// Catalog data (web/public/thread-catalogs/*.json, ~4,700 colors total)
// is color name + catalog number + an RGB approximation, sourced from
// Ink/Stitch (inkstitch.org, GPLv3 project) -- itself compiled from each
// manufacturer's own published color names and numbers, made public by
// the manufacturers themselves to promote their product and help
// customers match colors. Treated here as factual reference data (a
// name/number belongs to a real, purchasable spool; the RGB is a visual
// approximation of it), not as copying protectable creative expression --
// the same category this project already treats the Brother/Janome
// on-machine thread tables as, and consistent with legal review of this
// specific question before the data was added. Credited here as the
// source of that data, not as a license-compliance mechanism.

export interface ThreadCatalogRef {
  label: string;
  file: string;
}

export interface ThreadSupplier {
  id: string;
  name: string;
  lines: string;
  guidance: string;
  catalogs: ThreadCatalogRef[];
}

export const THREAD_SUPPLIERS: ThreadSupplier[] = [
  {
    id: "isacord",
    name: "Isacord",
    lines: "100% polyester, 40wt (Tex 27)",
    guidance: "The de facto default most digitizing software assumes when nothing else is specified. Runs clean at high machine speed with low lint. A universal 75/11–80/12 embroidery needle is the standard pairing; drop to 60wt only for lettering under about 5mm.",
    catalogs: [{ label: "Isacord", file: "isacord.json" }],
  },
  {
    id: "madeira",
    name: "Madeira",
    lines: "Polyneon (polyester) or Classic Rayon",
    guidance: "Polyneon is the durable, colorfast choice for anything that gets washed or bleached often (workwear, towels); Classic Rayon has more sheen and a softer hand but holds up to laundering and chlorine less well. Both are commonly stocked at 40wt.",
    catalogs: [
      { label: "Polyneon", file: "madeira-polyneon.json" },
      { label: "Classic Rayon", file: "madeira-rayon.json" },
    ],
  },
  {
    id: "robison-anton",
    name: "Robison-Anton",
    lines: "Rayon (2000 series) or Polyester (5000/9000 series)",
    guidance: "A US commercial-embroidery staple, organized by these number-series product lines rather than a single catalog. Rayon gives the glossiest finish; polyester trades a little sheen for meaningfully better durability.",
    catalogs: [
      { label: "Polyester", file: "robison-anton-polyester.json" },
      { label: "Rayon", file: "robison-anton-rayon.json" },
    ],
  },
  {
    id: "sulky",
    name: "Sulky",
    lines: "Rayon, polyester, or cotton",
    guidance: "Popular with home and quilting machines as much as commercial ones. Available at both 30wt and 40wt — 30wt lays down bolder coverage in fewer stitches, useful for large fill areas; 40wt is the general-purpose default.",
    catalogs: [
      { label: "Polyester", file: "sulky-polyester.json" },
      { label: "Rayon", file: "sulky-rayon.json" },
    ],
  },
  {
    id: "hemingworth",
    name: "Hemingworth",
    lines: "100% polyester, 40wt",
    guidance: "A budget-friendly polyester line widely used in commercial and promotional embroidery shops running high volume.",
    catalogs: [{ label: "Polyester", file: "hemingworth.json" }],
  },
  {
    id: "floriani",
    name: "Floriani",
    lines: "100% polyester, 40wt",
    guidance: "Aimed at the home and small-shop embroidery market, marketed for smooth, low-lint machine performance.",
    catalogs: [{ label: "Polyester", file: "floriani-polyester.json" }],
  },
  {
    id: "marathon",
    name: "Marathon",
    lines: "Polyester or rayon",
    guidance: "A commercial embroidery supplier with both fiber lines available, most often stocked at 40wt like the others here.",
    catalogs: [
      { label: "Polyester", file: "marathon-polyester.json" },
      { label: "Rayon", file: "marathon-rayon.json" },
    ],
  },
  {
    id: "gunold",
    name: "Gunold",
    lines: "Polyester or rayon",
    guidance: "A European commercial supplier (POLY, Cotty, and other named lines) with the same polyester-for-durability, rayon-for-sheen tradeoff as the other brands here.",
    catalogs: [{ label: "Polyester", file: "gunold-polyester.json" }],
  },
];
