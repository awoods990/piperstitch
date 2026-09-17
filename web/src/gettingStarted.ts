// What a new user needs to know to get a good result -- learned from real
// sew-outs and real customer artwork, not guessed. The first three are the
// headline (finish screen, start-screen tip strip); the whole list is the
// "Getting started" section at the top of Help.

export interface Tip {
  title: string;
  body: string;
  /** The one-line version for the guided setup's cards. */
  short: string;
  /** Only worth showing when they use Proofs. */
  proofsOnly?: boolean;
}

export const TIPS: Tip[] = [
  {
    title: "Your artwork decides most of the result",
    short: "A clean logo on a plain background, cropped to the design, 500+ pixels across. A vector file (SVG) is best. Phone screenshots and photos of signs don't digitize well.",
    body: "A clean logo on a plain background, at least about 500 pixels across, digitizes beautifully; a phone screenshot, a photo of a sign, or a picture of someone else's embroidery does not. Crop to just the design before you upload. If you have the vector file (SVG), use it — it's the best input there is.",
  },
  {
    title: "White inside your design is bare fabric",
    short: "Anything the colour of the page becomes 'no thread', as a digitizer would do it. Want white thread? Use a different shade, or add it afterwards.",
    body: "Anything the colour of the page is treated as 'no thread', the way a digitizer would. If you want white thread, it has to be a different shade than the background — or add it as a colour afterwards.",
  },
  {
    title: "Sew a test on scrap first",
    short: "One hoop in the real fabric shows registration and density before the garment does. Brother or Baby Lock? Turn on Jump Stitch Trimming in the machine's settings.",
    body: "One hoop of the real fabric and stabilizer shows you registration and density before the garment does. Brother and Baby Lock owners: check the machine's Jump Stitch Trimming setting once; with it off, every connector is left as a loose thread to pick out.",
  },
  {
    title: "Fabric and stabilizer matter as much as the file",
    short: "Choose the real fabric in setup and follow the stabilizer note.",
    body: "Pull compensation and underlay are set from the fabric you choose, so 'knit' vs 'structured cap' isn't cosmetic. Follow the stabilizer note in the readiness report — cut-away for anything that stretches.",
  },
  {
    title: "Smaller isn't free",
    short: "Below about 1 mm a stroke can't be satin; trust the size step's advice.",
    body: "Below about 1 mm a stroke can't be satin and small lettering loses its shape. The size step tells you how small your artwork's finest detail can go — trust it, or simplify the design.",
  },
  {
    title: "The preview is a prediction, not a photo",
    short: "Thread reads a little bolder than the screen; judge by stitch count and score.",
    body: "It's accurate for geometry and sewing order, but thread on fabric always reads a little bolder and denser than the screen. Judge density by the stitch count and the readiness score, not the sheen.",
  },
  {
    title: "Send feedback when something looks wrong",
    short: "It's read, and the engine improves from exactly these samples.",
    body: "The Send feedback button sends us the original artwork and the result. It is read, and the engine is improved from exactly these samples.",
  },
  {
    title: "Your customer approves on their phone, no account needed",
    short: "They trust your shop name and reply-to address. A proof only counts when you send it — drafts are free.",
    body: "What they see and trust is your shop name and reply-to address, so keep those current in Settings. Drafts are free — a proof only counts when you send it.",
    proofsOnly: true,
  },
];

/** The three to show up front (plus the Proofs one when relevant). */
export function headlineTips(includeProofs: boolean): Tip[] {
  return [...TIPS.slice(0, 3), ...(includeProofs ? TIPS.filter((t) => t.proofsOnly) : [])];
}
