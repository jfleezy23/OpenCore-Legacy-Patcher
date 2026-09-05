# Provenance and licensing

The original translator, bridge, tests and procedural reproduction are
published under the accompanying MIT license, copyright 2026 jfleezy23.
The work was developed through hardware-owner testing and Codex-assisted
implementation, inspection and review. This is not an official Dortania
release or an endorsement by upstream maintainers.

This is a source-only extraction from a larger local experiment. Core source
files are preserved unchanged in `fix/`; a standalone Makefile and these
publication notes were added. Tests live separately in `tests/`, with their
implementation include path updated for this layout. Historical experiments,
machine-specific deployment scripts, Apple driver/framework binaries and the
private working repository's history are excluded.

The reproduction's load/resolve geometry and semantics were informed by Skia
Graphite and a local rendering capture. Its shaders are independently
simplified equivalents, not an exact capture replay or a redistributed shader
binary. Relevant primary source:

- [Skia DawnResourceProvider.cpp at the inspected revision](https://skia.googlesource.com/skia/+/66cca05ab345fb894cc80ed412e2fa79f687f5d9/src/gpu/graphite/dawn/DawnResourceProvider.cpp).
- [OCLP AMD Navi reference patchset](https://github.com/dortania/OpenCore-Legacy-Patcher/blob/main/opencore_legacy_patcher/sys_patch/patchsets/hardware/graphics/amd_navi.py).

OCLP and third-party dependencies retain their respective licenses. The MIT
license here applies to this original source contribution, not to Apple
binaries, macOS private APIs, or the surrounding OCLP repository.
