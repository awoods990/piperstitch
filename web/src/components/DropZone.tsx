import { useCallback, useRef, useState } from "react";
import type { ProofsState, ProjectSummary } from "../types";
import { size } from "../format";
import { COARSE_QUERY, useMediaQuery } from "../useMediaQuery";
import { headlineTips } from "../gettingStarted";
import { SITE_URL } from "../links";

interface Props {
  onFile: (file: File) => void;
  busy: string | null;
  /** null: accounts are off or still loading; []: none saved yet. */
  projects: ProjectSummary[] | null;
  onOpenProject: (p: ProjectSummary) => void;
  onDeleteProject: (p: ProjectSummary) => void;
  /** Their Proofs standing, when they have any: the start screen is the
   *  natural place to cross over, because sending a proof is the step
   *  after digitizing and people were navigating back to the site to
   *  find it. */
  proofs?: ProofsState | null;
  /** Show the "before your first design" tips (skipped guided setup, not yet dismissed). */
  showTips?: boolean;
  onDismissTips?: () => void;
  onOpenHelp?: () => void;
}

export default function DropZone({ onFile, busy, projects, onOpenProject, onDeleteProject, proofs, showTips, onDismissTips, onOpenHelp }: Props) {
  const [over, setOver] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  const camera = useRef<HTMLInputElement>(null);
  // A phone or tablet: no drag-and-drop to speak of, but a camera.
  const touch = useMediaQuery(COARSE_QUERY);

  // "If they have it" means subscribed, or still holding free proofs.
  const hasProofs = !!proofs?.url && (proofs.subscribed || proofs.free_left > 0);

  const onDrop = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    setOver(false);
    const file = e.dataTransfer.files?.[0];
    if (file) onFile(file);
  }, [onFile]);

  return (
    <div className="start">
      <div className="start-brand">
        <h1 className="start-logo">
          <a href={SITE_URL} target="_blank" rel="noopener" title="PiperStitch home (opens in a new tab)">
            <img src="/logo.png" alt="PiperStitch" width={900} height={450} />
          </a>
        </h1>
        <p>Turn any image into embroidery. Drop in a logo, answer five quick questions, and download a file your machine can sew.</p>
      </div>
      <div
        className={"dropzone" + (over ? " over" : "") + (busy ? " busy" : "")}
        onDragOver={(e) => { e.preventDefault(); setOver(true); }}
        onDragLeave={() => setOver(false)}
        onDrop={onDrop}
        onClick={() => !busy && input.current?.click()}
        role="button"
        tabIndex={0}
        onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") input.current?.click(); }}
      >
        <input ref={input} type="file" accept="image/*,.svg,.heic,.heif" hidden onChange={(e) => { const f = e.target.files?.[0]; if (f) onFile(f); e.target.value = ""; }} />
        {busy ? (
          <><div className="spinner" /><div className="drop-title">{busy}</div></>
        ) : touch ? (
          <>
            <div className="drop-title">Tap to choose an image</div>
            <div className="drop-sub">from your photos or files · PNG, JPEG, SVG, WebP and more</div>
          </>
        ) : (
          <>
            <div className="drop-title">Drop an image or SVG here</div>
            <div className="drop-sub">or click to choose a file · PNG, JPEG, SVG, WebP and more</div>
          </>
        )}
      </div>
      {touch && !busy && (
        <>
          {/* `capture` opens the camera directly on phones; a tablet or
              laptop without one falls back to the normal picker. */}
          <input ref={camera} type="file" accept="image/*,.heic,.heif" capture="environment" hidden onChange={(e) => { const f = e.target.files?.[0]; if (f) onFile(f); e.target.value = ""; }} />
          <button className="btn" onClick={() => camera.current?.click()}>📷 Take a photo of the artwork</button>
        </>
      )}
      {hasProofs && (
        <a className="proofs-cross" href={proofs!.url} target="_blank" rel="noopener">
          <span className="proofs-cross-icon" aria-hidden="true">✓</span>
          <span className="proofs-cross-text">
            <b>Open PiperStitch Proofs</b>
            <span>{proofs!.subscribed
              ? "Send this design for approval and get a signed Certificate of Approval back."
              : `Send a design for approval — ${proofs!.free_left} free proof${proofs!.free_left === 1 ? "" : "s"} left on your account.`}</span>
          </span>
          <span className="proofs-cross-go" aria-hidden="true">→</span>
        </a>
      )}
      {showTips && (
        <div className="tips-strip">
          <div className="tips-head"><b>Before your first design</b><span className="grow" /><button className="icon-btn" title="Dismiss" onClick={onDismissTips}>×</button></div>
          <ol className="tips compact">
            {headlineTips(false).map((t) => <li key={t.title}><b>{t.title}.</b> {t.body}</li>)}
          </ol>
          {onOpenHelp && <button className="linkish" onClick={onOpenHelp}>Read the full guide</button>}
        </div>
      )}
      {projects && projects.length > 0 && (
        <div className="projects">
          <div className="section-label">Your saved projects</div>
          <ul>
            {projects.map((p) => (
              <li key={p.id}>
                <button className="project" onClick={() => onOpenProject(p)} disabled={!!busy}>
                  {/* Names blur together after a dozen projects; the design
                      itself is what people actually recognise. Anything
                      saved before thumbnails existed falls back to an empty
                      hoop until its next save. */}
                  {p.hasThumbnail
                    ? <img className="project-thumb" alt="" loading="lazy"
                           src={`/api/v1/projects/${encodeURIComponent(p.id)}/thumbnail?v=${encodeURIComponent(p.updatedAt)}`} />
                    : <span className="project-thumb empty" aria-hidden="true">
                        <svg viewBox="0 0 24 24" width="22" height="22"><circle cx="12" cy="12" r="8.5" fill="none" stroke="currentColor" strokeWidth="1.6" /></svg>
                      </span>}
                  <span className="project-text">
                    <b>{p.name}</b>
                    <span>{size(p.widthMM, p.heightMM)} · {p.objectCount} object{p.objectCount === 1 ? "" : "s"} · {new Date(p.updatedAt).toLocaleDateString()}</span>
                  </span>
                </button>
                <button className="icon-btn" title="Delete project" onClick={() => onDeleteProject(p)}>×</button>
              </li>
            ))}
          </ul>
        </div>
      )}
      <div className="start-hints">
        <div><strong>Best results:</strong> clean logos with flat colours on a plain background.</div>
        <div><strong>Your files stay yours:</strong> the finished DST/PES/JEF file downloads straight to your device.</div>
      </div>
    </div>
  );
}
