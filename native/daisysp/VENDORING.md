# Vendored DaisySP

- **Upstream:** https://github.com/electro-smith/DaisySP (MIT license — see `LICENSE`).
- **Vendored commit:** `599511b740f8f3a9b8db72a0642aa45b8a23c3a3` (2025-05-28).
- **What we kept:** `Source/` (the MIT DSP modules) + `LICENSE` + `README.md`.
- **What we removed:**
  - `DaisySP-LGPL/` — the separate LGPL module set. Excluded to avoid LGPL obligations.
  - The upstream `.git/` (vendored as flat source, not a submodule).
  - Dev/build scaffolding not used by the Unreal build: `tests/`, `ci/`, `vs/`, `doc/`, `util/`,
    `resources/`, `CMakeLists.txt`, `Makefile`, `Doxyfile`, `daisysp.sln`.
- **Source patches applied (search "Jammin vendoring patch" / the notes below):**
  - `Source/daisysp.h` — the LGPL umbrella include (already guarded by `#ifdef USE_DAISYSP_LGPL`) was
    replaced with a note. **Do not define `USE_DAISYSP_LGPL`.**
  - `Source/Filters/ladder.cpp` — the GCC-only `__attribute__((optimize("unroll-loops")))` on
    `LadderFilter::ProcessBlock` was guarded to real GCC (`#if defined(__GNUC__) && !defined(__clang__)`);
    it is just an optimization hint and is unsupported by MSVC.

## How it is built

The library is pure DSP (no libDaisy hardware dependency — that lives in a separate repo). It is compiled
**directly into the `JamAudioCore` module** (not as its own module), because DaisySP's plain C++ classes
carry no UE `*_API` export decoration and therefore cannot cross a DLL boundary — they must live in the
same module as the code that instantiates their voices. `JamAudioCore.Build.cs` adds every DaisySP
subdirectory as a SYSTEM include path (bare cross-directory includes like `"dsp.h"`) and relaxes
warnings-as-errors for the vendored code. This tree lives at `Plugins/JamAudioCore/Source/JamAudioCore/Private/DaisySP/`.

To update: re-clone upstream at the desired commit, re-apply the removals + the two source patches above,
and bump the commit hash here.
