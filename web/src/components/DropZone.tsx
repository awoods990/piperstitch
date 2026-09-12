import { useCallback, useRef, useState } from "react";

export default function DropZone({ onFile, busy }: { onFile: (file: File) => void; busy: string | null }) {
  const [over, setOver] = useState(false);
  const input = useRef<HTMLInputElement>(null);

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
        ) : (
          <>
            <div className="drop-title">Drop an image or SVG here</div>
            <div className="drop-sub">or click to choose a file · PNG, JPEG, SVG, WebP and more</div>
          </>
        )}
      </div>
      <div className="start-hints">
        <div><strong>Best results:</strong> clean logos with flat colours on a plain background.</div>
        <div><strong>Your files stay yours:</strong> the finished DST/PES/JEF file downloads straight to your computer.</div>
      </div>
    </div>
  );
}
