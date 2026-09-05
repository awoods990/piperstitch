# Third-party sample files

- `random1-ew.dst`, `random1-ew.pes` — from [EmbroidePy/samples](https://github.com/EmbroidePy/samples),
  MIT License (see `EmbroidePy-samples-LICENSE.txt`, copied verbatim from
  that repository). The same synthetic "random1" design, pre-digitized and
  exported to many machine formats by that project — used here as
  independently-authored files to validate that StitchPilot's *readers*
  (not just its own writer's output) can parse real-world files from
  another codebase, per spec §18 ("use PyEmbroidery and EmbroidePy samples
  to validate export behavior") and TESTING.md's cross-validation
  philosophy. See `ThirdPartySampleTests.swift`.

These are the only third-party binary assets vendored into this repository.
No source code from any studied project (Ink/Stitch, pyembroidery) is
copied here — see `EMBROIDERY_ALGORITHM_REFERENCE.md` for what was studied
and how.
