// Reference only -- which thread manufacturer(s) a user actually sews
// with, shown alongside the Thread Library editor so the color names
// they type in ("Madeira 1147 Red") mean something to them and so any
// well-known handling difference for that brand/fiber is visible right
// where they're building their list.
//
// Deliberately carries no color/RGB data: no embroidery thread
// manufacturer publishes official RGB values for their catalogs (their
// own color charts are names and numbers only, with a physical color
// card recommended for true accuracy), and the one place structured RGB
// data exists for these brands is a GPLv3-licensed project -- not
// something to fold into this app without a separate license decision.
// A user who wants a specific numbered shade in their own library still
// adds it by hand below, same as always; this only supplies the
// reference text and lets that hand-built list be organized by supplier.

export interface ThreadSupplier {
  id: string;
  name: string;
  lines: string;
  guidance: string;
}

export const THREAD_SUPPLIERS: ThreadSupplier[] = [
  {
    id: "isacord",
    name: "Isacord",
    lines: "100% polyester, 40wt (Tex 27)",
    guidance: "The de facto default most digitizing software assumes when nothing else is specified. Runs clean at high machine speed with low lint. A universal 75/11–80/12 embroidery needle is the standard pairing; drop to 60wt only for lettering under about 5mm.",
  },
  {
    id: "madeira",
    name: "Madeira",
    lines: "Polyneon (polyester) or Classic Rayon",
    guidance: "Polyneon is the durable, colorfast choice for anything that gets washed or bleached often (workwear, towels); Classic Rayon has more sheen and a softer hand but holds up to laundering and chlorine less well. Both are commonly stocked at 40wt.",
  },
  {
    id: "robison-anton",
    name: "Robison-Anton",
    lines: "Rayon (2000 series) or Polyester (5000/9000 series)",
    guidance: "A US commercial-embroidery staple, organized by these number-series product lines rather than a single catalog. Rayon gives the glossiest finish; polyester trades a little sheen for meaningfully better durability.",
  },
  {
    id: "sulky",
    name: "Sulky",
    lines: "Rayon, polyester, or cotton",
    guidance: "Popular with home and quilting machines as much as commercial ones. Available at both 30wt and 40wt — 30wt lays down bolder coverage in fewer stitches, useful for large fill areas; 40wt is the general-purpose default.",
  },
  {
    id: "hemingworth",
    name: "Hemingworth",
    lines: "100% polyester, 40wt",
    guidance: "A budget-friendly polyester line widely used in commercial and promotional embroidery shops running high volume.",
  },
  {
    id: "floriani",
    name: "Floriani",
    lines: "100% polyester, 40wt",
    guidance: "Aimed at the home and small-shop embroidery market, marketed for smooth, low-lint machine performance.",
  },
  {
    id: "marathon",
    name: "Marathon",
    lines: "Polyester or rayon",
    guidance: "A commercial embroidery supplier with both fiber lines available, most often stocked at 40wt like the others here.",
  },
  {
    id: "gunold",
    name: "Gunold",
    lines: "Polyester or rayon",
    guidance: "A European commercial supplier (POLY, Cotty, and other named lines) with the same polyester-for-durability, rayon-for-sheen tradeoff as the other brands here.",
  },
];
