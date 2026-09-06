# Third-party sample files

- `random1-ew.dst`, `random1-ew.pes`, `random1-wilcom.dst`,
  `random1-brother-v6.pes`, `scene.dst`, `scene.pes` — from
  [EmbroidePy/samples](https://github.com/EmbroidePy/samples), MIT License
  (see `EmbroidePy-samples-LICENSE.txt`, copied verbatim from that
  repository). Synthetic designs ("random1", "scene"), pre-digitized and
  exported to many machine formats by real embroidery software (EmbroidePy's
  own writer, Wilcom, Brother) — used here as independently-authored files
  to validate that StitchPilot's *readers* (not just its own writer's
  output) can parse real-world files from other codebases and other
  software, per spec §18 ("use PyEmbroidery and EmbroidePy samples to
  validate export behavior") and TESTING.md's cross-validation philosophy.
  These six are a representative slice, deliberately spanning multiple
  exporters and designs rather than one -- see `ThirdPartySampleTests.swift`.
  The full upstream repository (654 files, every design × every supported
  machine format) was cloned separately and run once through both readers
  as a broader one-off validation pass (all parsed successfully; see
  CHANGELOG.md) — only this smaller slice is vendored for ongoing
  regression testing, to avoid bloating the repository with redundant
  binary assets that don't materially add coverage beyond what's here.

These are the only third-party binary assets vendored into this repository.
No source code from any studied project (Ink/Stitch, pyembroidery) is
copied here — see `EMBROIDERY_ALGORITHM_REFERENCE.md` for what was studied
and how.
