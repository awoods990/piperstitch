import type { CandidateAssessment } from "../types";

/** Shown instead of the setup steps (or instead of the editor after the
 *  first digitize) when the engine judges the image a poor candidate.
 *  Specific about why -- the reasons carry the measurements -- and clear
 *  that this is the exception, with the way through spelled out. */
export function CandidateNotice({ assessment, fileName, afterDigitize, onChooseAnother, onContinue }: {
  assessment: CandidateAssessment; fileName: string; afterDigitize: boolean;
  onChooseAnother: () => void; onContinue: () => void;
}) {
  const codes = new Set(assessment.reasons.map((r) => r.code));
  const wantsOriginal = codes.has("photograph") || codes.has("fragmented");
  const wantsLarger = codes.has("lowResolution");
  return (
    <div className="candidate-notice">
      <div className="candidate-card">
        <p className="candidate-eyebrow">{afterDigitize ? "Not a result worth sending" : "Before you spend time on this one"}</p>
        <h2>{afterDigitize ? "This didn't digitize well, and here's why" : "This image isn't a good candidate for digitizing"}</h2>
        <p className="candidate-lead">
          PiperStitch digitizes the great majority of logos and artwork cleanly &mdash; flat colours and clean edges,
          straight from the design file. <strong>{fileName}</strong> falls outside that, and rather than hand you a poor
          stitch file, here is exactly what the engine found:
        </p>
        <ul className="candidate-reasons">
          {assessment.reasons.map((r, i) => <li key={i} className={r.code === "issue" ? "candidate-sub" : undefined}>{r.message}</li>)}
        </ul>
        <div className="candidate-fix">
          <h3>What works</h3>
          <ul>
            {wantsOriginal && <li>The <strong>original artwork file</strong> &mdash; the logo as the designer drew it (SVG, or a PNG with flat colours), not a photograph, a scan or a screenshot of embroidery.</li>}
            {wantsLarger && <li>A <strong>larger export</strong> of the same artwork: at least 500 pixels on the short side, ideally SVG.</li>}
            {!wantsOriginal && !wantsLarger && <li>A cleaner version of the artwork: flat colours, sharp edges, no shading or photographic texture.</li>}
            <li>If all you have is a photo or a scan, any designer can redraw a logo in about an hour. With the file in hand, PiperStitch turns it into a stitch file in minutes.</li>
          </ul>
        </div>
        <div className="candidate-actions">
          <button className="btn primary" onClick={onChooseAnother}>Choose a different file</button>
          <button className="link" onClick={onContinue}>{afterDigitize ? "Show it anyway" : "Digitize it anyway"}</button>
        </div>
      </div>
    </div>
  );
}
