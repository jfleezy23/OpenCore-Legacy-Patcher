# Integration notes and intentionally unfinished work

## Correct layer

The contribution belongs in the userspace Metal compatibility/support payload
that OCLP installs for its legacy Navi path. OCLP's Python patchset selects and
installs payloads; it does not itself run this descriptor translation.
Existing eGPU-enabling, framebuffer, and kernel-driver components remain
required. This library is not an AVX2 emulator or a substitute for that stack.

## Source layout and actual donor identity

The tested `MTLTextureDescriptorInternal` instance is 208 bytes, including an
eight-byte object header followed by its 200-byte `_private` record. Its
accessor is `descriptorPrivate`, without a leading underscore. The bridge
checks the complete type encoding and method signature, the accessor's Metal
image ownership, exact object class, and returned storage ownership.

The translated record retains bytes `0x00..0xa7`, omits the zero-valued matrix
word at `0xa8`, and copies `0xb0..0xc7` into `0xa8..0xbf`. Current Metal and
D700 callers continue receiving the original record.

The actual tested donor executable had SHA-256:

```text
cc0521912b5ccc26a87d7fb0eec6edd6c2272fb27d2ee6cb060c94ea5e9eaae7
```

This identifies evidence, not a redistributed Apple binary. The caller's
driver path must match the image defining `GFX10_MtlDevice`. These runtime
checks are not a complete binary fingerprint; the local deployment separately
checked the donor file. Production must strengthen donor/version selection.

## Validation order

The installed prototype was compiled with `NAVI_TEXTURE_ABI_ROOT=1`. It only
translates two caller offsets relative to this donor's image base:

- `0x14fc4d`: `initInternalWithDevice:descriptor:`.
- `0x152395`: `initIOSurfaceWithDevice:descriptor:iosurface:plane:field:`.

Both call `validateWithDevice:` before `descriptorPrivate`; validation has
therefore populated the resolved fields before the bridge snapshots them.
These were the paths exercised by the captured native and live Chrome tests.

The diagnostic, process-opt-in build does not apply that two-offset restriction.
It must not be substituted for the scoped root build indiscriminately.

Two exceptional paths found in review obtain the pointer before validation:
the tiled-buffer texture initializer and shared-IOSurface-property copying.
Returning an immutable translated snapshot there can leave it stale after
validation mutates the original record. These paths are left unchanged by the
root prototype. Targeted allocation-entry prevalidation is one candidate;
copy-family return ownership and validator side effects need attention.

`tests/texture_validation_order_tests.m` characterizes validator idempotence
without allocating textures or submitting GPU commands. Its 48 tested cases
were idempotent, but that does not prove complete exceptional-path correctness.
It is not part of the default CPU-only test suite because `--run` enumerates
the actual device and invokes the private validator.

## Lifetime and failure policy

The bridge retains immutable descriptor-owned versions, separated by thread.
This prevents a later/nested call overwriting an earlier outstanding pointer.
Tests cover old pointers, autorelease drains, nested calls, owner isolation,
concurrent readers and capacity boundaries.

There is a 4,096-version cap per descriptor/thread. Capacity exhaustion and a
nonzero color matrix currently return the original pointer: **an untreated
lab fallback, not a correct general compatibility policy**. A production
implementation must define bounded storage and supported matrix semantics or
reject unsupported allocation at a suitable boundary. Returning NULL from the
raw accessor is unsafe because donor callers may immediately dereference it.

Unknown descriptor subclasses, alternate accessors, capture wrappers, heap and
buffer paths, and other OS/donor layouts need coverage. Do not remove guards
merely to make an unsupported test proceed.

## Building the scoped root prototype

The three implementation files are in [fix/](../fix/); no files from
`tests/` are required. From the package directory:

```sh
make
```

`make root-prototype` remains an equivalent explicit target. This builds and
ad-hoc signs `build/NaviTextureABI.dylib`; it does not load or
install it. The root variant activates without process environment settings
when loaded through the driver dependency chain. Its IOSurface reexport
supports the packaging used in the local experiment: an existing compatible
`impostor.dylib` reexports this sibling instead of directly reexporting
IOSurface, and this library reexports the actual framework. The shim and its
dependent library must travel together.

The existing `impostor.dylib`, modified donor, root snapshot operations, EFI
and trust configuration are deliberately not bundled here. Reviewers must
integrate against a verified support payload rather than copy this library
into a stock installation and assume the driver is now supported.

The preferred long-term integration is a coherent compatibility payload with
version-aware selection and regression tests, installed/reapplied through
OCLP. The lab dependency chain is not a finished public installer.

## Reproduction boundaries

The process diagnostic activates only with `NAVI_TEXTURE_ABI_LAB=1`, an
absolute new `NAVI_TEXTURE_ABI_TRACE` path, and an allowlisted test process.
The native executable is `msaa_rectangle_minimal`; Chrome support is limited
to a GPU helper inside Google Chrome for Testing. Receipt events must confirm
installation and actual translations before a run counts as bridge evidence.

Do not inject the diagnostic over an already active root bridge to manufacture
an A/B comparison. The saved untreated controls were collected before root
deployment. Isolate the baseline explicitly on a lab system and preserve
compilation options, shaders, inputs, geometry, device choice and capture
conditions between phases. Blank or frozen windows are not successful output.
