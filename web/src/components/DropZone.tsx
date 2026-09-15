import { useCallback, useRef, useState } from "react";
import type { ProjectSummary } from "../types";
import { cm } from "../format";
import { COARSE_QUERY, useMediaQuery } from "../useMediaQuery";

interface Props {
  onFile: (file: File) => void;
  busy: string | null;
  /** null: accounts are off or still loading; []: none saved yet. */
  projects: ProjectSummary[] | null;
  onOpenProject: (p: ProjectSummary) => void;
  onDeleteProject: (p: ProjectSummary) => void;
}

export default function DropZone({ onFile, busy, projects, onOpenProject, onDeleteProject }: Props) {
  const [over, setOver] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  const camera = useRef<HTMLInputElement>(null);
  // A phone or tablet: no drag-and-drop to speak of, but a camera.
  const touch = useMediaQuery(COARSE_QUERY);

  const onDrop = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    setOver(false);
    const file = e.dataTransfer.files?.[0];
    if (file) onFile(file);
  }, [onFile]);

  return (
    <div className="start">
      <div className="start-brand">
        <img src="/icon.png" alt="" width={64} height={64} />
        <h1>PiperStitch</h1>
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
        <input ref={input} type="file" accept="image/*,.svg" hidden onChange={(e) => { const f = e.target.files?.[0]; if (f) onFile(f); e.target.value = ""; }} />
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
          <input ref={camera} type="file" accept="image/*" capture="environment" hidden onChange={(e) => { const f = e.target.files?.[0]; if (f) onFile(f); e.target.value = ""; }} />
          <button className="btn" onClick={() => camera.current?.click()}>📷 Take a photo of the artwork</button>
        </>
      )}
      {projects && projects.length > 0 && (
        <div className="projects">
          <div className="section-label">Your saved projects</div>
          <ul>
            {projects.map((p) => (
              <li key={p.id}>
                <button className="project" onClick={() => onOpenProject(p)} disabled={!!busy}>
                  <b>{p.name}</b>
                  <span>{cm(p.widthMM)} × {cm(p.heightMM)} cm · {p.objectCount} object{p.objectCount === 1 ? "" : "s"} · {new Date(p.updatedAt).toLocaleDateString()}</span>
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
