# Recorded rendering evidence

Experiments performed September 4-5, 2026 on macOS 15.7.9/24G830,
MacPro6,1 / Xeon E5-2697 v2 / RX 5700 XT with internal D700 devices present.
This is a summary of retained local evidence, not a claim that the full raw
capture archive is included in this source publication.

## Standalone synthetic rectangle

The test uses a 928x256 managed BGRA8 IOSurface, a 1024x256 private four-sample
MSAA color target, paired D32S8, and shader load/draw/resolve operations.
Geometry and shaders are independently simplified from a captured Chrome
Graphite sequence. No captured browser buffers are required to build it.

| Phase | Repeats | Whole-image bad pixels per repeat | Interior bad pixels per repeat |
| --- | ---: | ---: | ---: |
| Load/resolve only | 3 | 0 | 0 |
| Add procedural rectangle; no bridge | 3 | 4,874 | 1,191 |
| Same rectangle with bridge | 3 | 0 | 0 |

Each corrected output was byte-identical to the entire 950,272-byte synthetic
input. Inputs, rendering source, pipeline configuration and compilation
settings were held constant across the bridge comparison. Later off/on
reversal repeated the same corrupt/clean result. The original captured-draw
reproduction also became clean in its defined interior region; that does not
assert identity across unrelated pixels of the complete captured scene.

## Live Chrome reversal

Chrome for Testing 151.0.7922.138, hardware GraphiteDawnMetal, fresh profiles,
window widths 900, 640, 1200, 900; early/inactive/reactivated/late captures at
each width. Existing diagnostic flags were held constant across phases.

| Phase | Images | Flat-titlebar ROI pixels | Outliers | Images with outliers |
| --- | ---: | ---: | ---: | ---: |
| Bridge A | 16 | 201,600 | 0 | 0 |
| Control | 16 | 201,600 | 806 | 7 |
| Bridge B | 16 | 201,600 | 0 | 0 |

An outlier differs from the flat region's modal RGBA color. The region excludes
tabs, controls and rounded corners; the animated test page is not measured as
a flat surface. Independent CPU image decoding confirmed the saved results.
Some control width/focus states were clean, so one clean image was not enough.

The bridge phases logged 593 and 594 translations without fallback, unchanged
GPU process identities within each phase, and advancing animation counters.
Hardware acceleration stayed active. The tests retained a GPU-sandbox-off
diagnostic flag, so this comparison does not prove default-sandbox operation.

A wider eight-width run produced 32 populated captures with zero outliers in
456,064 titlebar pixels, followed by a completed five-minute animation soak.
The GPU process remained stable; the final frame count was 30,041, with 1,319
translations and no logged fallback. These counters establish liveness, not
an input-latency or throughput benchmark.

## Exclusions and open claims

- An earlier soak failed to activate the bridge and is excluded as bridge
  success/failure evidence.
- Blank startup windows were excluded from populated-rendering evidence.
- The operator reported successful real-boot output after installing the
  scoped root prototype. Live-root snapshot/file identity was independently
  checked. This is not a complete post-boot pixel census or prolonged soak.
- No MacPro5,1, other Navi GPU, later OS, or alternate donor validation is claimed.
- This identifies a causal private-ABI defect, not the exact hardware origin
  of the bad sample colors or a proved FMASK-specific fault.

Full raw images and receipts remain local for deliberate review/sharing;
machine-specific logs, account paths and driver binaries are not uploaded here.
