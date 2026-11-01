# Building OpenCode 1.19.4 for Android/Termux (aarch64)

Complete build specification: dependency topology, cross-compilation pipeline, every patch with
its rationale and diff, the standalone-binary format, packaging, CI, and verification.

This document describes the pipeline **as implemented in this repository**, not an
aspirational design. Where the implementation differs from the original design notes
(Bun 1.3.14 / 52-byte stride) the difference is called out explicitly —
see [Upgrade status](#14-upgrade-status-bun-1314).

**Audience and how to use it**

| Reader | Start at | Use it for |
|---|---|---|
| Maintainer | [§19](#19-implementation-strategy) | Why the pipeline is shaped this way, what was rejected, what must not be changed casually |
| Build engineer | [§21](#21-expanded-build-runbook) | Exact commands per stage, expected output, resume and recovery |
| AI agent / contributor | [§22](#22-agent-operating-manual) | Operating rules, authority order, triage loop, definition of done |
| Reviewer | [§11](#11-patch-reference-diffs--reasoning) | Every patch hunk with its justification |

**Authority order.** When documents disagree, the code wins, in this order:
`scripts/env.sh` and `.github/workflows/build.yml` (pins) → `scripts/*.sh`,
`scripts/transplant-bun-graph.py` (behaviour) → this document (explanation) →
`README.md` and design notes (context, sometimes stale). See
[§19.6](#196-readme-and-design-note-drift) for known drift.

**Status.** Every native stage is now green in CI. Run #41281683381 built, verified and
cached `libopentui.so`; run #41282039365 restored that cache (skipping the Zig build) and then
built, verified and cached ICU 75.1, WebKit/JSC, TinyCC and the Android Bun binary. Its
failure is now in the last stage, `Build OpenCode standalone binary`: `bun install` aborts
with `"git clone" for "@types/bun" failed` because Bun 1.2.13 cannot parse the `catalog:`
entries in OpenCode's committed `bun.lock`. `build-opencode.sh` now discards the lockfile so
Bun resolves the rewritten manifests; reproduced and fixed locally with Bun 1.2.13. With that
in place, run #41319756768 installed 9,025 packages and reached the bundler, which exposed two
OpenCode 1.19.4 layout changes: the TUI worker moved to `src/cli/tui/worker.ts`, and Bun will
not unpack `@opentui/core-*` packages for non-host platforms even though the bundler resolves
their imports. Both are fixed here. [§24](#24-ci-history-failure-taxonomy-and-the-current-opentui-blocker) has the run data,
diagnosis and remaining open items. The v2 pipeline (`opencode2`, Bun 1.4.2) lives beside it
and is out of scope; see [§19.7](#197-v1-vs-v2-pipelines).

---

## Table of contents

1. [Target matrix](#1-target-matrix)
2. [Artifact layout](#2-artifact-layout)
3. [Dependency topology and build order](#3-dependency-topology-and-build-order)
4. [Environment variables](#4-environment-variables)
5. [Stage 1 — ICU 75.1](#5-stage-1--icu-751)
6. [Stage 2 — WebKit / JavaScriptCore](#6-stage-2--webkit--javascriptcore)
7. [Stage 3 — TinyCC](#7-stage-3--tinycc)
8. [Stage 4 — Bun runtime](#8-stage-4--bun-runtime)
9. [Stage 5 — libopentui.so](#9-stage-5--libopentuiso)
10. [Stage 6 — OpenCode bundle and module-graph transplant](#10-stage-6--opencode-bundle-and-module-graph-transplant)
11. [Patch reference (diffs + reasoning)](#11-patch-reference-diffs--reasoning)
12. [Packaging](#12-packaging)
13. [CI pipeline](#13-ci-pipeline)
14. [Upgrade status: Bun 1.3.14](#14-upgrade-status-bun-1314)
15. [Verification and audit](#15-verification-and-audit)
16. [Troubleshooting](#16-troubleshooting)
17. [Known issues](#17-known-issues)
18. [Appendix: pins, files, references](#18-appendix-pins-files-references)
19. [Implementation strategy](#19-implementation-strategy)
20. [Build-system deep dive](#20-build-system-deep-dive)
21. [Expanded build runbook](#21-expanded-build-runbook)
22. [Agent operating manual](#22-agent-operating-manual)
23. [Maintenance and release checklist](#23-maintenance-and-release-checklist)
24. [CI history, failure taxonomy, and the current OpenTUI blocker](#24-ci-history-failure-taxonomy-and-the-current-opentui-blocker)

---

## 1. Target matrix

| Item | Value |
|---|---|
| OpenCode | `v1.19.4` (`anomalyco/opencode`, commit `148842ef7cb1bc34192b3fff57d0f9721ab9c801`) |
| Target triple | `aarch64-linux-android` (ABI `arm64-v8a`) |
| Minimum API | 24 (Android 7.0) |
| Android NDK | r28b (`28.1.13356709`), Clang 19 |
| Bun (host **and** target) | `1.2.13` (tag `bun-v1.2.13`) |
| WebKit/JSC | `017930ebf915121f8f593bef61cbbca82d78132d` (oven-sh/WebKit) |
| ICU | 75.1 (static) |
| TinyCC | `b91835d8701523e895a2b447713630069514e291` (oven-sh/tinycc) |
| Zig (for `libopentui.so`) | 0.16.0 (not 0.15.2 — `build.zig` uses the 0.16 `addLibrary`/`root_module` API) |
| OpenTUI | 0.5.10 |
| Build host | x86_64 Ubuntu (CI: `ubuntu-latest`), ≥16 GB RAM, ≥60 GB disk |

**Why every version is pinned.** Bun, WebKit, ICU and TinyCC are coupled: Bun's build links
against a specific WebKit/ICU pair, and the standalone module graph is positional binary data
whose layout changes between Bun releases. Changing any one of them is a coordinated upgrade,
not an isolated bump. See [§14](#14-upgrade-status-bun-1314) for the analysis required before
moving Bun.

**Builds must run on a remote runner.** The Termux development device cannot compile this:
no NDK, no root, no writable `/opt`, and insufficient RAM for the WebKit link step. The
supported flow is: edit locally → push → GitHub Actions → download artifacts → verify on device.

---

## 2. Artifact layout

The build stages the Termux `$PREFIX` layout directly, so the zip can be unpacked over
`$PREFIX` and the packages install to identical paths:

```
$PREFIX/
  bin/opencode                      # POSIX sh launcher
  libexec/opencode/opencode.bin     # real ELF: Android Bun runtime + module graph
  lib/libopentui.so                 # TUI renderer (dlopen'ed)
  lib/libc++_shared.so              # NDK C++ runtime, if referenced
  lib/libtagfix.so                  # optional, packaged only when supplied in build/
```

The launcher resolves both an installed prefix and an extracted zip:

```sh
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
DIR="$(CDPATH= cd -- "$(dirname "$SELF")" && pwd)"
PREFIX="${PREFIX:-$(CDPATH= cd -- "$DIR/.." && pwd)}"

for candidate in "$PREFIX/lib" "$PREFIX/libexec/opencode" "$DIR/lib"; do
    if [ -f "$candidate/libopentui.so" ]; then
        export OPENTUI_LIB_PATH="$candidate/libopentui.so"
        export LD_LIBRARY_PATH="$candidate${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        break
    fi
done

for candidate in "$PREFIX/libexec/opencode/opencode.bin" \
                 "$DIR/../libexec/opencode/opencode.bin" \
                 "$DIR/opencode.bin"; do
    [ -x "$candidate" ] && exec "$candidate" "$@"
done
exit 127
```

`OPENTUI_LIB_PATH` is what `@opentui/core` consults; `LD_LIBRARY_PATH` covers `DT_NEEDED`
lookups such as `libc++_shared.so`. The launcher uses the Termux shebang
`#!/data/data/com.termux/files/usr/bin/sh` because Android has no `/usr/bin/env`.

---

## 3. Dependency topology and build order

```
                 ┌──────────────────────────────┐
                 │ ICU 75.1 (host tools + cross)│
                 └──────────────┬───────────────┘
                                │ static libicu*.a
                                ▼
   oven-sh/WebKit @ 017930eb ──► JSCOnly static libs + headers
                                │
   oven-sh/tinycc @ b91835d ────┤ libtcc.a
                                ▼
                     Bun 1.2.13 (CMake + patched Zig vendor)
                                │  build/bun-build/bun  (aarch64 ELF, no graph)
                                ▼
   opencode v1.19.4 ──host bun compile──► host standalone ──┐
                                │                          │ module graph
                                │                          ▼
                                └──────────────────► opencode.bin (aarch64)
                                                           │
   opentui 0.5.10 (Zig 0.16) ──► libopentui.so ────────────┤
                                                           ▼
                                              bin/ + libexec/ + lib/ → zip/deb/pacman
```

Stages are **strictly sequential**; each script validates its inputs and fails loudly.

| Stage | Script | Typical time | Cache key inputs |
|---|---|---|---|
| ICU | `scripts/build-icu.sh` | ~5 min | ICU version, API level |
| WebKit/JSC | `scripts/build-webkit.sh` | 60–90 min | WebKit commit, webkit patch hash |
| TinyCC | `scripts/build-tinycc.sh` | ~1 min | TinyCC commit |
| Bun | `scripts/build-bun.sh` | 30–45 min | Bun version, bun patch hash, zig patch hash |
| libopentui.so | `scripts/build-opentui.sh` | ~2 min | OpenTUI version, patch hash, Zig version |
| Bundle | `scripts/build-opencode.sh` | ~30 s | OpenCode version, Bun version |
| Packages | `scripts/make-packages.sh` | ~10 s | — |

With warm WebKit and Bun caches a full CI run is roughly 4 minutes.

---

## 4. Environment variables

`scripts/env.sh` is sourced by every stage. Values are overridable (`BUN_VERSION=… ./script`).

| Variable | Default | Purpose |
|---|---|---|
| `REPO_ROOT` | derived | Repository root |
| `BUN_VERSION` | `1.2.13` | Host and target Bun |
| `BUN_TAG` | `bun-v${BUN_VERSION}` | Git tag to clone |
| `MODULE_GRAPH_STRIDE` | `36` | `CompiledModuleGraphFile` stride; enforced by the transplant tool |
| `WEBKIT_COMMIT` | `017930eb…` | oven-sh/WebKit commit |
| `ICU_VERSION` | `75.1` | ICU release |
| `ZIG_VERSION` | `0.16.0` | Zig used for OpenTUI |
| `OPENCODE_VERSION` | `1.19.4` | OpenCode tag (`v${OPENCODE_VERSION}`) |
| `ANDROID_API` | `24` | Bionic API level |
| `ANDROID_NDK_HOME` | Termux path | NDK root |
| `ANDROID_TRIPLE` | `aarch64-linux-android` | Target triple |
| `ANDROID_TRIPLE_API` | `aarch64-linux-android24` | Versioned compiler prefix |
| `WORK_DIR` | `${REPO_ROOT}/build` | All build state |
| `BUN_SRC` / `WEBKIT_SRC` / `OPENTUI_SRC` / `OPENCODE_SRC` | under `WORK_DIR` | Source trees |
| `DEPS_PREFIX` | `build/deps-android/prefix` | Installed ICU |
| `WEBKIT_OUTPUT` | `build/webkit-android` | JSC + libtcc + libopentui install root |
| `BUN_BUILD` | `build/bun-build` | CMake build dir |
| `DIST_DIR` | `build/dist` | Staged `$PREFIX` tree |
| `JOBS` | `nproc` | Parallelism |

**Path handling caveat.** `env.sh` defaults `WORK_DIR` to an absolute path, while CI sets
`WORK_DIR: ./build`. Scripts that assemble absolute paths therefore accept both forms through
an `abspath()` helper (`build-opencode.sh`, `make-packages.sh`). If you add a script, reuse it:

```sh
abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *)  printf '%s\n' "${REPO_ROOT_ABS}/${1#./}" ;;
    esac
}
```

---

## 5. Stage 1 — ICU 75.1

`scripts/build-icu.sh` builds ICU twice:

1. **Host tools** (`icu-host-build`) — `genccode`, `icupkg`, and friends must run on x86_64.
2. **Cross build** (`icu-android-build`) — configured with `--with-cross-build=<host build>`,
   `--host=aarch64-linux-android`, `CC/CXX/AR/RANLIB` from the NDK, and:

```
CFLAGS="-fPIC -DU_STATIC_IMPLEMENTATION=1"
CXXFLAGS="-fPIC -DU_STATIC_IMPLEMENTATION=1"
--enable-static --disable-shared
```

`-DU_STATIC_IMPLEMENTATION=1` is mandatory: WebKit is built with the same define, and mixing
static-ICU macros produces duplicate-symbol errors at link time. Outputs to
`build/deps-android/prefix/{lib,include}` and is reused by WebKit and Bun.

---

## 6. Stage 2 — WebKit / JavaScriptCore

`scripts/build-webkit.sh` builds the **JSCOnly** port using
`cmake/webkit-android-toolchain.cmake`, which is parameterised at run time (the checked-in
file contains author-machine paths that `sed` rewrites to the detected NDK and ICU prefix).

Key CMake options:

```
-PORT=JSCOnly
-DENABLE_STATIC_JSC=ON
-DUSE_THIN_ARCHIVES=OFF
-DUSE_BUN_JSC_ADDITIONS=ON
-DUSE_BUN_EVENT_LOOP=ON
-DENABLE_FTL_JIT=ON
-DENABLE_REMOTE_INSPECTOR=ON
-DCMAKE_C_FLAGS   "-fno-omit-frame-pointer -ffunction-sections -fdata-sections -faddrsig -DU_STATIC_IMPLEMENTATION=1"
-DCMAKE_CXX_FLAGS "… -fno-exceptions -fno-c++-static-destructors"
-DCMAKE_C_FLAGS_RELEASE "-O3 -DNDEBUG=1"
```

After `ninja jsc`, the script assembles the layout Bun's `SetupWebKit.cmake` expects:

```
build/webkit-android/
  lib/*.a                    # JSC, WTF, bmalloc, ICU, libtcc.a
  include/{JavaScriptCore,wtf,bmalloc,unicode}
  JavaScriptCore/{Headers,PrivateHeaders,DerivedSources}
  cmakeconfig.h              # + BUN_WEBKIT_VERSION
```

WebKit patches are described in [§11.2](#112-webkit--javascriptcore-patch).

---

## 7. Stage 3 — TinyCC

Bun links `libtcc.a` for its built-in C compiler/FFI path. TinyCC's build assumes a host
compiler, so `scripts/build-tinycc.sh` compiles the translation units directly with the NDK
and archives them:

```sh
$ANDROID_CC -O2 -fPIC -Wall -fno-strict-aliasing \
    -DONE_SOURCE=0 -DTCC_TARGET_ARM64 \
    -I"$TINYCC_SRC" -I"$TINYCC_SRC/include" -c "$src" -o "…"
$ANDROID_AR rcs libtcc.a *.o
```

A minimal `config.h` supplies `TCC_VERSION`, `TCC_TARGET_ARM64`, and the Termux `CONFIG_TCCDIR`.
The archive is installed into `build/webkit-android/lib/` where Bun's CMake looks for it.

---

## 8. Stage 4 — Bun runtime

This is the only stage that has no upstream Android support
([oven-sh/bun#9](https://github.com/oven-sh/bun/issues/9) is closed as *not planned*).

### 8.1 Clone and patch

`scripts/apply-patches.sh` clones `oven-sh/bun` at `bun-v1.2.13` and applies
`patches/bun/android-support.patch`, then clones oven-sh/WebKit at the pinned commit and
applies the WebKit patch.

### 8.2 Configure

`scripts/build-bun.sh`:

```sh
cmake -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$BUN_SRC/cmake/toolchains/android-aarch64.cmake" \
    -DANDROID_NDK_HOME="$ANDROID_NDK_HOME" \
    -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_LTO=OFF \
    -DBUN_LINK_ONLY=OFF \
    -DWEBKIT_LOCAL=ON \
    -DWEBKIT_PATH="$WEBKIT_OUTPUT" \
    "$BUN_SRC"
```

### 8.3 Zig vendor patch timing

Bun downloads its own Zig fork (`0.14.0-bun`) during the build. The POSIX patch must land
**after** the download and **before** the Zig compilation:

```sh
ninja clone-zig || true           # triggers the vendor download if the target exists
patch -p1 < patches/zig/posix-android-sigaction.patch   # applied in $BUN_SRC
```

If the first `ninja` fails because Zig arrived mid-build, the script applies the patch,
clears both Zig caches, and retries once.

### 8.4 Zig cache aliasing

Zig uses two cache locations: the explicit `--cache-dir` under `$BUN_BUILD/cache/zig/local`
and the implicit `$BUN_SRC/.zig-cache`. `translate-c` writes into one and `build-obj` looks in
the other; when they are distinct stale trees the build fails with
`file_hash FileNotFound`. The script deletes both and symlinks them:

```sh
rm -rf "$BUN_BUILD_ABS/cache/zig" "$BUN_SRC_ABS/.zig-cache"
mkdir -p "$BUN_BUILD_ABS/cache/zig/local" "$BUN_BUILD_ABS/cache/zig/global"
ln -sfn "$BUN_BUILD_ABS/cache/zig/local" "$BUN_SRC_ABS/.zig-cache"
```

### 8.5 Result

`build/bun-build/bun` — an aarch64 ELF with **no** module graph. Verify with
`file … | grep aarch64` and `readelf -h … | grep Machine`.

---

## 9. Stage 5 — libopentui.so

`scripts/build-opentui.sh` clones `anomalyco/opentui` at `v0.5.10` and applies three patches
([§11.4](#114-opentui-patches)). It then prepares a merged Bionic sysroot because Zig's
`translate-c` needs real NDK headers for `miniaudio` and `yoga`:

```
build/bionic-include/            # NDK usr/include + usr/include/aarch64-linux-android
  miniaudio.h
  yoga/yoga/…
  __opentui/miniaudio_shimmed.h  # defines _Nullable / _Nonnull then includes ../miniaudio.h
  __opentui/Yoga_shimmed.h
```

plus a Zig libc description file:

```
include_dir=<bionic include dir>
sys_include_dir=<bionic include dir>
crt_dir=<NDK>/usr/lib/aarch64-linux-android/24
```

The vendored Zig dependencies (`yoga`, `uucode-opentui`, `uucode-ghostty`, `ghostty`) are
downloaded and, where upstream does not publish them, `build.zig`/`build.zig.zon` are generated
for the Zig 0.16 API. Build:

```sh
zig build -Dlibrary-target=aarch64-linux-android -Doptimize=ReleaseSafe
```

Two post-conditions are enforced, because both have caused silent runtime failures:

```sh
file libopentui.so | grep aarch64                       # correct architecture
readelf -d libopentui.so | grep 'NEEDED.*libc.so'      # required for dlopen
```

---

## 10. Stage 6 — OpenCode bundle and module-graph transplant

`bun build --compile` has no Android target, so the pipeline compiles for the host and moves
the serialized module graph onto the Android runtime.

### 10.1 Host bundling

`scripts/build-opencode-android.ts` (run with the pinned host Bun) does four things:

1. Fetches `models.dev/api.json` and writes `src/provider/models-snapshot.js` (3 attempts,
   15 s timeout each; `MODELS_DEV_API_JSON` can supply a local copy).
2. Reads `migration/*/migration.sql` into the `OPENCODE_MIGRATIONS` define.
3. Calls `Bun.build({ target: "bun", compile: { outfile, autoload*…, execArgv } })` with the
   Solid plugin, the parser worker and the TUI worker as entry points.
4. Stops. Format handling lives in the Python tool.

`build-opencode.sh` first rewrites `catalog:` references from the root `package.json` catalog
(Bun 1.2.13 cannot resolve the workspace protocol) and drops `@types/bun`, whose catalog
version forces a `git clone` that fails in CI. It also swaps the x64 `libopentui.so` in
`node_modules` for the aarch64 build before bundling, then restores it.

### 10.2 Standalone binary format (measured, not assumed)

```
[bun runtime][string data][module list][Offsets][trailer "\n---- Bun! ----\n"][total: u64 LE]
                                     |<---------- module graph ------------->|
```

| Bun | `Offsets` size | fields | module stride | footer |
|---|---|---|---|---|
| ≤ 1.3.2 (pinned: 1.2.13) | 24 B | `byte_count u64`, `modules_ptr (u32 off, u32 len)`, `entry_point_id u32`, 4 B pad | 36 B: 4 StringPointers + 3 u8 + 1 pad | trailer at `EOF-8-16`, `total_byte_count == file size` |
| ≥ 1.3.11 (target of the upgrade) | 32 B | + `compile_exec_argv`, `flags u32` | 52 B: 6 StringPointers + 4 u8 | trailing data after the trailer; no size footer at EOF |

All StringPointer offsets are **relative to the graph start**. Measured examples:

```
bun 1.2.13 host build: offsets=24B stride=36B modules=1 entry=0 payload=108B  trailing=8B
bun 1.3.14 host build: offsets=32B stride=52B modules=1 entry=0 payload=125B trailing=47051B
```

> **Critical history.** The original TypeScript extractor hardcoded `OFFSETS_SIZE = 32` and
> required the trailer at `EOF-8-16`. The workflow pins Bun **1.2.13**, whose struct is 24
> bytes: the read slid 8 bytes past the struct, `byte_count` became garbage, and
> `hostBunSize = file_length - 8 - moduleGraphSize` went negative. The transplant step could
> never succeed with the pinned toolchain. `scripts/transplant-bun-graph.py` replaced it and
> auto-detects both the struct size and the stride.

### 10.3 Transplant algorithm

`scripts/transplant-bun-graph.py` exposes `inspect`, `transplant`, `verify`:

1. **Locate** the last occurrence of `\n---- Bun! ----\n` (the marker also exists inside the
   runtime's data section, so the last match is the graph trailer).
2. **Try** `Offsets` sizes 32 and 24; for each, try strides 52 and 36.
3. **Validate** before accepting a candidate:
   - `byte_count > 0` and `graph_start = offsets_start - byte_count ≥ 0`
   - `modules_offset + modules_length ≤ byte_count`
   - `byte_count - (modules_offset + modules_length) ≤ 16` (version-specific NUL padding)
   - `modules_length % stride == 0`, `entry_point_id < module_count`
   - every StringPointer satisfies `offset + length ≤ modules_offset` (this is what
     distinguishes a real 36-byte parse from a misaligned 52-byte parse)
   - for 32-byte `Offsets`: `argv_offset + argv_length ≤ byte_count`
4. **Patch** the bundle's `undici` re-export inside the string-data region only:
   ```
   __reExport(exports_Undici, undici)  ->  __reExport(exports_Undici, Undici)
   ```
   Identical length, so no offset is rewritten. Android Bun exposes the module object as the
   global `Undici`, not `undici`.
5. **Assemble** `runtime ++ graph(through trailer) ++ u64(total)` and `chmod 755`.
6. **Re-parse the output** and require layout v1, the expected stride, and
   `total_byte_count == file size`. A failed round-trip is a hard error.

Commands:

```sh
# what layout is this binary?
python3 scripts/transplant-bun-graph.py inspect build/dist/libexec/opencode/opencode.bin

# graft a host graph onto the Android runtime
python3 scripts/transplant-bun-graph.py transplant \
    --host   build/dist/opencode-host \
    --bun    build/bun-build/bun \
    --output build/dist/libexec/opencode/opencode.bin \
    --expect-stride 36

# CI gate
python3 scripts/transplant-bun-graph.py verify \
    build/dist/libexec/opencode/opencode.bin --expect-stride 36
```

The tool refuses, with an actionable message, when the host uses layout v2 (Bun ≥ 1.3.11)
while the runtime is built from 1.2.x, and when the stride does not match
`MODULE_GRAPH_STRIDE`.

### 10.4 Stage and verify

`build-opencode.sh` creates `dist/bin`, `dist/libexec/opencode`, `dist/lib`, writes the
launcher, copies `libopentui.so`, the NDK's `libc++_shared.so` (when present), and
`libtagfix.so` (only when supplied), then runs `verify` and prints the tree for CI to assert.

---

## 11. Patch reference (diffs + reasoning)

All patches are unified diffs applied with `git apply` in a clean source tree. Paths are
relative to the upstream repository root.

### 11.1 Bun (`patches/bun/android-support.patch`, 33 files)

#### A. Android CMake toolchain — *new file*, `cmake/toolchains/android-aarch64.cmake`

**Why.** Bun's CMake has no Android support: no sysroot, no versioned NDK compiler prefix, no
Bionic awareness. This file makes CMake treat the build as a real Android cross build and is
what `build-bun.sh` passes as `CMAKE_TOOLCHAIN_FILE`.

```diff
+set(CMAKE_SYSTEM_NAME Android)
+set(CMAKE_SYSTEM_PROCESSOR aarch64)
+set(ABI android)
+set(ANDROID_PLATFORM 24)
+set(CMAKE_SYSTEM_VERSION ${ANDROID_API_LEVEL})
+set(CMAKE_ANDROID_ARCH_ABI arm64-v8a)
+
+# must survive try_compile re-processing
+list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES ANDROID_NDK_HOME)
+set(NDK_TOOLCHAIN "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64")
+set(CMAKE_SYSROOT "${NDK_TOOLCHAIN}/sysroot")
+set(CMAKE_C_COMPILER   "${NDK_TOOLCHAIN}/bin/aarch64-linux-android24-clang")
+set(CMAKE_CXX_COMPILER "${NDK_TOOLCHAIN}/bin/aarch64-linux-android24-clang++")
+set(CMAKE_ASM_COMPILER "${NDK_TOOLCHAIN}/bin/aarch64-linux-android24-clang")
+set(CMAKE_POSITION_INDEPENDENT_CODE ON)
```

#### B. PIC / PIE / RELRO — `cmake/CompilerFlags.cmake`

**Why.** Android requires position-independent executables and shared objects (API 21+), and
Android's security model expects RELRO. Upstream Linux flags do the opposite: `-Wl,-z,norelro`
plus non-PIC Zig output. The patch keeps PIC and drops the ELF hardening only for the host
case.

```diff
 if(LINUX)
-  register_linker_flags(DESCRIPTION "Disable relocation read-only (RELRO)" -Wl,-z,norelro)
-  register_compiler_flags(DESCRIPTION "Disable semantic interposition" -fno-semantic-interposition)
+  if(ANDROID)
+    register_compiler_flags(DESCRIPTION "Enable position-independent code for Android" -fPIC)
+    register_compiler_flags(DESCRIPTION "Disable semantic interposition" -fno-semantic-interposition)
+  else()
+    register_linker_flags(DESCRIPTION "Disable relocation read-only (RELRO)" -Wl,-z,norelro)
+    register_compiler_flags(DESCRIPTION "Disable semantic interposition" -fno-semantic-interposition)
+  endif()
 endif()
```

Related hunks in the same file: `-march=armv8-a+crc` without `-mtune=ampere1` for Android
(broad device compatibility) and `_GLIBCXX_ASSERTIONS` disabled (`Bionic has no libstdc++`).

#### C. Zig CPU, NDK headers, TLS assembly — `cmake/targets/BuildBun.cmake`

**Why.** `-Dcpu=native` is invalid when cross-compiling; Zig's `translate-c` has no bundled
Android libc headers, so it needs the sysroot; and the TLS alignment object must be assembled
and linked such that `--gc-sections` cannot drop it.

```diff
+  elseif(ANDROID)
+    set(ZIG_CPU "baseline")
+if(ANDROID AND DEFINED CMAKE_SYSROOT)
+  set(ZIG_FLAGS_BUN ${ZIG_FLAGS_BUN} -Dandroid-ndk-sysroot=${CMAKE_SYSROOT})
 endif()
+
+if(ANDROID)
+  enable_language(ASM)
+  add_custom_command(OUTPUT ${ANDROID_TLS_ALIGN_OBJ}
+    COMMAND ${CMAKE_ASM_COMPILER} -c ${CWD}/src/android_tls_align.s -o ${ANDROID_TLS_ALIGN_OBJ})
+  add_dependencies(${bun} android-tls-align)
+  target_link_libraries(${bun} PRIVATE ${ANDROID_TLS_ALIGN_OBJ})
+  target_link_options(${bun} PRIVATE "LINKER:--undefined=_android_tls_align_force")
+endif()
```

#### D. ARM64 TLS alignment — *new file*, `src/android_tls_align.s`

**Why.** Bionic's Thread Control Block occupies `TPIDR_EL0+0…63`. The TLS segment begins at
`round_up(sizeof(tcb_head), p_align)`. With `p_align=8` (what Zig's linker emits for `.tbss`)
TLS starts at `TPIDR+16` and overlaps the TCB — scudo allocator metadata is corrupted on the
first thread allocation. Forcing a 64-byte `.tbss` makes `lld` emit `PT_TLS p_align=64`, so TLS
starts at `TPIDR+64`. It **must** be assembly: the NDK's emulated TLS (`__emutls`) wrapper,
used for C/C++ thread-locals, produces no real `.tbss` section.

```asm
.section .tbss,"awT",@nobits
.balign 64
.global _android_tls_align_force
.hidden _android_tls_align_force
.type _android_tls_align_force,@tls_object
.size _android_tls_align_force,64
_android_tls_align_force:
.zero 64
```

`--undefined=_android_tls_align_force` keeps the symbol alive through `--gc-sections`.

#### E. Platform detection — `src/env.zig`

**Why.** Android reports `os.tag == .linux` but uses Bionic, not glibc or musl. Without this,
`isMusl()` is false while every glibc-only symbol path is still taken.

```diff
 pub const isLinux = ... == .linux;
+pub const isAndroid = isLinux and @import("builtin").target.abi == .android;
-pub const isMusl = builtin.target.abi.isMusl();
+pub const isMusl = !isAndroid and builtin.target.abi.isMusl();
+        .{ "android", .linux },
+        .{ "linux-android", .linux },
```

#### F. Standalone format + `find()` bug — `src/StandaloneModuleGraph.zig`

**Why.** Two independent fixes. (1) The Android runtime must understand the `Offsets` struct
the host bundler emits, including `compile_exec_argv` and `flags`. (2) Upstream
`find()` calls `isBunStandaloneFilePath(base_path)` instead of `name`, so relative module
specifiers inside a compiled standalone graph are never recognised — a genuine upstream bug.

```diff
     pub fn find(this: *const StandaloneModuleGraph, name: []const u8) ?*File {
-        if (!isBunStandaloneFilePath(base_path)) {
+        if (!isBunStandaloneFilePath(name)) {
             return null;
         }
@@ struct
         byte_count: usize = 0,
         modules_ptr: bun.StringPointer = .{},
         entry_point_id: u32 = 0,
+        compile_exec_argv_ptr: bun.StringPointer = .{},
+        flags: Flags = .{},
+    };
+
+    pub const Flags = packed struct(u32) {
+        disable_default_env_files: bool = false,
+        disable_autoload_bunfig: bool = false,
+        disable_autoload_tsconfig: bool = false,
+        disable_autoload_package_json: bool = false,
+        _padding: u28 = 0,
     };
```

> Note for the 1.3.x upgrade: this file moved to `src/standalone_graph/` and the struct grew to
> the 32-byte `Offsets` / 52-byte stride described in [§10.2](#102-standalone-binary-format-measured-not-assumed).

#### G. Bionic symbol workarounds — `src/workaround_missing_symbols.zig`

**Why.** Bionic exports `memmem`, `lstat`, `fstat`, `stat` but Zig's `translate-c` does not
surface them with the expected signatures, and glibc-compat symbol overrides must not be used.

```diff
-pub const linux = struct {
+pub const linux = if (bun.Environment.isAndroid) struct {
+    pub const memmem = bun.c.memmem;
+    pub const lstat = blk: {
+        const T = *const fn ([*:0]const u8, *std.os.linux.Stat) callconv(.C) c_int;
+        break :blk @extern(T, .{ .name = "lstat" });
+    };
+    pub const fstat = blk: { /* same shape */ };
+    pub const stat  = blk: { /* same shape */ };
+} else struct {
```

Additional Bionic gaps handled in the same patch: `pthread_setcancelstate`/`setcanceltype`
stubbed to `0` (Bionic has no POSIX thread cancellation); `posix_spawnattr_setsigdefault`/
`setsigmask` stubbed (API 28+, Bun's own `posix_spawn_bun()` configures masks via raw
syscalls); `getifaddrs`/`freeifaddrs` declared with `@extern` because `__INTRODUCED_IN(24)`
hides them from some header configurations.

#### H. `pwrite64` — `src/sys.zig`

**Why.** Bionic exposes `pwrite`, not the glibc compat alias `pwrite64`.

```diff
-const pwrite_sym = if (builtin.os.tag == .linux and builtin.link_libc and !bun.Environment.isMusl)
+const pwrite_sym = if (builtin.os.tag == .linux and builtin.link_libc and !bun.Environment.isMusl and !bun.Environment.isAndroid)
```

#### I. Strict `open()` signature — `packages/bun-usockets/src/bsd.c`

**Why.** Passing a mode to `open()` without `O_CREAT` is undefined behaviour and Bionic is
stricter than glibc.

```diff
-            int socket_dir_fd = open(dirname_buf, O_CLOEXEC | O_PATH | O_DIRECTORY, 0700);
+            int socket_dir_fd = open(dirname_buf, O_CLOEXEC | O_PATH | O_DIRECTORY);
```

#### J. Syscall compatibility (`src/linux.zig`, `src/fs.zig`, `src/bun.js/node/*`)

Android's zygote seccomp policy traps several syscalls with `SECCOMP_RET_TRAP`, which raises
`SIGSYS` (exit 159) instead of returning `ENOSYS`:

| Syscall | Handling |
|---|---|
| `close_range` | replaced with an explicit loop over `/proc/self/fd` |
| `preadv2` / `pwritev2` | return `ENOSYS`; Bun falls back to `pread`/`pwrite` loops |
| `epoll_pwait2` | returns `ENOSYS`; falls back to `epoll_pwait` |
| `lchmod` | returns `ENOSYS` (absent from Bionic) |

#### K. Everything else in the 33-file patch

Linking and build plumbing: `-lpthread` removed (Bionic merges pthread into libc), Rust linker
set to the versioned NDK clang for `lol-html`, `CARGO_ENCODED_RUSTFLAGS` replaced with
`RUSTFLAGS` (CMake cannot encode the `0x1F` separator), `-Wno-undefined-var-template` for
Clang 19, `if(NOT ANDROID)` guards around post-link steps that execute the aarch64 binary
(`bun --revision`, `features.json`), and an aarch64 crash handler with register dump and
`/proc/self/maps`. Behavioural guards: `bun upgrade` disabled (no Android channel), higher
default fd limit, npm libc reporting as `glibc` for package resolution.

#### L. Optional: seccomp `SIGSYS` handler (`patches/bun/android-seccomp-sigsys.patch`)

Used by the **v2** pipeline (`build-bun-android.sh`) to adopt upstream
[oven-sh/bun#39775](https://github.com/oven-sh/bun/pull/39775), which the v1 build does not
need because it replaces `close_range` outright. For reference, the mechanism is:

```c
static void onSIGSYS(int sig, siginfo_t* info, void* context)
{
    if (info->si_code == SYS_SECCOMP && context) {
        ucontext_t* uc = static_cast<ucontext_t*>(context);
#if CPU(X86_64)
        uc->uc_mcontext.gregs[REG_RAX] = -ENOSYS;
#else
        uc->uc_mcontext.regs[0] = static_cast<unsigned long long>(-ENOSYS);
#endif
        return;
    }
    ...forward kill(2)-sent SIGSYS to JS...
}
```

The handler rewrites the trapped syscall's return register, so callers observe `ENOSYS` and
run their fallbacks instead of dying. It also removes `SIGSYS` from `blockall` in
`posix_spawn_bun()` — a seccomp trap on a **blocked** `SIGSYS` is fatal.

### 11.2 WebKit / JavaScriptCore patch

`patches/webkit/android-support.patch` — 5 files, all self-contained.

**(a) JIT signal traps — `Source/JavaScriptCore/runtime/InitializeThreading.cpp`**

Android's `debuggerd` intercepts `SIGSEGV`/`SIGBUS` before user-space handlers, so signal-based
JIT bounds checks and Wasm memory faults become process crashes. Polling traps and explicit
bounds checks replace them.

```diff
+#if defined(__ANDROID__)
+        {
+            Options::AllowUnfinalizedAccessScope scope;
+            Options::usePollingTraps() = true;
+            Options::useWasmFaultSignalHandler() = false;
+            Options::useWasmFastMemory() = false;
+        }
+#endif
```

**(b) `aligned_alloc` → `posix_memalign`** (`Source/bmalloc/bmalloc/DebugHeap.cpp`) —
`aligned_alloc` requires API 28.

```diff
+#if defined(__ANDROID__)
+    void* result = nullptr;
+    if (::posix_memalign(&result, alignment, size) != 0)
+        result = nullptr;
+#else
     void* result = ::aligned_alloc(alignment, size);
+#endif
```

**(c) `bcmp` → `memcmp`** (`libpas/pas_min_heap.h`) — `bcmp` is a BSD legacy function absent
from Bionic.

```diff
-        PAS_ASSERT(!bcmp(name##_get_ptr_by_index(min_heap, index), &element, sizeof(type))); \
+        PAS_ASSERT(!memcmp(name##_get_ptr_by_index(min_heap, index), &element, sizeof(type))); \
```

**(d) `backtrace` and `pthread_getname_np`** — `backtrace()` requires API 33;
`pthread_getname_np` requires API 26, so diagnostics degrade instead of failing the link.

```diff
-#if !PAS_PLATFORM(PLAYSTATION) && __has_include (<execinfo.h>)
+#if !PAS_PLATFORM(PLAYSTATION) && !defined(__ANDROID__) && __has_include (<execinfo.h>)
@@
+#elif defined(__ANDROID__)
+    /* pthread_getname_np requires API 26+, stub for API 24 */
+    getname_result = -1;
```

### 11.3 Zig stdlib patch (`patches/zig/posix-android-sigaction.patch`)

**Why.** Zig's `linux.Sigaction` is 152 bytes with a 128-byte `sigset_t`; Bionic's
`struct sigaction` is 32 bytes with an 8-byte `sigset_t`. Passing Zig's struct to Bionic's
`sigaction()` corrupts 120 bytes of adjacent memory — silently. The patch bypasses libc and
issues `rt_sigaction`/`rt_sigprocmask` with the kernel layout.

```diff
 pub fn sigaction(sig: u6, noalias act: ?*const Sigaction, noalias oact: ?*Sigaction) void {
-    switch (errno(system.sigaction(sig, act, oact))) {
+    if (comptime builtin.abi.isAndroid()) {
+        switch (E.init(linux.sigaction(sig, act, oact))) {
+            .SUCCESS => return,
+            else => unreachable,
+        }
+    } else {
+        switch (errno(system.sigaction(sig, act, oact))) {
+            .SUCCESS => return,
+            else => unreachable,
+        }
+    }
```

`sigprocmask` receives the same treatment (`linux.sigprocmask`). Applied to Bun's vendored
`vendor/zig/lib/std/posix.zig` by `build-bun.sh` after `clone-zig`.

### 11.4 OpenTUI patches

**(a) Retired: NDK `libc.so` link (`patches/opentui/android-libc-link.patch`)**

**Why it is gone.** The patch targeted `packages/core/src/zig/build.zig`, which does not exist
at OpenTUI v0.5.10 (or on main). It had been skipped silently since the OpenTUI build was
refactored, and successful builds still passed the `NEEDED libc.so` check because
`packages/native/build.zig` sets `module.link_libc = true`. The patch was therefore removed
instead of being wired into the strict apply path; the real contract is still enforced by the
post-build `readelf -d … | grep NEEDED.*libc.so` check.

**(b) ghostty Metal library (`patches/opentui/ghostty-android-metallib.patch`)**

**Why.** OpenTUI vendors ghostty; its `SharedDeps.initTarget()` unconditionally builds a Metal
shader library, which does not exist on Android (and `framedata` is unused by the VT module).

```diff
-        .framedata = try .init(b),
+        // OpenTUI only consumes the ghostty-vt module, which does not use GUI frame data.
+        .framedata = undefined,
@@
-    // Update our metallib
-    self.metallib = .create(b, .{ ... });
+    // Only create metallib for Apple targets (macOS, iOS, etc.)
+    if (target.result.os.tag.isDarwin()) {
+        self.metallib = .create(b, .{ ... });
+    }
```

The local metallib patch contains only the guard hunk; the `.framedata` change is provided by
OpenTUI's `ghostty-shared-deps.patch`. Its context was regenerated against the pinned commit
`aeda37b` and the guard reads `target.result.os.tag.isDarwin()`: `std.Build.ResolvedTarget`
exposes the target as `.result` in Zig 0.16, and `isIOS()`/`isMacOS()` are already covered by
`isDarwin()`. The previous context no longer matched the pinned source, so the patch would have
been rejected as soon as the shared-deps failure stopped masking it. `build-opentui.sh` applies both through
`apply_verified_patch` and fails unless the corresponding marker is present in
`src/build/SharedDeps.zig`.

**The silent-skip trap (CI run 41279562301).** The ghostty tree is extracted into
`build/opentui-src/packages/native/zig-deps/ghostty`, which lives inside the
`opencode-termux` worktree but is not itself a Git repository. `git apply` resolves patch
paths against the worktree root of the *enclosing* repository, so it looked for
`opencode-termux/src/build/SharedDeps.zig`, printed `Skipped patch 'src/build/SharedDeps.zig'.`,
and **exited 0**. Both `git apply --check` and `git apply` therefore reported success while
the file stayed untouched, and the helper failed afterwards on the missing marker:

```text
    ghostty shared-deps: applied
ERROR: ghostty shared-deps patch did not take effect in src/build/SharedDeps.zig
       expected marker: .framedata = undefined,
```

`apply_verified_patch` now runs `git init -q` in any vendor tree that has no `.git`, so patch
paths resolve from that tree, and it also treats `Skipped patch` in `git apply --verbose`
output as a hard failure. Vendor clones created with `git clone`/`git init` (Bun, WebKit,
OpenTUI) were never affected because their own `.git` stops the upward search.

**(c) `patches/opentui/v2-0.5.10-android.patch`** — adds the `aarch64-linux-android` library
target to `packages/native/build.zig`, the Bionic sysroot include/lib helpers consumed by
`build-opentui.sh`, and Android guards around `pthread`/`m` linkage.
Applied through `apply_verified_patch` with the marker `fn bionicSysrootInclude` in
`packages/native/build.zig`.


---

## 12. Packaging

`scripts/make-packages.sh` consumes `dist/{bin,libexec,lib}` and produces three formats plus
checksums. All three install to the same `$PREFIX` paths.

| Format | Name | Contents |
|---|---|---|
| Zip | `opencode-1.19.4-android-aarch64.zip` | `bin/`, `libexec/opencode/`, `lib/` — unpack with `unzip -o … -d "$PREFIX"` |
| Pacman | `opencode-1.19.4-1-aarch64.pkg.tar.xz` | `.PKGINFO` + `data/data/com.termux/files/usr/{bin,libexec/opencode,lib}` |
| Deb | `opencode_1.19.4_aarch64.deb` | `DEBIAN/control` + `data/data/data/com.termux/files/usr/{…}` |

`.PKGINFO`:

```
pkgname = opencode
pkgver = 1.19.4-1
arch = aarch64
license = MIT
depend = ripgrep
size = <bytes installed>
```

`DEBIAN/control` mirrors it with `Installed-Size`, `Depends: ripgrep`, and Section/Priority.
`SHA256SUMS` is written alongside. The deb is assembled with `ar` rather than `dpkg-deb` so the
same script runs on Termux.

> Package name and layout changed from the old flat zip (`opencode` + libs side by side) to the
> `$PREFIX` tree. `README` install instructions match the new layout; scripts and CI assert it.

---

## 13. CI pipeline

`.github/workflows/build.yml` — `ubuntu-latest`, 360-minute timeout, two jobs.

**Triggers:** tag push `v*`, pull request to `main`/`master`, manual dispatch with an optional
`opencode_version` input and `force_rebuild`.

**`build-android-aarch64`:**

1. Checkout, workspace init, `df -h`.
2. Install packages (`ninja-build`, `python3`, `ruby`, `perl`, `patchelf`, `libxml2-dev`, …) and
   CMake 3.28 if the runner's is older than 3.24.
3. Install Android NDK r28b to `/opt/android-ndk`; export `ANDROID_NDK_HOME` and `PATH`.
4. Install Rust with the `aarch64-linux-android` target (for `lol-html`).
5. Install Zig 0.16.0 into `build/zig-0.16.0`; export `ZIG_BIN`.
6. Install host Bun **pinned to 1.2.13** and pre-install `@types/bun` plus all four
   `@opentui/core-linux-*` variants to avoid `git clone` fallbacks during `bun install`.
7. Compute patch hashes (`sha256sum | cut -c1-16`) for cache keys.
8. Cache ICU prefix, WebKit output, Bun binary, `libopentui.so`, and `opencode-src/node_modules`.
9. Apply patches; build ICU → WebKit → TinyCC → Bun → libopentui.so.
10. Build OpenCode, then verify:
    ```sh
    file   "${WORK_DIR}/dist/libexec/opencode/opencode.bin" | grep aarch64
    readelf -h  … | grep -E "Machine|Class"
    readelf -lW … | grep -E "GNU_RELRO|GNU_STACK"
    python3 scripts/transplant-bun-graph.py verify … --expect-stride "$MODULE_GRAPH_STRIDE"
    ```
11. Package, upload artifacts (`packages/*.zip`, `*.pkg.tar.xz`, `*.deb`), and on a tag create
    a GitHub release.

`Lint patch application` runs before any source is cloned. It fails the job on a patch command
that swallows failure (`|| true`) or that skips on a context mismatch, so a stale vendor patch
cannot become a silent no-op.

**`validate-artifacts`:** downloads the artifact, lists the zip/pacman/deb contents, extracts
the zip and asserts the binary is aarch64. It looks specifically for `opencode.bin` — searching
for `opencode` would find the shell launcher and `readelf` would fail on it.

**Patch lint.** Immediately after dependency installation, and before any source is cloned,
`python3 scripts/lint-patch-application.py` runs as its own step. It fails the job on patch
commands that swallow failure (`|| true`, `|| :`, `|| exit 0`) or that skip on a context
mismatch, so a stale vendor patch cannot become a silent no-op. It also cross-checks that
every patch under `patches/` is applied by some script, at most once per script, and that each
application asserts a marker present in the patch text.

**Cleanup** always runs: removes source trees and the Zig cache (stale references inside
deleted trees cause `FileNotFound` on the next run) while keeping cached artifacts.

---

## 14. Upgrade status: Bun 1.3.14

The original design targeted Bun 1.3.14 (`Offsets` 32 B, stride 52 B). It is **not** a patch
rebase, and the pipeline stays on 1.2.13 until the work below is done.

**Blocker: the build system was replaced.**

```sh
$ git ls-tree -r --name-only bun-v1.3.14 | grep '^cmake/'     # no output
$ git ls-tree -r --name-only bun-v1.3.14 | grep build.zig     # build.zig
```

`scripts/build-bun.sh` drives CMake plus `cmake/toolchains/android-aarch64.cmake`. With no
`cmake/` tree upstream, that stage must be ported to `build.zig` before any patch work matters.

**Blocker: sources moved.** Roughly half of the 33 patched files no longer exist at their old
paths:

| 1.2.13 path | 1.3.14 path |
|---|---|
| `src/standalone/StandaloneModuleGraph.zig` | `src/standalone_graph/StandaloneModuleGraph.zig` |
| `src/bun.js/bindings/*.cpp` | `src/jsc/bindings/*.cpp` |
| `src/bun.js/node/node_fs.zig`, `node_os.zig` | `src/runtime/node/*` |
| `src/deps/c_ares.zig` | `src/cares_sys/c_ares.zig` |
| `src/deps/tcc.zig` | `src/tcc_sys/tcc.zig` |
| `src/Global.zig`, `src/env.zig` | `src/bun_core/*` |
| `src/fs.zig` | `src/resolver/fs.zig` |
| `src/linux.zig` | `src/platform/linux.zig` |
| `src/sys.zig` | `src/sys/sys.zig` |
| `src/crash_handler.zig` | `src/crash_handler/crash_handler.zig` |
| `src/test/recover.zig` | `src/test_runner/harness/recover.zig` |

**Blocker: format v2.** 1.3.14 emits a 32-byte `Offsets`, 52-byte modules and 47 KB of trailing
data after the trailer. A 1.2.13 runtime cannot read it; `transplant-bun-graph.py` refuses the
graft rather than shipping a binary that crashes at startup.

**What is already reusable.** `transplant-bun-graph.py inspect` reports the layout of any
standalone binary, so the format half of a bump can be validated before the port:

```sh
python3 scripts/transplant-bun-graph.py inspect /path/to/standalone
# layout=v2 offsets=32B stride=52B modules=1 entry=0 flags=12 … trailing: 47051 bytes
```

`MODULE_GRAPH_STRIDE` and `BUN_VERSION` are already decoupled from the format code, and the
tool's candidate search accepts either struct size.

**Suggested order for the upgrade:**

1. Port `build-bun.sh` (and the toolchain) to `build.zig`; get an unpatched aarch64 build.
2. Rebase `patches/bun/android-support.patch` file-by-file onto the moved tree; keep the
   `find()` fix and TLS assembly first (they are the smallest, highest-value hunks).
3. Re-validate `isAndroid`/`isMusl` and every syscall fallback against the new Zig stdlib.
4. Set `BUN_VERSION=1.3.14` **and** `MODULE_GRAPH_STRIDE=52` together; re-run the round-trip
   test and the CI verifier.
5. Re-check the `undici` global name; the bundler's emitted call pattern is version-dependent.

---

## 15. Verification and audit

### 15.1 Format round-trip (no Android device required)

```sh
# 1. Get the pinned host bun
curl -fsSL -o bun.zip https://github.com/oven-sh/bun/releases/download/bun-v1.2.13/bun-linux-x64.zip
unzip -q bun.zip -d bun1213
# 2. Compile a trivial entrypoint
printf 'console.log("hi");\n' > index.ts
bun1213/bun-linux-x64/bun build --compile index.ts --outfile host
# 3. Transplant back onto the same runtime and compare
python3 scripts/transplant-bun-graph.py transplant \
    --host host --bun bun1213/bun-linux-x64/bun \
    --output assembled --expect-stride 36
cmp host assembled && echo "byte-identical"
```

Expected: `byte-identical` (this is how the tool was validated; with the undici pattern absent
it emits a warning, not an error).

### 15.2 Artifact checks

```sh
file build/bun-build/bun | grep aarch64
readelf -h build/bun-build/bun | grep -E 'Machine|Class'
file build/opentui-src/packages/native/lib/aarch64-linux-android/libopentui.so | grep aarch64
readelf -d …/libopentui.so | grep 'NEEDED.*libc\.so'
readelf -lW build/dist/libexec/opencode/opencode.bin | grep GNU_RELRO
python3 scripts/transplant-bun-graph.py verify build/dist/libexec/opencode/opencode.bin --expect-stride 36
unzip -l build/packages/*.zip
tar -tf  build/packages/*.pkg.tar.xz | grep -E 'bin/opencode$|opencode\.bin$|libopentui\.so$'
dpkg-deb -c build/packages/*.deb | grep opencode
(cd build/packages && sha256sum -c SHA256SUMS)
```

### 15.3 Patch audit (no stubs, no placeholders)

```sh
grep -rn "TODO\|FIXME\|PLACEHOLDER\|NotImplemented" patches/ scripts/ \
    --include='*.patch' --include='*.sh' --include='*.py'
```

Expected: no matches in code paths. The word "stub" appears legitimately in comments describing
Android API gaps (`backtrace`, `pthread_getname_np`), which is documentation, not missing code.

### 15.4 Static checks that run without an NDK

```sh
for f in scripts/*.sh; do bash -n "$f"; done
python3 scripts/lint-patch-application.py
python3 -m py_compile scripts/transplant-bun-graph.py
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build.yml'))"
```

### 15.5 Packaging smoke test

Create a fake `build/dist/{bin,libexec/opencode,lib}` with any ELF (`/bin/true`) and stub `.so`
files, run `./scripts/make-packages.sh`, and confirm the listings above. This validates the
layout logic without a full build.

---

## 16. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `error: "git clone" for "@types/bun" failed` | catalog version pulls from git | `bun add -g @types/bun@1.2.13` before install; script also strips it |
| `WARNING: ARM64 libopentui.so not found … keeping x86_64 version` | Zig build produced no aarch64 artifact, or path mismatch | build with `-Dlibrary-target=aarch64-linux-android`; check `packages/native/lib/aarch64-linux-android/` |
| `Could not resolve: "@opentui/core-linux-arm64-musl"` | optional native packages not installed on host | install all four `@opentui/core-linux-*` variants before bundling |
| `FileNotFound` in Zig `translate-c` cache | cache references deleted source trees | clear both caches and re-symlink (see §8.4) |
| `Derived host bun size is negative` (old extractor) | 32-byte `Offsets` assumed against a 1.2.13 binary | use `transplant-bun-graph.py`; see §10.2 |
| `layout v2 … cannot be transplanted` | host Bun ≥ 1.3.11 with a 1.2.x runtime | pin host and target to the same Bun |
| `module graph uses a 52-byte stride but 36 was expected` | host/target mismatch | set `MODULE_GRAPH_STRIDE` to match `BUN_VERSION` |
| `PREFIX: unbound variable` in packaging | unescaped `$PREFIX` in a shell string under `set -u` | quote with single quotes or `\${PREFIX}` |
| `Package not found` / launcher exits 127 | zip unpacked flat instead of over `$PREFIX` | `unzip -o … -d "$PREFIX"` |
| aarch64 binary "cannot execute" on x86 host | post-link steps run the target binary | `if(NOT ANDROID)` guards in the Bun patch |
| instant crash on first allocation | `PT_TLS p_align=8` overlapping Bionic TCB | keep `android_tls_align.s` linked with `--undefined` |

---

## 17. Known issues

| Issue | Severity | Detail |
|---|---|---|
| `@parcel/watcher` native binding | Low | Only an x86_64 `.node` is bundled; Bun logs the `dlopen` mismatch and falls back to polling |
| `bun upgrade` | Low | Disabled on Android; no release channel exists |
| TinyCC FFI | Low | `libtcc.a` links, but TCC's code generation may not emit valid ARM64 |
| `libtagfix.so` | Info | Not produced by any script; packaged only when supplied in `build/` |
| SIGPWR noise in `strace` | None | Android power management / Bun signal handling, not errors |

---

## 18. Appendix: pins, files, references

### 18.1 Upstream references

| Component | Source | Pin |
|---|---|---|
| OpenCode | `https://github.com/anomalyco/opencode` | tag `v1.19.4` |
| Bun | `https://github.com/oven-sh/bun` | tag `bun-v1.2.13` |
| WebKit | `https://github.com/oven-sh/WebKit` | `017930ebf915121f8f593bef61cbbca82d78132d` |
| OpenTUI | `https://github.com/anomalyco/opentui` | tag `v0.5.10` |
| TinyCC | `https://github.com/oven-sh/tinycc` | `b91835d8701523e895a2b447713630069514e291` |
| ICU | `https://github.com/unicode-org/icu` | release `75-1` |
| Bun Android issue | `https://github.com/oven-sh/bun/issues/9` | closed, not planned |
| Seccomp `SIGSYS` fix | `https://github.com/oven-sh/bun/pull/39775` | v2 pipeline |

### 18.2 Repository map

```
patches/
  bun/android-support.patch            33 files: toolchain, TLS, Bionic, syscalls, JIT
  bun/android-seccomp-sigsys.patch     optional: seccomp SIGSYS -> ENOSYS (v2)
  webkit/android-support.patch         5 files: bcmp/backtrace/getname/memalign + JSC traps
  zig/posix-android-sigaction.patch    raw rt_sigaction/rt_sigprocmask on Android
  opentui/v2-0.5.10-android.patch      aarch64 target + Bionic sysroot helpers
  opentui/ghostty-android-metallib.patch  skip Metal shader lib on non-Apple
cmake/
  webkit-android-toolchain.cmake       JSCOnly cross toolchain (paths rewritten at run time)
scripts/
  env.sh                               shared environment and version pins
  apply-patches.sh                     clone + apply Bun/WebKit patches
  build-icu.sh                         host tools + cross ICU
  build-webkit.sh                      JSCOnly static libraries and header layout
  build-tinycc.sh                      libtcc.a for aarch64
  build-bun.sh                         CMake + patched Zig vendor + cache aliasing
  build-opentui.sh                     Zig build, Bionic sysroot, dependency vendoring
  build-opencode.sh                    host bundle -> transplant -> $PREFIX staging
  build-opencode-android.ts            models snapshot, migrations, host standalone compile
  transplant-bun-graph.py              inspect / transplant / verify the module graph
  make-packages.sh                     zip, pacman, deb, SHA256SUMS
.github/workflows/build.yml            CI: build, verify, package, release
```

### 18.3 Data-flow summary

```
opencode v1.19.4 (TS) --host bun 1.2.13--> host standalone (graph embedded)
        graph + undici patch
Android bun 1.2.13 (aarch64) --+--> opencode.bin ($PREFIX/libexec/opencode)
libopentui.so (aarch64) -------+--> $PREFIX/lib
launcher ----------------------+--> $PREFIX/bin/opencode
                                      ↓
                          zip / pacman / deb + SHA256SUMS
```

### 18.4 Manual build (CI-equivalent)

```sh
git clone <this repo> && cd opencode-termux
export ANDROID_NDK_HOME=/opt/android-ndk        # r28b
export PATH="$HOME/.bun/bin:$PATH"              # bun 1.2.13
./scripts/apply-patches.sh
./scripts/build-icu.sh
./scripts/build-webkit.sh
./scripts/build-tinycc.sh
./scripts/build-bun.sh
./scripts/build-opentui.sh
./scripts/build-opencode.sh
./scripts/make-packages.sh
python3 scripts/transplant-bun-graph.py verify \
    build/dist/libexec/opencode/opencode.bin --expect-stride 36
```

Each script sources `scripts/env.sh`, validates its prerequisites, and uses `set -euo pipefail`.

---

## 19. Implementation strategy

This section is the "why" behind the pipeline. It is written for someone who has to change
it, not just run it: the decisions, the alternatives that were rejected, the invariants that
make the artifact valid, and the cost model that shapes the CI.

### 19.1 Four projects wearing one trench coat

OpenCode is not a normal cross-compile. Four largely independent build problems are stacked,
and each one can fail on its own:

| # | Problem | Built with | Result |
|---|---|---|---|
| 1 | **Bun runtime** — C/C++, Zig, CMake/Ninja, vendored WebKit, Rust crates | CMake + Ninja + Bun's patched Zig | aarch64 ELF `bun` with no application payload |
| 2 | **JavaScriptCore** — C++ static library, no prebuilt Android binary exists | CMake (JSCOnly port) | static libs + headers + `cmakeconfig.h` |
| 3 | **OpenTUI renderer** — Zig shared library, `dlopen`ed at runtime | Zig build | `libopentui.so` with `DT_NEEDED: libc.so` |
| 4 | **Application payload** — TypeScript, Solid JSX, worker entrypoints, migrations | Host Bun standalone + binary surgery | module graph grafted onto (1) |

Plus two support builds that exist only to feed the above: **ICU** (Unicode data for JSC and
Bun) and **TinyCC** (`libtcc.a` for Bun's FFI path). Packaging is a seventh concern and is
deliberately kept trivial: a directory tree plus three archive formats.

The strategy in one sentence: **cross-compile everything that must execute natively, then
move the application as data.** The application is never compiled by an Android toolchain;
the serialized module graph produced by a host Bun is byte-compatible with what the Android
runtime expects, provided the two Bun versions and the graph layout match.

### 19.2 Why not the obvious shortcuts

| Approach | Why it is not used |
|---|---|
| **proot / chroot / Termux userland** | Not native. Adds a second libc and a syscall translation layer; JSC JIT and `dlopen` of the TUI library become unreliable, and performance is unacceptable for a TUI that repaints constantly. |
| **qemu-user** | Same class of problem, worse: no JIT, no `/proc` fidelity, enormous startup cost. |
| **Termux's packaged Bun** | Does not exist for aarch64 Android at the pinned version, and stock Bun dies under Android's seccomp policy (`SIGSYS`, exit 159) on `close_range`. |
| **Wait for official Bun Android support** | [oven-sh/bun#9](https://github.com/oven-sh/bun/issues/9) is closed as *not planned*. |
| **Interpreted JSC (no JIT)** | Would remove the signal-handling class of bugs but costs an order of magnitude in throughput; OpenCode's TUI and language server work would be unusable. |
| **Ship `bun` + JS sources separately** | Loses the single-file property and still requires an Android Bun; the standalone format is the easier half once Bun builds. |
| **Patch only the app, not the runtime** | Impossible: the runtime is what lacks Android support. |

### 19.3 Decision record

| ID | Decision | Alternatives rejected | Consequence / cost |
|---|---|---|---|
| **D1** | Build Bun from source with a 33-file patch | proot, qemu, wait for upstream | 30–45 min per cold build; the patch is the project's core asset |
| **D2** | Stay on Bun **1.2.13 / CMake** | Port to 1.3.14 `build.zig` | Working build now; upgrade is a build-system port, documented in [§14](#14-upgrade-status-bun-1314) |
| **D3** | **JSCOnly**, static, no GTK/WPE | Full WebKit, WPE | Fewer dependencies, smaller build; no browser APIs, which OpenCode does not need |
| **D4** | Static ICU with `-DU_STATIC_IMPLEMENTATION=1` | Shared ICU | No runtime `.so` to ship; macro must match in WebKit and Bun or symbols duplicate |
| **D5** | Prebuild TinyCC with the NDK and inject `libtcc.a` | Let Bun's CMake build it | TinyCC's build assumes a host compiler; direct compilation is ~1 min |
| **D6** | Host-bundle + **graph transplant** | Cross `bun build --compile` (does not exist) | The format becomes a first-class contract; version pairing is mandatory |
| **D7** | One **Python** tool owns the graph format | Keep extraction in TypeScript | Testable against real Bun binaries, single source of truth, explicit exit codes |
| **D8** | Stage the **`$PREFIX` layout** (`bin`, `libexec/opencode`, `lib`) | Flat zip with siblings | Zip unpacks over `$PREFIX`; pacman/deb install identical trees; launcher resolves both |
| **D9** | POSIX `sh` launcher with Termux shebang | `/usr/bin/env`, shell wrapper in bash | Android has no `/usr/bin/env` and no guaranteed bash at that path |
| **D10** | CI-only builds | Local Termux builds | Device cannot build WebKit/Bun; caches make the warm loop ~4 minutes |
| **D11** | Zig **0.16.0** | 0.15.2 (design notes) | `build.zig` uses `addLibrary`/`root_module`, which are 0.16 APIs |
| **D12** | Rewrite `catalog:` refs at bundle time | Require Bun ≥ 1.3 for `catalog:` | Keeps host/target on 1.2.13 without forking OpenCode's manifests |
| **D13** | Keep v1 and v2 pipelines separate | One pipeline with flags | `opencode` and `opencode2` install side by side; no shared version assumptions |

**D2 in detail.** The pinned tag `bun-v1.2.13` still has a `cmake/` tree, and the 33-file
patch targets it. `bun-v1.3.14` has no `cmake/` directory at all — the build moved to
`build.zig` — and roughly fifteen patched paths moved. Porting is therefore not "rebase the
patch"; it is "reimplement the Android toolchain in Zig's build graph, then rebase". The
pipeline stays on 1.2.13 until that work is done, and the verifier refuses to pretend
otherwise.

**D6 in detail.** `bun build --compile` links a runtime and appends a serialized module graph.
The graph is portable data: string table, module descriptors, an `Offsets` struct, a trailer,
and a total-length footer. Nothing in it is x86_64-specific. So the build compiles the app
with a **host** Bun, extracts the graph, patches one symbol reference, and appends it to the
**Android** runtime. The catch is that the graph layout is versioned: host and target must
agree, and the tool must validate rather than assume.

**D7 in detail.** The original TypeScript helper hardcoded a 32-byte `Offsets` struct and
required the trailer at `EOF-8-16`. Against the pinned 1.2.13 runtime (24-byte struct) it
produced a negative host size and the transplant could never succeed. Moving the format into
`scripts/transplant-bun-graph.py` made it possible to test the parser against real standalone
binaries from Bun 1.2.13, 1.3.14 and 1.4.4, and to enforce a round-trip on every build.

### 19.4 Invariants

Violating any of these produces an artifact that builds but crashes, or a build that fails
late and expensively. Each has a detection point:

| Invariant | Why | Detected by |
|---|---|---|
| Host Bun version == target Bun version family | Graph struct size and stride are versioned | `transplant-bun-graph.py` (`--expect-stride`, layout check) |
| `MODULE_GRAPH_STRIDE` matches the runtime | A 52-byte parse of 36-byte data "succeeds" structurally but corrupts every module | StringPointer bounds check + round-trip |
| `PT_TLS p_align = 64` | Otherwise TLS overlaps Bionic's TCB and corrupts scudo on first allocation | `android_tls_align.s` linked with `--undefined`; check with `readelf -lW` |
| `libopentui.so` has `NEEDED libc.so` | `dlopen` cannot resolve `getauxval` and friends without it | `readelf -d | grep NEEDED` in `build-opentui.sh` |
| ICU built with `U_STATIC_IMPLEMENTATION=1` everywhere | Mixed static/shared macros duplicate symbols at link | Link failure; consistent flags in ICU + WebKit |
| PIE + PIC + RELRO | Android requires them for executables and `.so` files | `readelf -lW` shows `GNU_RELRO`; linker flags in the Bun patch |
| Launcher resolves installed **and** zip layouts | Users do both | `build-opencode.sh` writes both candidate paths |
| No post-link step executes the aarch64 binary | Host is x86_64 | `if(NOT ANDROID)` guards; CI would fail at configure/link otherwise |
| `total_byte_count == file size` (v1) | Runtime uses it to find the graph | `verify` subcommand, hard error |

### 19.5 The bundle path in detail

The application stage is the least obvious, so it is spelled out end to end:

1. `build-opencode.sh` clones `anomalyco/opencode` at tag `v1.19.4`.
2. It rewrites every `"catalog:"` dependency to the concrete version from the workspace
   catalog, and removes `@types/bun` (its catalog version forces a `git clone` that fails in
   CI). This is what lets Bun 1.2.13 install a manifest written for 1.3.x (D12).
3. `bun install --no-cache`, then explicitly adds the four `@opentui/core-linux-*` variants
   so bundling cannot fail on a missing optional native package.
4. It swaps the x64 `libopentui.so` inside `node_modules` for the aarch64 build, keeping a
   `.x64.bak` backup, and re-verifies architecture and `NEEDED libc.so` after the copy.
5. `build-opencode-android.ts` runs **inside** `packages/opencode` (copied there so
   `@opentui/solid/bun-plugin` resolves), fetches `models.dev/api.json`, reads
   `migration/*/migration.sql`, and calls `Bun.build({ compile: { outfile: opencode-host } })`.
6. The backup is restored, and `transplant-bun-graph.py` grafts the host graph onto
   `build/bun-build/bun`, producing `dist/libexec/opencode/opencode.bin`.
7. The launcher and native libraries are staged into `dist/{bin,libexec,lib}` and the result
   is re-parsed by `verify`.

### 19.6 README and design-note drift

Documentation in this repository has claimed things the scripts do not do. Treat prose as
context, not configuration:

| Claim in older prose | Actual implementation | Where reality lives |
|---|---|---|
| v1 uses Bun **1.3.14**, 52-byte stride | Bun **1.2.13**, 36-byte stride | `scripts/env.sh`, workflow `env:` |
| Host Bun is 1.3.14 "because of `catalog:`" | Host 1.2.13; `catalog:` is rewritten before install | `build-opencode.sh` catalog rewriter |
| Zig 0.15.2 | Zig 0.16.0 | `env.sh`, workflow |
| `build-opencode-android.ts` extracts the graph | It only bundles; Python owns the format | `build-opencode-android.ts` footer comment |
| Zip unpacks flat beside `opencode.bin` | Zip mirrors `$PREFIX` (`bin/`, `libexec/opencode/`, `lib/`) | `make-packages.sh` |

**Rule for agents:** when a document and `scripts/env.sh` disagree, the script is right, and
the stale document should be corrected in the same change that touches the version.

### 19.7 v1 vs v2 pipelines

Both engines live in this repository and must not be mixed:

| | v1 (this document) | v2 |
|---|---|---|
| Command / package | `opencode` | `opencode2` |
| OpenCode | 1.19.4 | 2.x (`2.0.0-android-termux.*`) |
| Bun | 1.2.13, source-built with the 33-file patch | 1.4.2, built via `bun scripts/build.ts --profile=android-release` with the seccomp fix |
| API level | 24 | 29 |
| Environment | `scripts/env.sh` | `scripts/env-v2.sh` |
| Build entry | `build-bun.sh`, `build-opencode.sh` | `build-bun-android.sh`, `build-opencode2-android.sh` |
| Standalone format | host-bundle + graph transplant | separate pipeline; assume nothing from v1 |
| Seccomp | `close_range` rewritten to a `/proc/self/fd` loop | `SIGSYS` handler returns `ENOSYS` (oven-sh/bun#39775) |

Sourcing `env-v2.sh` in a v1 shell (or vice versa) silently changes versions, API level and
output paths. Every v1 script sources `env.sh` explicitly; do the same in anything new.

### 19.8 Cost model

| Stage | Cold | Warm cache | Dominant cost |
|---|---|---|---|
| ICU | ~5 min | 0 (restored) | `make` of host tools + cross libs |
| WebKit/JSC | 60–90 min | 0 (restored) | C++ compile + link, memory-bound |
| TinyCC | ~1 min | ~10 s | trivial |
| Bun | 30–45 min | 0 (restored) | C++/Zig compile + link |
| OpenTUI | ~2 min | ~2 min | Zig build of vendored deps |
| OpenCode bundle + transplant | ~30 s | ~30 s | `bun install` dominates on cold npm cache |
| Packages | ~10 s | ~10 s | compression |

Sizes at the end of the pipeline (approximate, from build output): Bun runtime ~96 MB,
module graph ~46 MB, final `opencode.bin` ~136 MB. Budget ≥60 GB disk for a cold build
(WebKit alone is the largest consumer) and ≥16 GB RAM for the WebKit link. `JOBS=4` is the
CI default; raising it on a 16 GB runner risks the linker being OOM-killed. Warm runs with
WebKit and Bun restored are ~4 minutes, which is what makes the edit → CI → artifact loop
tolerable.

---

## 20. Build-system deep dive

### 20.1 Five layers

| Layer | Technology | Owns | Entry point |
|---|---|---|---|
| Orchestration | Bash (`set -euo pipefail`) | Ordering, prerequisite checks, path normalisation, staging | `scripts/*.sh` |
| Native build | CMake + Ninja | ICU, WebKit/JSC, Bun C/C++ | `build-icu.sh`, `build-webkit.sh`, `build-bun.sh` |
| Zig build | Zig 0.16.0 | Bun's Zig modules (via Bun's own build), `libopentui.so` | invoked by CMake / `build-opentui.sh` |
| Binary format | Python 3 (stdlib only) | Standalone graph parse, patch, assemble, verify | `scripts/transplant-bun-graph.py` |
| App bundling | TypeScript on host Bun | Models snapshot, migrations, `Bun.build` compile | `scripts/build-opencode-android.ts` |

There is no Makefile, no Dockerfile and no Node toolchain. Every stage is a script that can
be read end to end, which is deliberate: the build runs on a remote runner, so the scripts
must be debuggable from a log alone.

### 20.2 Toolchain contract

`scripts/env.sh` is the single source of truth for versions and paths. Its exports form a
contract that every stage depends on:

```sh
ANDROID_NDK_HOME   # NDK root (CI: /opt/android-ndk, Termux: ~/android-ndk/android-ndk-r28b)
NDK_TOOLCHAIN      # $ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64
NDK_SYSROOT        # $NDK_TOOLCHAIN/sysroot
ANDROID_CC/CXX     # $NDK_TOOLCHAIN/bin/aarch64-linux-android24-clang(++)
ANDROID_TRIPLE     # aarch64-linux-android
ANDROID_TRIPLE_API # aarch64-linux-android24  (the versioned compiler prefix)
```

Three consumers need the sysroot in different forms, which is a recurring source of bugs:

1. **CMake** receives `CMAKE_TOOLCHAIN_FILE` plus `-DANDROID_NDK_HOME=…`. The variable is
   added to `CMAKE_TRY_COMPILE_PLATFORM_VARIABLES` so `try_compile` re-processes it;
   without that, feature checks silently compile for the host.
2. **Zig's `translate-c`** (inside Bun's build) receives `-Dandroid-ndk-sysroot=$CMAKE_SYSROOT`
   because Zig ships no Android libc headers. Without it, `@cImport` of Bionic headers fails.
3. **OpenTUI's Zig build** cannot use `-Dandroid-ndk-sysroot` (it is upstream's build, not
   Bun's), so `build-opentui.sh` constructs a merged include tree (`build/bionic-include`)
   and a `zig libc` description file (`build/bionic-libc.txt`) pointing at the NDK's
   `crt_dir`, then exports `BIONIC_SYSROOT_INC`, `ZIG_LIBC` and `ANDROID_NDK_LIB_DIR`.

Rust is the fourth consumer: `lol-html` must link with the NDK's versioned clang, so the
patch sets `CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER` and replaces
`CARGO_ENCODED_RUSTFLAGS` with `RUSTFLAGS` (CMake cannot encode the `0x1F` separator).

**Path caveat.** `env.sh` defaults `WORK_DIR` to `$REPO_ROOT/build`, while the workflow sets
`WORK_DIR: ./build`. `build-icu.sh` and `build-webkit.sh` build paths as
`"${REPO_ROOT}/${WORK_DIR}/…"`, which is only correct when `WORK_DIR` is relative. Run them
with `WORK_DIR=./build` explicitly (the workflow does), and check the echoed path before a
long build. `build-opencode.sh` and `make-packages.sh` avoid the issue with an `abspath()`
helper.

### 20.3 Flag matrix

| Flag / setting | Where | Why it is there |
|---|---|---|
| `CMAKE_SYSTEM_NAME Android`, `ANDROID_PLATFORM 24`, `arm64-v8a` | Bun toolchain file | Makes CMake treat it as a real Android cross build |
| `CMAKE_POSITION_INDEPENDENT_CODE ON` | Bun toolchain file | Android requires PIC for executables and `.so` |
| `-fPIC` (instead of upstream `-fno-pic`) | `CompilerFlags.cmake` patch | Zig/CMake objects must be relocatable |
| `-pie -fPIE` | link flags | Android mandates PIE; upstream Linux used `-no-pie` |
| RELRO kept (`-Wl,-z,relro`) | link flags | Android security model; upstream Linux disables it |
| `-march=armv8-a+crc` (no `-mtune=ampere1`) | `CompilerFlags.cmake` patch | Broad device compatibility instead of server tuning |
| `-DENABLE_LTO=OFF` | `build-bun.sh` | LTO + cross NDK link is fragile and unnecessary |
| `-fno-exceptions -fno-c++-static-destructors` | WebKit flags | JSCOnly build style; smaller, faster |
| `-DU_STATIC_IMPLEMENTATION=1` | ICU and WebKit flags | Consistent static-ICU ABI; mixing duplicates symbols |
| `-Wno-undefined-var-template` | Bun flags | NDK Clang 19 warns on JSC template specialisations; `-Werror` would fail |
| `-fuse-ld=lld` | WebKit link flags | NDK's linker; matches the toolchain's `ld.lld` |
| `LINKER:--undefined=_android_tls_align_force` | Bun link flags | Keeps the TLS-alignment object through `--gc-sections` |
| `ZIG_CPU=baseline` | Bun CMake patch | `-Dcpu=native` is invalid when cross-compiling |
| `-Dandroid-ndk-sysroot=…` | Bun Zig flags | Gives `translate-c` Bionic headers |
| `-Doptimize=ReleaseSafe` | OpenTUI | Release `.so`; `-Dstrip` is not declared by OpenTUI 0.5.10 and makes Zig reject the invocation (run #41281508898) |
| `RUSTFLAGS` (space-separated) | Bun CMake patch | CMake cannot pass the encoded `0x1F` separator |

### 20.4 WebKit/JSC build graph and header contract

`build-webkit.sh` configures the JSCOnly port with `-DPORT=JSCOnly -DENABLE_STATIC_JSC=ON`
and the Bun-specific options `-DUSE_BUN_JSC_ADDITIONS=ON -DUSE_BUN_EVENT_LOOP=ON`,
`-DENABLE_BUN_SKIP_FAILING_ASSERTIONS=ON`, `-DENABLE_FTL_JIT=ON`,
`-DENABLE_REMOTE_INSPECTOR=ON`. It builds the `jsc` target and then
`JavaScriptCore_CopyPrivateHeaders`.

The script's second half is an **installation contract**: Bun's `SetupWebKit.cmake` expects
a specific `WEBKIT_LOCAL` layout, not a normal `make install` tree. It produces:

```
build/webkit-android/
  lib/*.a                                  # JSC, WTF, bmalloc, ICU, later libtcc.a, libopentui.so
  include/{JavaScriptCore,wtf,bmalloc,unicode}/
  include/cmakeconfig.h                    # + "#define BUN_WEBKIT_VERSION <commit>"
  JavaScriptCore/Headers/JavaScriptCore/   # duplicated for the SetupWebKit search path
  JavaScriptCore/PrivateHeaders/JavaScriptCore/
  JavaScriptCore/DerivedSources/inspector/ # *.json protocol files
  WTF/Headers/wtf/, bmalloc/Headers/bmalloc/
```

The commit string appended to `cmakeconfig.h` is not cosmetic: Bun records which WebKit it
was built against and uses it in diagnostics and cache keys. If the layout is wrong, Bun's
CMake finds system WebKit headers (or none) and the failure appears later as missing
`wtf/…` includes during the Bun build.

### 20.5 ICU: two builds, one prefix

ICU is built twice because cross-compiling ICU requires host tools that can *run* during the
build (`genccode`, `icupkg`, `pkgdata`). The host build installs into
`build/icu-host-build/install`; the cross build is configured with
`--with-cross-build=<host build>` and NDK compilers, static only, into
`build/deps-android/prefix`. WebKit consumes that prefix via `ICU_ROOT`/`ICU_INCLUDE_DIRS`;
Bun consumes the same prefix. If ICU is rebuilt, both consumers must be rebuilt — the
static archive is linked in, not loaded.

The configure invocation is guarded by existence checks (`bin/icupkg`, `lib/libicuuc.a`), so
re-running the script is cheap and safe. That idempotence is what makes the CI step
`if: cache-icu.outputs.cache-hit != 'true'` reliable.

### 20.6 Bun: two build systems in one build

Bun 1.2.13's build is CMake orchestrating C/C++ compilation *and* invoking its vendored Zig
fork. That produces a sequencing problem the script solves explicitly:

```
cmake -G Ninja …            # configure
ninja clone-zig || true     # download vendor/zig (target may not exist → ignore)
patch -p1 < zig/posix-android-sigaction.patch   # must precede Zig compilation
rm -rf cache/zig .zig-cache                     # avoid stale translate-c hashes
ln -sfn cache/zig/local .zig-cache              # make both cache paths one directory
ninja -j$JOBS               # build
```

If Zig only arrives *during* the build, the first `ninja` fails; the script detects that the
patch is not applied yet, applies it, clears both caches, re-links them and retries once.
That retry is the difference between a recoverable 45-minute build and a lost run. The
script also accepts `bun-profile` as the output name when `bun` is absent, since some
configurations produce only the unstripped binary.

The cache aliasing deserves its own note: Zig writes `translate-c` output into the explicit
`--cache-dir` and looks it up via the CWD-local `.zig-cache`. When they are different
physical trees, `build-obj` fails with `file_hash FileNotFound`. A symlink is the fix; a
`rm -rf` of one without the other is the bug.

### 20.7 OpenTUI: vendoring and the Bionic sysroot shim

Upstream OpenTUI does not commit its Zig dependencies, and its `build.zig.zon` expects
specific vendored trees. `build-opentui.sh` reconstructs them:

| Dependency | Source | Notes |
|---|---|---|
| `yoga` | `facebook/yoga` v3.2.1 tarball | required by the layout engine |
| `uucode-opentui` | `jacobsandlund/uucode` @ `8ad04b75…` | unicode tables |
| `uucode-ghostty` | `jacobsandlund/uucode` @ `9d555245…` | ghostty's copy; its **upstream** `build.zig`/`build.zig.zon` are installed, because ghostty's `SharedDeps.init` needs their options (`-Dbuild_config_path`, `-Dtables_path`) and named lazy path `tables.zig` |
| `ghostty` | `ghostty-org/ghostty` @ `aeda37b3…` | only `include/`, `src/`, `pkg/android-ndk`, `pkg/apple-sdk`, `pkg/translate-c`, `pkg/wuffs`, `pkg/highway`, `pkg/simdutf`, `LICENSE` are kept; `src/font/res` is dropped; its `build.zig`/`.zon` are fetched from OpenTUI's vendor directory and patched |

The build also patches `ghostty/build.zig.zon` to add a `zlib` dependency when it is missing,
and applies `ghostty-android-metallib.patch` so the non-Apple build does not create a Metal
shader library. The dependency is pinned to the GitHub release asset
`github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz` with hash
`N-V-__8AAJj_QgDBhU17TCtcvdjOZZPDfkvxrEAyZkc14VN8`, verified with `zig fetch`. Those are the
same bytes as the zlib.net fossil tarball, which served the runner an HTML page in run
#41280877999.

The Bionic sysroot shim exists because `translate-c` needs real headers for `miniaudio` and
`yoga`, but those headers use Apple nullability annotations and relative includes that do not
resolve inside the NDK tree:

```
build/bionic-include/
  <NDK usr/include> + <NDK usr/include/aarch64-linux-android>   # merged
  miniaudio.h, yoga/yoga/…
  __opentui/miniaudio_shimmed.h   # #define _Nullable/_Nonnull, then #include "../miniaudio.h"
  __opentui/Yoga_shimmed.h        # same for Yoga.h
```

`build/bionic-libc.txt` then tells Zig where headers and `crt` objects are. `NEEDED libc.so`
comes from `module.link_libc = true` in OpenTUI's `packages/native/build.zig`; an older
`android-libc-link.patch` targeted a file that no longer exists and was retired
([§11.4a](#114-opentui-patches)). The script still fails hard if the `NEEDED` entry is missing
rather than shipping a `.so` that will fail at `dlopen`.

### 20.8 Module-graph contract

The graph is owned by one module, and the contract is enforced structurally rather than by
version sniffing. `parse()` tries `Offsets` sizes 32 and 24, and strides 52 and 36, then
accepts a candidate only if all of the following hold:

- the trailer was found and the candidate offsets start after the graph;
- `byte_count > 0`, `graph_start = offsets_start - byte_count ≥ 0`;
- the module list fits inside the payload, with at most 16 bytes of gap;
- `modules_length % stride == 0`, module count sane, `entry_point_id` in range;
- every StringPointer's `offset + length` lies inside the string-data region;
- for 32-byte `Offsets`, the argv pointer/length also fits.

The StringPointer bound check is the discriminator: a 52-byte parse of a 36-byte module list
still yields plausible counts, but its "pointers" point into the module list rather than the
string table, and the check rejects it. This is why the tool can auto-detect instead of
trusting a hardcoded constant — and why the old `OFFSETS_SIZE = 32` extractor failed.

Exit codes are part of the contract so shell callers can branch:
`0` success, `2` invalid/unparseable, `3` unsupported layout (v2 onto a v1 runtime).

### 20.9 Directory state machine

| Path | Produced by | Consumed by | Safe to delete? |
|---|---|---|---|
| `build/icu-src` | `build-icu.sh` (download) | ICU builds | Yes; re-downloaded |
| `build/deps-android/prefix` | ICU cross build | WebKit, Bun | Yes, but forces both rebuilds |
| `build/webkit-src` | `apply-patches.sh` | `build-webkit.sh` | Yes; re-cloned |
| `build/webkit-build` | `build-webkit.sh` | header copies | Yes; forces WebKit rebuild |
| `build/webkit-android` | `build-webkit.sh` (+ TinyCC, OpenTUI copies) | Bun CMake, packaging | **No** unless rebuilding WebKit/Bun |
| `build/bun-src` | `apply-patches.sh` (+ Zig vendor download) | `build-bun.sh` | Yes; re-clone + re-patch |
| `build/bun-build` | `build-bun.sh` | transplant, launcher staging | Yes; forces Bun rebuild |
| `build/opentui-src` | `build-opentui.sh` | OpenCode bundle swap + `lib/` | Yes; re-vendored |
| `build/opencode-src` | `build-opencode.sh` | bundle | Yes; re-clone + install |
| `build/dist` | `build-opencode.sh` | `make-packages.sh` | Yes; rebuilt in ~30 s |
| `build/packages` | `make-packages.sh` | CI upload | Yes |

The workflow's cleanup step follows this table exactly: it deletes sources and `webkit-build`
but keeps `deps-android/prefix`, `webkit-android`, and `bun-build/bun`, which are the cache
targets. It also deletes `bun-build/cache/zig` because the cache references files under the
now-deleted `bun-src/vendor/zig`, which produces `FileNotFound` on the next run.

### 20.10 Caches and invalidation

| Cache | Path | Key | Invalidated by |
|---|---|---|---|
| ICU | `build/deps-android/prefix` | `icu-android-<version>-<api>` | ICU version, API level |
| WebKit | `build/webkit-android` | `webkit-android-<commit>-<webkit patch hash>` | WebKit commit, patch content |
| Bun | `build/bun-build/bun` | `bun-android-<version>-<bun patch hash>-<zig patch hash>` | Bun version, either patch |
| OpenTUI | `…/aarch64-linux-android/libopentui.so` | `opentui-android-<version>-<patch hash>-<zig version>` | OpenTUI version, patch, Zig |
| node_modules | `build/opencode-src/node_modules` | `opencode-deps-<version>-<package.json hash>-<bun version>` | OpenCode version, manifest, Bun |

Two consequences worth knowing: a patch edit invalidates the expensive stage even if the
version did not change (by design), and a Bun version bump invalidates the Bun cache *and*
the OpenCode dependency cache, but not WebKit unless the commit changed.

### 20.11 Resource budget

| Resource | Requirement | Notes |
|---|---|---|
| RAM | ≥16 GB recommended; 8 GB is not enough | WebKit link is the peak; `JOBS=4` on 16 GB |
| Disk | ≥60 GB cold | WebKit build tree dominates; sources are ~3.8 GB together |
| Time | 2–3 h cold, ~4 min warm | 360-minute job timeout covers a cold run with retries |
| Network | GitHub (incl. release assets), unicode.org, ziglang.org, models.dev, npm registry | Models fetch has 3×15 s timeouts and a local-file override; avoid zlib.net, which has answered runners with HTML |

### 20.12 Failure surfaces by layer

| Layer | Typical signature | First thing to check |
|---|---|---|
| Toolchain / CMake | `try_compile` host results, missing `aarch64-linux-android24-clang` | `ANDROID_NDK_HOME`, `ANDROID_TRIPLE_API`, `CMAKE_TRY_COMPILE_PLATFORM_VARIABLES` |
| WebKit | missing `wtf/…` header during Bun build | `WEBKIT_OUTPUT` layout, `BUN_WEBKIT_VERSION` |
| Zig in Bun | `FileNotFound` in `translate-c` cache | cache symlink, patch timing (see §8.3–8.4) |
| Zig in OpenTUI | missing `miniaudio.h`/`Yoga.h`, `NEEDED libc.so` absent | bionic shim tree, `ANDROID_NDK_LIB_DIR` |
| Bundling | `Could not resolve @opentui/core-linux-*` | four native variants installed |
| Format | negative size, stride mismatch, v2 refusal | `transplant-bun-graph.py inspect` |
| Packaging | launcher 127, `PREFIX` unset | zip unpacked over `$PREFIX` |

---

## 21. Expanded build runbook

This is the executable form of the document. Commands are copy-paste ready for a fresh
Ubuntu runner; the CI workflow performs the same steps with caching around them. Local
Termux cannot run the compile stages (no NDK/root/RAM) — use CI — but it can run the static
checks and the packaging smoke test.

### 21.1 Preflight

```sh
cd opencode-termux
source scripts/env.sh
export WORK_DIR=./build            # keep it relative; see §20.2 path caveat

# Required tools
for t in git cmake ninja clang python3 curl unzip zip xz ar readelf file; do
    command -v "$t" >/dev/null || echo "MISSING: $t"
done
cmake --version | head -1          # Bun needs >= 3.24; 3.28 is what CI installs
bun --version                      # must be 1.2.13 (host == target)
"${ZIG_BIN:-zig}" version           # must be 0.16.0
ls "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang"
df -h .                            # >= 60 GB free for a cold build
nproc; free -g                     # 4 jobs / 16 GB is the reference point
```

Do not continue if any of these fail. Diagnosing a half-configured build costs more than the
five minutes this takes.

### 21.2 Bootstrap (fresh Ubuntu runner)

```sh
sudo apt-get update
sudo apt-get install -y ninja-build python3 ruby perl git curl wget unzip xz-utils zip \
    build-essential pkg-config libxml2-dev libxslt1-dev golang-go autoconf automake \
    libtool patchelf file binutils

# CMake >= 3.24 (Ubuntu 22.04 ships 3.22)
CMAKE_VER=3.28.6
wget -q "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VER}/cmake-${CMAKE_VER}-linux-x86_64.tar.gz" -O /tmp/cmake.tar.gz
sudo tar xzf /tmp/cmake.tar.gz -C /opt/
sudo ln -sf "/opt/cmake-${CMAKE_VER}-linux-x86_64/bin/cmake" /usr/local/bin/cmake

# NDK r28b
wget -q https://dl.google.com/android/repository/android-ndk-r28b-linux.zip -O /tmp/ndk.zip
sudo unzip -q /tmp/ndk.zip -d /opt/
sudo mv /opt/android-ndk-r28b /opt/android-ndk
export ANDROID_NDK_HOME=/opt/android-ndk

# Rust target for lol-html
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
rustup target add aarch64-linux-android

# Zig 0.16.0
mkdir -p build/zig-0.16.0
wget -q https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz -O /tmp/zig.tar.xz
tar xf /tmp/zig.tar.xz -C build/zig-0.16.0 --strip-components=1
export ZIG_BIN="$PWD/build/zig-0.16.0/zig"

# Host Bun 1.2.13 (must match the target)
curl -fsSL https://bun.sh/install | bash -s "bun-v1.2.13"
export PATH="$HOME/.bun/bin:$PATH"
bun add -g @types/bun@1.2.13
for p in linux-arm64 linux-x64 linux-arm64-musl linux-x64-musl; do
    bun add -g "@opentui/core-${p}@0.5.10" --no-cache || true
done
```

The global `@types/bun` and the four native variants are not optional cleanliness: without
them, `bun install` tries to `git clone` a catalog version (fails in CI) and the bundler
cannot resolve optional native packages.

### 21.3 Stage 1 — patches

```sh
./scripts/apply-patches.sh
```

Creates `build/bun-src` at `bun-v1.2.13` with the 33-file patch applied, and
`build/webkit-src` at the pinned commit with its 5-file patch.

Verify:

```sh
git -C build/bun-src status --short        # patched files listed, nothing untracked except new files
test -f build/bun-src/cmake/toolchains/android-aarch64.cmake
test -f build/bun-src/src/android_tls_align.s
git -C build/webkit-src diff --stat        # 5 files changed
```

**Idempotence warning.** The script runs `git checkout -- .` before `git apply`. Files that
the patch *creates* are untracked and therefore survive the checkout, so a second run fails
with `already exists`. To re-apply cleanly, delete and re-clone:

```sh
rm -rf build/bun-src build/webkit-src && ./scripts/apply-patches.sh
```

### 21.4 Stage 2 — ICU

```sh
./scripts/build-icu.sh
```

Host tools build first (`build/icu-host-build`), then the Android static build into
`build/deps-android/prefix`.

Verify:

```sh
ls build/deps-android/prefix/lib/libicu{uc,i18n,data}.a
ls build/deps-android/prefix/include/unicode/utypes.h
```

Failure signatures: `configure: error: cross build not supported` means the host tools were
not built or `--with-cross-build` points elsewhere; missing `libicuuc.a` means the cross build
was skipped and the cache/step should be re-run with the directory removed.

### 21.5 Stage 3 — WebKit/JSC

```sh
./scripts/build-webkit.sh
```

This is the long stage (60–90 min). The script rewrites the checked-in toolchain file with the
detected NDK and ICU paths, configures JSCOnly, builds `jsc`, copies private headers, and
assembles the `WEBKIT_LOCAL` layout.

Verify:

```sh
ls build/webkit-android/lib/*.a
test -f build/webkit-android/cmakeconfig.h
grep BUN_WEBKIT_VERSION build/webkit-android/cmakeconfig.h
ls build/webkit-android/include/JavaScriptCore/JavaScriptCore.h
```

If `cmakeconfig.h` lacks `BUN_WEBKIT_VERSION`, the append step failed; Bun's configure will
either reject the directory or record an empty version. Re-run the tail of the script rather
than the whole build when possible.

### 21.6 Stage 4 — TinyCC

```sh
./scripts/build-tinycc.sh
```

Compiles TinyCC's translation units with the NDK and archives them.

Verify:

```sh
ls build/webkit-android/lib/libtcc.a
"$ANDROID_AR" t build/webkit-android/lib/libtcc.a | head
```

### 21.7 Stage 5 — Bun

```sh
./scripts/build-bun.sh
```

Configure → `clone-zig` → patch Zig stdlib → clear/alias caches → `ninja`. Expect 30–45 min.
On the first failure, read the tail: if it is a Zig `FileNotFound` and the patch is newly
applied, the script retries automatically after clearing caches.

Verify:

```sh
file build/bun-build/bun | grep aarch64
readelf -h build/bun-build/bun | grep -E 'Machine|Class'
readelf -lW build/bun-build/bun | grep -E 'GNU_RELRO|GNU_STACK'
```

The binary must have **no** module graph yet; `transplant-bun-graph.py inspect` on it should
fail with "trailer not found" or "could not parse", which is expected at this point.

### 21.8 Stage 6 — libopentui.so

```sh
./scripts/build-opentui.sh
```

Clones OpenTUI, applies the two OpenTUI patches, vendors Zig dependencies, builds the Bionic sysroot
shim, runs `zig build`, and copies the result to three locations.

Verify:

```sh
file build/webkit-android/lib/libopentui.so | grep aarch64
readelf -d build/webkit-android/lib/libopentui.so | grep 'NEEDED.*libc\.so'
```

Both checks are enforced by the script; a pass here means `dlopen` has a chance of working.

### 21.9 Stage 7 — OpenCode bundle and transplant

```sh
bun --version                 # 1.2.13
./scripts/build-opencode.sh
```

Clones OpenCode, rewrites `catalog:`, installs deps, swaps in the aarch64 `libopentui.so`,
bundles with host Bun, restores the x64 library, transplants the graph, stages the `$PREFIX`
tree, writes the launcher, and runs the verifier.

Verify:

```sh
find build/dist -maxdepth 3 -type f | sort
file build/dist/libexec/opencode/opencode.bin | grep aarch64
python3 scripts/transplant-bun-graph.py verify \
    build/dist/libexec/opencode/opencode.bin --expect-stride 36
head -1 build/dist/bin/opencode      # Termux shebang
```

Expected `dist` contents: `bin/opencode`, `libexec/opencode/opencode.bin`, `lib/libopentui.so`,
`lib/libc++_shared.so` when the NDK provides it, `lib/libtagfix.so` only when supplied.

### 21.10 Stage 8 — packages

```sh
./scripts/make-packages.sh
```

Verify:

```sh
unzip -l build/packages/*.zip | grep -E 'bin/opencode$|opencode\.bin$|libopentui\.so$'
tar -tf build/packages/*.pkg.tar.xz | grep -E 'bin/opencode$|opencode\.bin$|libopentui\.so$|\.PKGINFO'
dpkg-deb -c build/packages/*.deb | grep -E 'bin/opencode$|opencode\.bin$|libopentui\.so$'
(cd build/packages && sha256sum -c SHA256SUMS)
```

### 21.11 Resume matrix

Deleting one artifact to force a rebuild is the normal debugging loop. Delete the **smallest**
thing that invalidates the failing stage:

| Symptom | Delete | Rebuild cost |
|---|---|---|
| Patch does not apply / source tree dirty | `build/bun-src`, `build/webkit-src` | clone + patch |
| ICU missing/wrong | `build/deps-android/prefix`, `build/icu-*-build` | ~5 min + WebKit + Bun |
| WebKit headers missing after a Bun rebuild | `build/webkit-android` | 60–90 min + Bun |
| Bun link fails on ICU/WebKit symbols | `build/bun-build` | 30–45 min |
| `libopentui.so` wrong arch / missing NEEDED | `build/opentui-src` | ~2 min |
| OpenCode bundle error / stale npm deps | `build/opencode-src`, `build/dist` | install + bundle |
| Only packaging changed | `build/packages` | ~10 s |
| Stride/layout error | nothing; fix pins and re-run transplant | seconds |

Do not delete `build/webkit-android` to "clean up" unless you intend to spend 90 minutes.

### 21.12 Fast iteration loops

| You changed | Minimum loop |
|---|---|
| A patch hunk in `patches/bun/…` | delete `build/bun-src`, `build/bun-build`, `build/dist`; run stages 1, 5, 7, 8 |
| A WebKit header/flag | delete `build/webkit-src`, `build/webkit-build`, `build/webkit-android`, `build/bun-build`; stages 1, 3, 5, 7 |
| `transplant-bun-graph.py` | run the §15.1 round-trip against a downloaded Bun; no Android build needed |
| `make-packages.sh` | fake `dist` with `/bin/true`; run stage 8 |
| `env.sh` version pins | treat as a coordinated upgrade; see [§14](#14-upgrade-status-bun-1314) |
| README/docs | nothing; static checks only |

### 21.13 CI dispatch, monitoring, artifacts

```sh
gh workflow run build.yml -f opencode_version=1.19.4 -f force_rebuild=false
gh run list --workflow=build.yml --limit 5
gh run watch <run-id>
gh run view <run-id> --log-failed
gh run download <run-id> -D artifacts
```

What to inspect, in order: the failing **step** name (it maps to a stage), then the last ~200
lines of that step, then the artifact listing. `continue-on-error` is enabled for pull
requests, so a red PR check does not always mean the job failed the build — check the
artifacts and the `validate-artifacts` job.

### 21.14 Device install and smoke test

```sh
# Standalone zip (unpacks over the prefix)
unzip -o opencode-1.19.4-android-aarch64.zip -d "$PREFIX"
pkg install ripgrep
opencode --version
opencode            # TUI should render; Ctrl+C exits

# Pacman
pacman -U opencode-1.19.4-1-aarch64.pkg.tar.xz

# Deb
dpkg -i opencode_1.19.4_aarch64.deb
```

On-device checks that catch packaging mistakes fast:

```sh
readlink -f "$(command -v opencode)"        # -> $PREFIX/bin/opencode
ls -l "$PREFIX/libexec/opencode/opencode.bin" "$PREFIX/lib/libopentui.so"
file "$PREFIX/libexec/opencode/opencode.bin"   # aarch64
python3 - <<'PY'                                # if python is installed
import sys
data = open("/data/data/com.termux/files/usr/libexec/opencode/opencode.bin","rb").read()
print("trailer at", data.rfind(b"\n---- Bun! ----\n"), "size", len(data))
PY
```

If the launcher exits 127, the binary is not where the launcher looks: re-check that the zip
was unpacked **over `$PREFIX`**, not into a scratch directory.

### 21.15 Triage decision tree

1. **Did it fail before any compilation?** → versions, NDK paths, CMake version, network.
2. **Did it fail in configure?** → toolchain file, `try_compile`, missing sysroot headers.
3. **Did it fail compiling C/C++?** → flag mismatch (PIC/PIE/RELRO), missing ICU/WebKit headers.
4. **Did it fail in Zig?** → patch timing or cache aliasing; check both cache paths resolve to
   the same directory.
5. **Did it fail linking?** → missing `libtcc.a`/WebKit libs, `-lpthread` still present, TLS
   object garbage-collected.
6. **Did the bundle fail?** → `catalog:` rewrite, `@types/bun`, native package resolution.
7. **Did the transplant fail?** → host/target Bun mismatch, stride, layout v2, trailer.
8. **Did packaging fail?** → `dist` incomplete, `$PREFIX` unset, `ar` missing.
9. **Did it build but crash immediately on device?** → TLS alignment, `NEEDED libc.so`,
   seccomp `SIGSYS`, missing `OPENTUI_LIB_PATH`.

---

## 22. Agent operating manual

Instructions for an AI agent (or a new contributor) asked to change, fix or rebuild this
project. They encode the rules that keep a 2–3 hour build from being wasted.

### 22.1 Scope and non-negotiables

- You may edit `scripts/`, `patches/`, `cmake/`, `.github/workflows/build.yml`, `docs/`, and
  `README.md`.
- You may **not** fake a build result. There is no local NDK, no Android device and a
  five-minute command cap in this workspace; a claim that the pipeline "works" must come from
  CI logs or a previously recorded measurement.
- Never weaken a verifier, skip a stage, or bump a version to make an error disappear.
- Never commit `build/`, downloaded tarballs, or generated `node_modules`.

### 22.2 Read before you touch anything

In this order:

1. `AGENTS.md` — repository rules (remote-runner requirement, failure modes).
2. `scripts/env.sh` — the pins. These are the truth.
3. `.github/workflows/build.yml` — the actual execution order and cache keys.
4. The script for the stage you are changing, end to end.
5. `scripts/transplant-bun-graph.py` — if the change touches the format, read all of it.
6. This document, [§11](#11-patch-reference-diffs--reasoning) for the patch you are editing.

Do not infer a pin from prose. A README that says 1.3.14 while `env.sh` says 1.2.13 is a
documentation bug, not permission to change the build.

### 22.3 Authority order

`env.sh` / workflow `env:` → stage scripts and the Python tool → this document → README and
design notes. If you change a pin, update all four in the same change, plus the cache keys
that hash the affected patches.

### 22.4 Research gate

The repository asks for Context7-based research before build changes. Context7 is not
available in this environment; use web search and GitHub instead, and record what you
consulted in the commit message or PR description. Never guess:

- dependency tarball hashes (`build.zig.zon` fails closed on a wrong hash);
- NDK release paths or API-level symbol availability;
- Bun's `Offsets`/module struct layout (measure it with `transplant-bun-graph.py inspect`);
- Zig API names for a version (`addLibrary` vs `addStaticLibrary`, `root_module`).

### 22.5 Execution constraints

- Builds belong on GitHub Actions (`ubuntu-latest`, 360-minute timeout). Do not attempt a
  WebKit or Bun build in the chat workspace.
- Shell commands here are capped at five minutes; long jobs must be CI runs or explicit
  background processes with logs.
- No interactive commands (`convex dev`, `bun login`, editors, `git rebase -i`).
- Do not run `git push`, force-push, or tag unless the user asked for it.

### 22.6 Change protocol

1. **Patch-first.** If upstream source must change, change the `.patch` file (and regenerate it
   from a real tree with `git diff`), never a checked-out `build/*-src` tree alone.
2. **Keep scripts idempotent.** Guard expensive steps with existence checks the way
   `build-icu.sh` does; make re-runs cheap.
3. **Assert contracts.** When adding a stage or artifact, verify architecture, `NEEDED`
   entries, and layout in the script, not only in CI YAML.
4. **One owner per format.** Module-graph logic belongs in `transplant-bun-graph.py`; do not
   reintroduce offset math in TypeScript or bash.
5. **Quote for `set -u`.** Any literal `$PREFIX` in an echoed string must be `\$PREFIX` or
   single-quoted; unbound-variable failures have already broken packaging once.
6. **Absolute/relative paths.** Reuse `abspath()`; never assume the caller's CWD.

### 22.7 CI triage loop

1. Identify the failing step; map it to a stage with [§21.15](#2115-triage-decision-tree).
2. Pull the last 200 lines of that step (`gh run view --log-failed`).
3. Classify: toolchain, WebKit, Zig, bundle, format, packaging.
4. Make the **smallest** change that addresses the cause. Do not bundle unrelated fixes.
5. Re-run only what is needed; use the cache keys to predict what will rebuild.
6. Record the evidence (run id, failing step, signature, fix) in the PR/commit.

Stop and ask after two failed attempts at the same signature: repeated failures usually mean
an upstream change or a missing credential, not a typo.

### 22.8 Log signature → action

| Signature | Layer | Action |
|---|---|---|
| `CMake 3.2x is too old` | bootstrap | install CMake ≥ 3.24 |
| `try_compile` succeeds for host / wrong arch | toolchain | check `CMAKE_TRY_COMPILE_PLATFORM_VARIABLES` and `ANDROID_NDK_HOME` |
| `fatal error: 'wtf/…' file not found` | WebKit/Bun boundary | `WEBKIT_OUTPUT` layout, `BUN_WEBKIT_VERSION`, rebuild WebKit if headers missing |
| `file_hash FileNotFound` | Zig cache | clear both caches, re-symlink, rerun |
| `undefined reference to pthread_…` | link flags | remove `-lpthread` (Bionic merges it), rebuild Bun |
| `cannot execute binary file` during build | post-link step | `if(NOT ANDROID)` guard around the step |
| `Could not resolve "@opentui/core-linux-…"` | bundle | install all four native variants |
| `Derived host bun size is negative` | old extractor | use `transplant-bun-graph.py` |
| `layout v2 … cannot be transplanted` | format | host/target Bun mismatch; do not force |
| `libopentui.so is missing NEEDED: libc.so` | OpenTUI | check `ANDROID_NDK_LIB_DIR`, re-apply libc-link patch |
| `Bad system call` on device | seccomp | v1: `close_range` fallback present? v2: SIGSYS patch |
| launcher exits 127 | packaging | zip unpacked over `$PREFIX` |

### 22.9 Stop conditions

Escalate instead of improvising when:

- a version bump is requested but the build system changed upstream (e.g. Bun 1.3.14);
- a required credential or secret is missing (never invent one, never write one to a file);
- CI fails with the same signature twice after targeted fixes;
- the fix would require weakening an invariant in [§19.4](#194-invariants);
- upstream deleted or moved a patched file.

### 22.10 Definition of done

A change is complete only when:

- [ ] the affected script passes `bash -n` (or `py_compile` for Python);
- [ ] `python3 scripts/lint-patch-application.py` passes, including patch coverage and markers;
- [ ] the workflow YAML still parses;
- [ ] every path the change touches exists in the repo (no dangling references);
- [ ] version claims in README/docs match `env.sh`;
- [ ] the verifier passes on a real artifact, or CI has produced one;
- [ ] the final report states what was **not** verified and why.

### 22.11 Reporting template

```
Changed: <files, one line each>
Why: <the failure or requirement>
Evidence: <run id / command output / measurement>
Checks run: <exact commands and results>
Not verified: <what needs CI or a device>
Risks: <what could regress>
```

### 22.12 Anti-patterns

- Editing `build/*-src` and calling it fixed (the next clone loses it).
- Adding `|| true` to a verifier or `continue-on-error` to hide a failure.
- Bumping `BUN_VERSION` without `MODULE_GRAPH_STRIDE` and a format round-trip.
- Changing a patch without updating its cache key inputs (the patch hash is computed
  automatically, but a manual cache key in a fork may not be).
- Replacing `$PREFIX` layout with a flat zip "for simplicity".
- Committing generated files or secrets.

---

## 23. Maintenance and release checklist

### 23.1 Version bump matrix

Changing a pin is never a one-line edit. The minimum coordinated set:

| Change | Must also change | Rebuild | Verify |
|---|---|---|---|
| **OpenCode** version | `OPENCODE_VERSION` in `env.sh`, workflow `env:` + dispatch default, README table, node_modules cache key | bundle, package | version output, migrations define, TUI launch |
| **Bun** version | `BUN_VERSION`, **`MODULE_GRAPH_STRIDE`**, host Bun in CI, Bun and node_modules cache keys, README table | Bun, bundle | transplant `verify`, `inspect` layout, round-trip |
| **WebKit** commit | `WEBKIT_COMMIT`, WebKit cache key, patch rebase | WebKit, Bun | header layout, `BUN_WEBKIT_VERSION` |
| **ICU** version | `ICU_VERSION`, ICU cache key | ICU, WebKit, Bun | link succeeds, no duplicate symbols |
| **OpenTUI** version | `OPENTUI_VERSION`, patch rebase, cache key, Zig version compatibility | OpenTUI, bundle | aarch64 + `NEEDED libc.so` |
| **NDK / API** | `ANDROID_NDK_VERSION`, `ANDROID_API`, toolchain paths in env and CMake, workflow download | everything | configure, link, device run |
| **Patch content** | nothing manual (hashes are computed) unless a cache key was hardcoded elsewhere | affected stage | `git apply --check` on a clean tree |

Two rules follow from the table: a Bun bump without a stride bump fails the verifier, and a
stride bump without a Bun bump produces a binary that corrupts at startup. Treat them as one
unit.

### 23.2 Release checklist

1. CI green on the release commit; `validate-artifacts` passed.
2. Download the three packages and `SHA256SUMS`; verify checksums locally.
3. Install each format on a device (or at minimum the zip over `$PREFIX`) and run
   `opencode --version` and a TUI launch.
4. Confirm the package metadata: `pkgname`/`Package`, version, `arch = aarch64`,
   `depend = ripgrep`.
5. Tag `v*` (this triggers the release job), or create the release manually with the three
   artifacts.
6. After publishing, re-check the download URLs in `README.md` and the documented layout.
7. Update the "Status" block at the top of this document if the engine, Bun pin or stride
   changed.

Remember there are two version numbers: the OpenCode application version (`1.19.4`) and this
repository's release/package tag. Release notes should state both, as the README does for v2.

### 23.3 Documentation upkeep

| If you change… | Update |
|---|---|
| a pin in `env.sh` | [§1](#1-target-matrix), [§4](#4-environment-variables), README versions, workflow `env:` |
| the patch set | [§11](#11-patch-reference-diffs--reasoning) and the file counts in [§18.2](#182-repository-map) |
| the graph format or tool | [§10.2](#102-standalone-binary-format-measured-not-assumed), [§20.8](#208-module-graph-contract), tool docstring |
| staging or packaging | [§2](#2-artifact-layout), [§12](#12-packaging), [§21.10](#2110-stage-8--packages) |
| CI steps or caches | [§13](#13-ci-pipeline), [§20.10](#2010-caches-and-invalidation) |
| agent rules | [§22](#22-agent-operating-manual) |

Internal anchors are part of the contract for readers. After editing headings, re-run the
check in [§15.4](#154-static-checks-that-run-without-an-ndk) plus a link check; a renamed
heading silently breaks every `§` reference.

### 23.4 Handoff block

Paste this into a fresh agent session before asking for build work:

```
Repo: opencode-termux. Target: OpenCode 1.19.4, Android aarch64, Termux.
Constraints: builds only on GitHub Actions ubuntu-latest; no local NDK; 5-minute command cap;
do not commit build/ or secrets; do not bump versions to silence errors.
Truth: scripts/env.sh and .github/workflows/build.yml (Bun 1.2.13, stride 36, API 24).
Read first: AGENTS.md, scripts/env.sh, build.yml, the stage script you will touch,
docs/BUILD-OPENCODE-1.19.4-ANDROID.md §19–§22.
Format: scripts/transplant-bun-graph.py owns the standalone graph; never re-derive offsets.
Evidence required: CI run id or measured command output; state what was not verified.
```

### 23.5 Document map

| Question | Section |
|---|---|
| What versions, and why are they coupled? | [§1](#1-target-matrix), [§19.3](#193-decision-record) |
| What does the installed tree look like? | [§2](#2-artifact-layout) |
| In what order do stages run? | [§3](#3-dependency-topology-and-build-order), [§21](#21-expanded-build-runbook) |
| Why is the build shaped this way? | [§19](#19-implementation-strategy) |
| How does each build system hand off? | [§20](#20-build-system-deep-dive) |
| What exactly was patched, and why? | [§11](#11-patch-reference-diffs--reasoning) |
| How does the standalone format work? | [§10.2](#102-standalone-binary-format-measured-not-assumed), [§20.8](#208-module-graph-contract) |
| How do I run or resume it? | [§21](#21-expanded-build-runbook) |
| How should an agent behave? | [§22](#22-agent-operating-manual) |
| What breaks, and what do I do? | [§16](#16-troubleshooting), [§21.15](#2115-triage-decision-tree) |
| How do I upgrade Bun? | [§14](#14-upgrade-status-bun-1314), [§23.1](#231-version-bump-matrix) |

---

## 24. CI history, failure taxonomy, and the current OpenTUI blocker

This section is evidence-based: it was added after reading the repository's public GitHub
Actions history and commit log, not from design intent.

### 24.1 What was available, and what was not

| Source | Access | Result |
|---|---|---|
| Actions run/job/step metadata | Public REST API, no credentials | 87 runs with per-step conclusions and timings |
| Log archives (`/actions/runs/{id}/logs`) | Requires authentication | **403**; no log text available in this environment |
| Failed-run artifacts | API | none uploaded (artifact upload is skipped on failure) |
| Commit history | Local clone (103 commits) + API | Full messages, including the fix attempts |
| Local reproduction | Zig **0.16.0**, real compiler | Validated the generated build script outside CI |

So the conclusions below come from step timings, conclusions, commit messages and a local
compiler test — not from log lines. Anything that would need log text is marked as inference.

### 24.2 Run history at a glance

| Runs | Period | Outcome |
|---|---|---|
| #1–#2 | 2026-10-26 | cancelled (setup) |
| #3–#12 | 2026-10-26/27 | failures during early pipeline bring-up |
| #13–#57 | 2026-10-27/30 | **mostly success**, with path/format fixes in between |
| #58–#76 | 2026-10-31 | mixed; OpenTUI and Zig work dominates |
| #77–#86 | 2026-10-31 → 11-01 | **all fail** at `Build libopentui.so` |
| #87–#92 | 2026-11-01 | OpenTUI fixes; first green OpenTUI at #41281683381 |
| #93 | 2026-11-01 06:44 | ICU, WebKit, TinyCC and Bun all green; OpenCode install fails (#41282039365) |

The important signal is not the count but the shape: a twelve-second OpenTUI failure streak
was finally broken in #41281683381, after which the pipeline advanced through every native
stage in a single run.

### 24.3 Where the time goes (run #86)

| Step | Start → end | Duration | Conclusion |
|---|---|---|---|
| Clone and patch Bun + WebKit | 04:43:43 → 04:45:10 | 1m27s | success |
| Build ICU | 04:45:10 → 04:47:25 | 2m15s | success |
| Build WebKit/JSC | 04:47:25 → 04:57:07 | 9m42s | success (cache restored) |
| Build TinyCC | 04:57:07 → 04:57:10 | 3s | success |
| Build Bun | 04:57:10 → 05:15:57 | 18m47s | success |
| **Build libopentui.so** | 05:15:57 → 05:16:09 | **12s** | **failure** |
| Cleanup | 05:16:09 → 05:17:17 | 68s | success |

A 12-second failure after an 18-minute successful Bun build is a deterministic script/API
error, not a compiler timeout or a flaky network fetch. Everything after the failing step is
skipped, and no artifact is produced.

### 24.4 Commit archaeology: what was actually fixed

| Theme | Commits (abbrev.) | What it tells us |
|---|---|---|
| Absolute path handling | `2cdba00`, `e276fa4`, `4691b09`, `d063c45`, `1226750`, `1591648`, `5de4bc1`, `b0a299d`, `584c88d`, `1c4f7d6`, `2561165` | Every stage eventually needed `REPO_ROOT`-anchored absolute paths; relative `WORK_DIR` assumptions caused a long tail of failures |
| `catalog:` / `@types/bun` install | `2ea7bf5`, `41ea6c7`, `7ab0d44`, `a272321`, `965ea79`, `a52ac30`, `26806b8`, `94ed046`, `824f2fa` | Bun 1.2.13 cannot resolve `catalog:`; the fix was rewriting manifests, not upgrading Bun |
| Host Bun detour | `66d5a40`, `76c6903` (1.4.4), `cfc9e6d` (back to 1.2.13) | Host Bun was changed to fix installs, then reverted when the real problem was catalog resolution |
| Zig version roulette | `773a04b` (0.17.0), `6558d38`, `dc2461f`, `860f565` (revert 0.16.0) | Upgrading Zig to fix a cross-compile crash moved the failure rather than fixing it |
| ghostty `zlib` hash encoding | `6306bfe`, `494c3ff`, `9594af1`, `fd04833`, `274f865`, `48bd71e`, `1a7f11b`, `453f47a`, `fcad69b`, `0248c83`, `a6a8fa0`, `6421751` | Twelve commits hand-encoding SHA-256 as raw hex, base32, base64, base64url, then `N-V-__…`; the working answer came from `zig fetch`, not from guessing the format |
| ghostty metallib on Android | `390dd73`, `5d4f06a`, `eaf219b` | Non-Apple targets must skip the Metal shader library entirely |
| Generated `uucode-ghostty/build.zig` | `eaf219b` … `2f88f27`, `d672cec`, `1796732`, `0332673` | Repeated API edits (`root_source_file`, `addLibrary`, `root_module`, `b.path`) without ever compiling the generated file locally |

Pattern: most "fix" commits changed one API name, pushed, and waited ~40 minutes for CI to
fail again at the same step. The failure signatures were never captured in the repository.

### 24.5 The OpenTUI dependency-graph blocker

Run #41280310141 cleared the ghostty patch stage and failed while Zig evaluated OpenTUI's
`build.zig`, before compiling anything:

```text
error: invalid option: -Dbuild_config_path
...
thread panic: unable to find named lazypath 'tables.zig'
```

The cause was the hand-written `uucode-ghostty/build.zig` in `build-opentui.sh`. It declared
only the standard options and exposed a dynamic library plus
`b.installFile("src/tables.zig", …)`, but ghostty's `src/build/SharedDeps.zig` asks the
dependency for a different interface:

```zig
const tables = b.dependency("uucode", .{
    .build_config_path = b.path("src/build/uucode_config.zig"),
}).namedLazyPath("tables.zig");

const uucode_mod = b.dependency("uucode", .{
    .tables_path = tables,
    .build_config_path = b.path("src/build/uucode_config.zig"),
}).module("uucode");
```

So the package must declare `-Dbuild_config_path` and `-Dtables_path` (both
`std.Build.LazyPath`), export the named lazy path `tables.zig`, and register a module named
`uucode`. The pinned uucode commit already implements all of that in its own `build.zig`, and
its tarball ships the UCD inputs the table generator reads. The stub was also doomed because
it installed `src/tables.zig`, a file the package does not contain.

**Fix applied in this workspace** (`scripts/build-opentui.sh`): install the pinned upstream
`build.zig` and `build.zig.zon` from commit `9d555245…` instead of generating them, then
validate the interface before building:

- `zig build --help` in `uucode-ghostty` must succeed;
- its output must list `-Dbuild_config_path` and `-Dtables_path`;
- `build.zig` must still contain `addNamedLazyPath("tables.zig"`.

Run #41280659177 caught a second problem in the same area: the workflow's patch-integrity
step ran `mkdir -p …/uucode-ghostty`, a legacy workaround for the stub. The script's
`[ ! -d ]` guard therefore skipped the tarball extraction, and Zig found only the two build
files just downloaded:

```text
src/ucd_inputs.zig:1:1: error: unable to load 'ucd_inputs.zig': FileNotFound
```

The guard now tests for a file from the package (`src/ucd_inputs.zig`) instead of the
directory, and the workflow no longer pre-creates the tree, so an empty or partial checkout
is re-extracted instead of accepted.

A third defect followed in run #41280877999: Zig refused `ghostty/build.zig.zon` with
`unrecognized 'Content-Type' header: 'text/html'` for the zlib tarball, because zlib.net
answered the runner (not this development host) with an HTML page. The dependency now points
at the GitHub release asset for v1.3.1; `zig fetch` reports the same hash
(`N-V-__8AAJj_QgDBhU17TCtcvdjOZZPDfkvxrEAyZkc14VN8`) as the fossil tarball, so the pinned
bytes are unchanged.

A fourth defect followed in run #41281095820: `GhosttyZig.initVt` wires wuffs in whenever
Kitty graphics is enabled, which it is for a lib artifact on Android (only freestanding
targets force it off). OpenTUI's vendored `ghostty-build.zig.zon` omitted ghostty's own path
dependencies, so Zig panicked with `no dependency named 'wuffs'`. The build now copies
`pkg/wuffs` and `pkg/translate-c` from the pinned ghostty tarball and declares
`.wuffs = .{ .path = "./pkg/wuffs", .lazy = true }` and
`.translate_c = .{ .path = "./pkg/translate-c" }` in the vendored zon. Both shims fetch their
own C sources by URL and hash, so nothing else is vendored.

The same manifest gap covers SIMD: `SharedDeps.addSimd` unconditionally asks for `simdutf` and
`highway` when `Config.simd` is set, which it is for this build. Evaluating the patched tree
with Zig 0.16.0 therefore panicked next on `simdutf`, so `pkg/simdutf` and `pkg/highway` are
vendored and declared as lazy path dependencies too. The shims fetch their own sources by URL
and hash, and the local evaluation reaches ghostty's module graph with all four declared.

A fifth defect was in the Zig invocation itself: `build-opentui.sh` passed `-Dstrip=true`, but
OpenTUI 0.5.10 declares no `strip` option, so run #41281508898 failed before compiling
anything with `error: invalid option: -Dstrip`. The flag is gone; ReleaseSafe output is left
unstripped and stripped later during packaging.

With OpenTUI green, run #41281683381 advanced to `Clone and patch Bun`. The Bun patch applied
cleanly (33 files), but the marker assertion then failed because it used the relative
`$BUN_SRC/src/env.zig` *after* `cd "$BUN_SRC"`, so the path resolved inside the Bun tree. The
script now returns to `$REPO_ROOT` before the assertion.

Run #41282039365 then cleared every native stage — ICU, WebKit/JSC, TinyCC and Bun — and
stopped in `Build OpenCode standalone binary`. The manifest rewrite above removed
`@types/bun` from every `package.json`, but `bun install` still aborted with
`error: "git clone" for "@types/bun" failed`, and scrubbing those entries moved the failure
to `@types/node`. OpenCode's committed `bun.lock` stores `"@types/bun": "catalog:"` in about
thirty workspace entries, and Bun 1.2.13 treats the unknown `catalog:` protocol as a Git
spec. Deleting the lockfile makes Bun resolve the rewritten manifests (verified locally: 513
packages installed in 5.8 s with a warm install cache), so `build-opencode.sh` now removes
`bun.lock`/`bun.lockb` before installing.

Run #41319756768 then installed dependencies successfully and failed in the bundler with
`ModuleNotFound resolving .../packages/opencode/src/cli/cmd/tui/worker.ts`. OpenCode 1.19.4
moved the TUI worker to `packages/opencode/src/cli/tui/worker.ts`. The same run could not
resolve `@opentui/core-darwin-x64` and its siblings: `bun add` records platform-specific
optional packages but does not unpack ones whose `os`/`cpu` do not match the runner, and the
bundler resolves every literal dynamic import in `@opentui/core`'s platform loader. The build
script now writes minimal stubs for the seven non-host platform packages; the arm64 stub
exports `process.env.OPENTUI_LIB_PATH`, which the launcher points at the packaged
`libopentui.so`.

The JS side pins `@opentui/core` 0.4.5 while this pipeline builds OpenTUI 0.5.10. Comparing
the prebuilt arm64 libraries, every C symbol exported by 0.4.5 is present in 0.5.10; the 15
that are missing are C++ runtime internals (`_ZNSt3__1…`, `_ZNSt12…`). The native library is
kept, but the version skew remains a runtime risk to verify on a device.

Verified locally with Zig 0.16.0: a scratch package whose `build.zig` makes exactly the two
`b.dependency` calls above plus `.module("uucode")` evaluates and builds (exit 0) against the
pinned uucode tree. This is still not proof that the full OpenTUI build succeeds: the next
failure, if any, will be in ghostty's own boundary (`SharedDeps`/`GhosttyZig`) or in
OpenTUI's `build.zig`.

### 24.6 Failure taxonomy derived from the history

| Failure class | Example from this repo | Durable fix | Anti-fix that was tried |
|---|---|---|---|
| Environment/path assumption | relative `WORK_DIR`, `cd /tmp` breaking `ZIG_DIR` | one `abspath()` helper, absolute paths everywhere | re-running with different CWD |
| Package-manager protocol mismatch | `catalog:` on Bun 1.2.13 | rewrite manifests before install | upgrading host Bun to 1.4.4 |
| Package-manager lockfile protocol | `bun.lock` keeps `"@types/bun": "catalog:"` after the manifests are rewritten (run #41282039365) | delete the lockfile so Bun re-resolves the patched manifests | scrubbing individual entries (the failure moved to `@types/node`) |
| Hand-encoded dependency hash | ghostty `zlib` (12 attempts) | `zig fetch <url>` and paste its output | guessing hex/base32/base64 variants |
| Unstable dependency URL | zlib.net served `text/html` to the runner (run #41280877999) | pin the GitHub release asset, byte-identical per `zig fetch` | trusting HTTP 200 for a binary download |
| Incomplete vendored manifest | OpenTUI's `ghostty-build.zig.zon` omitted `wuffs`, then `simdutf`/`highway` (run #41281095820 and local evaluation) | copy the `pkg/*` shims and declare them as upstream ghostty does | adding only the first missing dependency |
| Phantom build option | `-Dstrip=true` on OpenTUI 0.5.10 (run #41281508898) | pass only options the build declares; check `zig build -h` | assuming a standard option set |
| Relative path reused after `cd` | Bun marker check after `cd "$BUN_SRC"` (run #41281683381) | return to `$REPO_ROOT` first, or absolutize the path | trusting relative paths to survive a `cd` |
| Stale entrypoint after upstream refactor | `src/cli/cmd/tui/worker.ts` moved to `src/cli/tui/worker.ts` in 1.19.4 (run #41319756768) | resolve entrypoints from the checked-out tree, not from an older release's layout | assuming paths survive a version bump |
| Optional platform packages not installed | `bun add @opentui/core-linux-arm64` records but does not unpack it on an x64 runner | stub the non-host platform modules; supply the real `.so` through `OPENTUI_LIB_PATH` | adding the package and expecting `node_modules` to contain it |
| Build-API drift | Zig 0.15 vs 0.16 vs 0.17 `build.zig` | pin Zig, validate generated scripts, consult `lib/std/Build.zig` | changing the Zig version |
| Hidden patch failure | `git apply … || true` for ghostty | fail on patch mismatch, or assert the expected symbol | continuing with a half-patched tree |
| Patch applied to the wrong tree | `git apply` inside `build/…/ghostty` skipped everything and exited 0 | `git init` the vendor tree; treat `Skipped patch` as an error | trusting `git apply` exit status alone |
| Cached artifact staleness | Zig `translate-c` `FileNotFound` | delete both caches and symlink them | clearing one cache |
| Post-link execution of target binary | `bun --revision` on host | `if(NOT ANDROID)` guards | disabling tests globally |
| Seccomp `SIGSYS` | `close_range` on Android | syscall fallback (v1) or SIGSYS→ENOSYS handler (v2) | retrying the same binary |

### 24.7 Strategy changes adopted from this audit

1. **Validate generated code before the long build.** `build-opentui.sh` now runs
   `zig build --help` in the generated package; the same pattern can be applied to any
   generated `build.zig`.
2. **Do not hide patch failures.** The ghostty vendor patches now go through
   `apply_verified_patch`, which applies (or confirms an already-applied patch) and then
   requires the patched marker in `src/build/SharedDeps.zig`. The helper also gives an
   un-versioned vendor tree its own Git repository first: without it `git apply` resolves
   paths against the enclosing `opencode-termux` worktree, skips every hunk and exits 0
   (§11.4b). The local metallib patch was
   reduced to its guard hunk: its first hunk duplicated the shared-deps change, so the two
   could never apply in sequence. The OpenTUI Android patch uses the same helper, with its
   marker in `packages/native/build.zig`; the old libc-link patch was retired because its
   target file no longer exists (§11.4a).
3. **Never hand-encode multihashes.** Use `zig fetch`, record the exact hash, and pin the URL.
4. **One variable at a time.** The Zig 0.17 excursion and the host Bun 1.4.4 excursion each
   changed two things and made the failure harder to attribute.
5. **Treat a fast repeat failure as deterministic.** Ten failures at the same step in ~12s
   means the code path is wrong; more retries do not add information.
6. **Put the run id and failing step in the commit message** when a CI-driven fix lands, so
   the next person can correlate cause and effect.
7. **Keep log access.** Without authentication the log archive is unavailable; if CI is the
   only compiler, either store the failing step output as an artifact or emit the key compiler
   error into a step annotation.
8. **Lint patch application in CI.** `scripts/lint-patch-application.py` rejects `git apply
   … || true`, `git -C … apply … || true`, and skip-on-mismatch logic. It also requires every
   `patches/**/*.patch` to be applied by some script, at most once per script, with a marker
   assertion whose text occurs in the patch. It runs before the source clone, so a stale,
   orphaned or double-applied patch fails in seconds rather than after a 20-minute build.

### 24.8 Open items from the audit

- All native artifacts are green as of run #41282039365. The OpenCode install now succeeds;
  the next gate is the bundle (`Build OpenCode standalone binary`), where the TUI entrypoint
  and the platform-package stubs were fixed. After it passes, confirm the transplant,
  packaging and artifact upload.
- The bundled JS uses `@opentui/core` 0.4.5 while `libopentui.so` is built from 0.5.10. The
  symbol comparison is clean, but a device smoke test of the TUI is still required.
- Ghostty patch markers are now asserted in `build-opentui.sh`; re-verify them after any
  OpenTUI or ghostty vendor bump, including the `git init` fix and the regenerated metallib
  patch context.
- `uucode-ghostty` no longer has a hand-written `tables.zig`; ghostty's dependency request
  (`namedLazyPath("tables.zig")` → `module("uucode")`) is served by the package's own
  generator, and `build-opentui.sh` asserts the option and named-path contract after install.
- Kitty graphics pulls `wuffs` and `pkg/translate-c` into the Android build, and SIMD pulls
  `pkg/simdutf` and `pkg/highway`. If C/C++ compilation is the next failure, the alternatives
  are to build ghostty-vt with `kitty_graphics` disabled or `simd` off instead of vendoring
  more of `pkg/`.
