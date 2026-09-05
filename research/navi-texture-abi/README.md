# Navi texture-descriptor ABI correction

Source-only experimental compatibility fix for the RX 5700 XT on a pre-AVX2
MacPro6,1 running Sequoia with a modified Monterey-derived Navi driver stack.

**This builds on OCLP's unfinished Navi work; it is not official OCLP support,
a new AMD driver, or a general-purpose installer.**

## How this connects to OCLP

OCLP's [AMD Navi reference patchset](../../opencore_legacy_patcher/sys_patch/patchsets/hardware/graphics/amd_navi.py)
already describes installing legacy Navi drivers on machines without AVX2,
using the `12.5-24` Metal payload on Sequoia. Its `AMD Navi Extended` path
accounts for mixed legacy-GCN/Navi hardware such as the MacPro6,1.

This work addresses a remaining incompatibility **inside the userspace Metal
driver compatibility payload** used by that approach. The existing driver
stack could accelerate rendering, but the tested configuration produced
repeatable red dots/streaks. Correcting the descriptor layout removed the
established reproduction. Merely enabling the reference patchset's detection
gate does not implement this correction.

## The defect and the small part of the fix

Current Metal's `MTLTextureDescriptorInternal::descriptorPrivate` returns a
200-byte private record. The actual locally patched donor expects 192 bytes.
An eight-byte `colorSpaceConversionMatrix` field inserted at `0xa8` shifts
the fields the older driver consumes:

| Field | Current offset | Tested donor offset |
| --- | ---: | ---: |
| `resolvedUsage` | `0xb0` | `0xa8` |
| `cpuCacheMode` | `0xb8` | `0xb0` |
| `storageMode` | `0xc0` | `0xb8` |

For the verified source/donor layout and zero matrix, translate into separate
owned storage:

```c
memcpy(destination, source, 0xa8);
memcpy(destination + 0xa8, source + 0xb0, 24);
```

The [pure translator](src/texture_descriptor_abi.c) leaves the current Metal
object unchanged. The [bridge](tools/texture_descriptor_abi_lab.m) adds caller,
class/layout, ownership and matrix gates plus retained translation storage.

The 192-byte layout is **not a universal Monterey ABI**. An independently
inspected unmodified 12.5 private record was 176 bytes. Match the actual donor
and source layout, not just their advertised OS provenance.

## Evidence

Tested on MacPro6,1 / Xeon E5-2697 v2 / RX 5700 XT, macOS 15.7.9 (24G830),
with internal D700 devices still present:

- Standalone synthetic rectangle: 4,874 bad whole-image pixels without the
  bridge; zero with it. Three corrected outputs were byte-identical to the
  entire 950,272-byte synthetic input.
- Matched Chrome bridge/control/bridge phases: **0 / 806 / 0** flat-titlebar
  outliers across 16 captures and 201,600 measured pixels per phase. Hardware
  rendering and animation remained active.
- The operator reported success after installing and rebooting the scoped
  root prototype; the intended live snapshot and files were independently
  verified. This is initial boot evidence, not all-application certification.

See [evidence and limitations](docs/EVIDENCE.md) and
[integration details](docs/INTEGRATION.md). MacPro5,1 and other donor/OS
combinations have not been validated here.

## Build and CPU tests

Requires macOS with Xcode Command Line Tools and a macOS 15-or-newer SDK.
Targets are x86_64. On Apple silicon, running these binaries requires Rosetta.
From this directory:

```sh
make
make test
build/msaa_rectangle_minimal --describe
build/texture_validation_order_tests --describe
```

`make test` runs translation checks, five CPU-only lifetime groups and the
image-comparator self-test. It does not initialize a GPU or install the hook.
The source checks are not a substitute for actual donor/GPU tests.

The [standalone reproduction](tests/msaa_rectangle_minimal.m) needs no Chrome
assets. GPU execution is opt-in through `--run --out NEW_ABSOLUTE_DIRECTORY
--repeat 3`. Run only on a suitable lab system; see integration notes before
attempting an A/B comparison. A root-patched machine is not an untreated
control just because process-injection variables are absent.

## Publication scope

This directory contains the translator, bridge, standalone reproduction,
regression tests, build instructions and review notes. Source files are copied
from the tested local implementation; the standalone Makefile is publication
packaging. No private lab history, credentials, screenshots with personal file
paths, root installers, EFI configurations or Apple driver binaries are
included. No install target is provided.

MIT license for the original code in this directory. See [LICENSE](LICENSE)
and [provenance](docs/PROVENANCE.md). Review and additional hardware testing
are welcome; upstream integration is not complete.
