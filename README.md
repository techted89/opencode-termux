# OpenCode for Termux (Android aarch64)

Build system for cross-compiling [OpenCode](https://github.com/anomalyco/opencode) to run natively on Android devices via [Termux](https://termux.dev/).

OpenCode is an AI-powered coding assistant for the terminal. It uses [Bun](https://bun.sh/) as its JavaScript runtime and compiles to a standalone binary via `bun build --compile`. Since Bun has no official Android support ([marked "not planned"](https://github.com/oven-sh/bun/issues/9)), this project cross-compiles Bun itself from source for Android/aarch64, including the full WebKit/JavaScriptCore engine.

> **Full build specification:** [docs/BUILD-OPENCODE-1.19.4-ANDROID.md](docs/BUILD-OPENCODE-1.19.4-ANDROID.md) — dependency topology, every patch with diffs and reasoning, the standalone binary format, packaging, CI, and verification, plus implementation strategy, an expanded stage-by-stage runbook, and an agent operating manual.


## Versions

Two engines are available. They install **side by side** -- `opencode` and `opencode2` are
separate packages and commands, and v2 never overwrites v1 files.

| | Command | Status | Runtime |
|---|---|---|---|
| OpenCode 1.x | `opencode` | stable | patched Bun 1.2.13 + WebKit/JSC, built from source |
| OpenCode 2.x | `opencode2` | pre-release | official Bun 1.4.2 android target + OpenTUI 0.5.10 |

Install the v2 pre-release alongside v1:

```bash
curl -LO https://github.com/guysoft/opencode-termux/releases/download/v1.0.3/opencode2-1.0.3-1-aarch64.pkg.tar.xz
pacman -U opencode2-1.0.3-1-aarch64.pkg.tar.xz
opencode2
```

See the [v1.0.3 release](https://github.com/guysoft/opencode-termux/releases/tag/v1.0.3) for
the deb and standalone-zip alternatives.

> **Android seccomp fix.** Android's zygote seccomp policy traps `close_range` (and
> `openat2`/`fchmodat2`/...) with `SECCOMP_RET_TRAP`. Stock Bun dies with `Bad system call`
> (`SIGSYS`, exit 159). v2 embeds a Bun built with the upstream fix (oven-sh/bun#39775),
> which turns the trap into `ENOSYS` so Bun's fallbacks run.
>
> **Two version numbers.** `opencode2 --version` reports the *OpenCode 2 app* version
> (e.g. `2.0.0-android-termux.2`). The `v1.0.x` numbers are **this repo's release/package**
> tags, which track the Android build, not the app.

## Install (Termux)

### Installer script (recommended)

[`scripts/install-termux.sh`](scripts/install-termux.sh) is the all-in-one
installer. It needs no root, downloads the latest release (or a pinned tag or
local archive), installs `ripgrep` and the required installer tools on Termux,
verifies `SHA256SUMS`, checks the aarch64 ELF headers and the packaged
`BUN_SELF_EXE` launcher/runtime markers, backs up the previous installation, and
rolls back automatically if `opencode --version` reports Bun's `1.2.13` instead
of the OpenCode version. It also installs into the correct `$PREFIX/bin`,
`$PREFIX/libexec/opencode`, and `$PREFIX/lib` locations and adds the prefix to
PATH.

```bash
# download the installer, then use the interactive menu
curl -LO https://github.com/techted89/opencode-termux/releases/latest/download/install-termux.sh
chmod +x install-termux.sh
./install-termux.sh

# or update non-interactively to the latest release
./install-termux.sh --latest --yes

# pin a release tag
./install-termux.sh --tag v1.19.4-android.1

# install a local archive or a direct release URL
./install-termux.sh opencode-1.19.4-android-aarch64.tar.xz
./install-termux.sh https://github.com/techted89/opencode-termux/releases/download/v1.19.4-android.1/opencode-1.19.4-android-aarch64.tar.xz

# inspect or remove the installation (configuration and backups are kept)
./install-termux.sh --check
./install-termux.sh --uninstall --yes
```

With no arguments in a terminal it shows the menu; the manual package-manager
routes are below.

### Option 1: Standalone binary (easiest)

> **Note:** The zip and tar.xz mirror the Termux `$PREFIX` layout: `bin/opencode`
> (launcher), `libexec/opencode/opencode.bin` (the ELF), and `lib/*.so` (native
> libraries). Unpack one over `$PREFIX` so the launcher can find them.

```bash
# Download the latest "opencode-*-android-aarch64.zip" from
#   https://github.com/techted89/opencode-termux/releases/latest
# Then install:

unzip -o opencode-*-android-aarch64.zip -d "$PREFIX"
# or: tar -xJf opencode-*-android-aarch64.tar.xz -C "$PREFIX"
chmod +x "$PREFIX/bin/opencode" "$PREFIX/libexec/opencode/opencode.bin"

# Install required dependency
pkg install ripgrep

# Run
opencode
```

### Option 2: Pacman package (recommended if using pacman)

```bash
curl -LO https://github.com/techted89/opencode-termux/releases/latest/download/opencode-1.19.4-1-aarch64.pkg.tar.xz
pacman -U opencode-1.19.4-1-aarch64.pkg.tar.xz
opencode
```

### Option 3: Deb package

```bash
curl -LO https://github.com/techted89/opencode-termux/releases/latest/download/opencode_1.19.4_aarch64.deb
dpkg -i opencode_1.19.4_aarch64.deb
opencode
```

The pacman and deb packages automatically install `ripgrep` as a dependency.

### After install

OpenCode needs an AI provider to work. Set one up by configuring your environment:

```bash
# Example: Use Anthropic Claude
export ANTHROPIC_API_KEY="sk-..."

# Or use OpenAI
export OPENAI_API_KEY="sk-..."

# Then run
opencode
```

See the [OpenCode docs](https://github.com/anomalyco/opencode) for full configuration options.

## What This Repo Contains

This repo contains **patch files and build scripts** only -- not the full source trees of Bun or WebKit (which are 1.1GB and 2.7GB respectively). The CI workflow clones upstream repos and applies patches during build.

```
opencode-termux/
  patches/
    bun/android-support.patch      # 33 files, Bun Android/aarch64 support
    webkit/android-support.patch   # 5 files, WebKit/JSC Android fixes
    zig/posix-android-sigaction.patch  # Zig stdlib sigaction/sigprocmask fix
    opentui/v2-0.5.10-android.patch  # (v2) OpenTUI android/bionic build fixes
    bun/android-seccomp-sigsys.patch # (v2) Bun: turn seccomp SIGSYS into ENOSYS (upstream #39775)
  scripts/
    apply-patches.sh               # Clone upstream repos + apply patches
    build-icu.sh                   # Cross-compile ICU 75.1 for Android
    build-webkit.sh                # Cross-compile WebKit/JSC for Android
    build-tinycc.sh                # Cross-compile TinyCC (libtcc.a) for Android
    build-bun.sh                   # Cross-compile Bun for Android
    build-opentui.sh               # Build libopentui.so for Android
    build-opencode.sh              # Build OpenCode and stage the $PREFIX layout
    transplant-bun-graph.py        # Inspect/transplant/verify the Bun module graph
    make-packages.sh               # Create zip, tar.xz, pacman, and deb packages
    build-opencode-android.ts      # TypeScript helper (host bundle + standalone compile)
    lint-patch-application.py      # Reject silent failures; verify patch coverage and markers
    env-v2.sh                      # (v2) Environment for the v2 pipeline
    build-opentui-v2.sh            # (v2) Build libopentui.so for Android/bionic
    build-bun-android.sh           # (v2) Build patched Bun for Android (seccomp fix)
    build-opencode2-android.sh     # (v2) Build the opencode2 binary (uses patched Bun if present)
    make-packages-v2.sh            # (v2) Create opencode2 zip, pacman, and deb packages
  cmake/
    webkit-android-toolchain.cmake # WebKit CMake cross-compilation toolchain
  .github/workflows/
    build.yml                      # GitHub Actions CI workflow
```

---

## What Was Done

This project got OpenCode (a ~136MB standalone binary built on Bun + WebKit/JSC) running on Android/Termux, which required:

1. **Cross-compiling Bun v1.2.13 for Android/aarch64** -- Bun has zero Android support. We patched 33 files across the build system (CMake, Zig), syscall layer, Bionic libc compatibility, JSC/JIT configuration, and linker settings.

2. **Cross-compiling WebKit/JavaScriptCore for Android** -- No prebuilt WebKit exists for Android. We patched 5 files to replace glibc-specific APIs with POSIX/Android equivalents and fixed JIT signal handling for Android's security model.

3. **Fixing Zig's stdlib for Android/Bionic** -- Zig's `sigaction()` and `sigprocmask()` pass a 152-byte struct through Bionic's libc which expects 32 bytes, causing silent memory corruption. Patched to use raw syscalls on Android.

4. **Building libopentui.so for Android** -- OpenCode's TUI renderer depends on OpenTUI, which needed a patch to link Android NDK's libc.so stub so `dlopen()` can resolve symbols at runtime.

5. **Standalone binary surgery** -- Since `bun build --compile` has no Android cross-compilation target, we build a host standalone binary, extract the serialized module graph, and transplant it onto the Android Bun binary. This required understanding and matching the binary format across Bun versions (36-byte vs 52-byte module struct stride).

6. **Cross-compiling ICU 75.1** -- Bun depends on ICU for Unicode/i18n support. Cross-compiled from source for Android.

7. **Cross-compiling TinyCC** -- Bun links against libtcc.a for FFI support. TinyCC's build system assumes a host build, so we cross-compile it separately and inject the library.

### Build pipeline

```
Stage 1: ICU 75.1          ~5 min    (cross-compile for Android)
Stage 2: WebKit/JSC        ~60-90 min (cross-compile, CACHED)
Stage 3: TinyCC            ~1 min    (cross-compile libtcc.a)
Stage 4: Bun binary        ~30-45 min (CMake + Ninja, CACHED)
Stage 5: libopentui.so     ~2 min    (Zig build for aarch64-linux-android)
Stage 6: OpenCode bundle   ~30 sec   (bun build --compile, extract module graph)
Stage 7: Packages          ~10 sec   (zip + pacman + deb)
```

With warm caches (WebKit + Bun cached), CI runs complete in ~4 minutes.

---

## What Was Patched and Why

### Bun Patches (33 files modified, 2 new files)

Bun has zero Android support. Every patch falls into one of these categories:

#### Build system (CMake/Zig)
- **Android NDK CMake toolchain** (`cmake/toolchains/android-aarch64.cmake`) -- new file. Sets up cross-compiler, sysroot, and find-root paths for the entire Bun build.
- **`-fPIC` instead of `-fno-pic`** -- Android requires position-independent code for all executables and shared libraries (since API 21).
- **PIE linking** -- Android mandates position-independent executables. Changed `-Wl,-no-pie` to `-pie -fPIE`.
- **Rust linker set to NDK's versioned clang** -- The lol-html Rust crate must link against Android's libc, not the host's. Set `CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER` to the NDK's `aarch64-linux-android24-clang`.
- **Zig `translate-c` given NDK sysroot headers** -- Zig has no bundled Android libc headers. Added `-Dandroid-ndk-sysroot` build option that passes NDK include paths to `translate-c`.
- **`-Wno-undefined-var-template`** added -- NDK Clang 19 triggers this warning on some JSC template specializations; with `-Werror`, this becomes a build failure.
- **RELRO kept enabled** -- Desktop Linux disables RELRO (`-Wl,-z,norelro`); Android requires it for security.
- **`CARGO_ENCODED_RUSTFLAGS` replaced with `RUSTFLAGS`** -- CMake can't encode the 0x1F separator that `CARGO_ENCODED_RUSTFLAGS` requires. Switched to space-separated `RUSTFLAGS`.

#### TLS alignment (ARM64 Bionic critical fix)
- **`android_tls_align.s`** -- new file. Assembly file that creates a `.tbss` section with 64-byte alignment. Without this, the Zig linker emits `PT_TLS p_align=8`, causing TLS variables to overlap with Bionic's Thread Control Block slots (TPIDR+0..63), corrupting scudo allocator state and crashing on first allocation. This MUST be assembled (not compiled as C) to avoid NDK's emulated TLS (`__emutls`).
- **`android_tls_align.c`** -- backup C version with `__attribute__((aligned(64)))`.

#### Syscall compatibility
- **`close_range()` fallback** -- Android's seccomp filter blocks the `close_range` syscall in app processes (including Termux). Replaced with iteration over `/proc/self/fd`.
- **`preadv2`/`pwritev2` return ENOSYS** -- These syscalls may be blocked by Android's seccomp. Return ENOSYS so the Zig caller falls back to regular `read()`/`write()`.
- **`epoll_pwait2` return ENOSYS** -- Same seccomp issue. Falls back to `epoll_pwait`.
- **`lchmod` return ENOSYS** -- Not available in Bionic.

#### Bionic libc differences
- **`memmem`, `lstat`, `fstat`, `stat` as `@extern` declarations** -- Bionic has these symbols but Zig's `translate-c` doesn't pick them up due to symbol visibility differences. Declared manually.
- **`getifaddrs`/`freeifaddrs` extern wrappers** -- Hidden by `__INTRODUCED_IN` macros at API 24 despite being available. Declared manually via `@extern`.
- **`pthread_setcancelstate` stubbed** -- Bionic has no POSIX thread cancellation.
- **`posix_spawnattr_setsigdefault`/`setsigmask` stubbed** -- Require API 28, we target API 24. Bun uses its own `posix_spawn_bun()` which handles signals directly.
- **No separate `-lpthread`** -- Bionic merges pthread into libc. Removed from link flags.
- **`pwrite64` not used on Android** -- Android/Bionic uses standard `pwrite`, not the glibc compat symbol.
- **`open()` flag fix** -- Removed third argument (mode) from `open()` call when not creating a file (Bionic is stricter about this).

#### JSC/JIT fixes
- **Signal-based VM traps disabled** (`usePollingTraps=true`) -- Android's `debuggerd` crash handler intercepts SIGSEGV before the app's signal handler, so JSC's signal-based traps crash the process instead of being caught.
- **Wasm fault signal handler disabled** (`useWasmFaultSignalHandler=false`) -- Same `debuggerd` issue. Uses explicit bounds checking instead.
- **Options set via `setenv("JSC_*")` BEFORE `JSC::initialize()`** -- `Options::initialize()` resets all options to defaults before reading env vars. Setting options via the API before `initialize()` has no effect.

#### Standalone binary format
- **`StandaloneModuleGraph.zig` Offsets struct extended** -- Added `compile_exec_argv_ptr`, `flags` fields and `Flags` type to match the format produced by host Bun 1.3.2.
- **`find()` function bug fix** -- Fixed variable name from `base_path` to `name` in `isBunStandaloneFilePath()` call (this was actually an upstream bug).

#### Platform detection
- **`isAndroid` constant** added to `env.zig` -- `isLinux and abi == .android`.
- **`isMusl` excludes Android** -- Android uses Bionic, not musl.
- **`bun upgrade` disabled on Android** -- No Android release channel exists.
- **Crash handler**: Enhanced with aarch64 register dump and `/proc/self/maps` output for debugging crashes on Android.
- **File descriptor limit**: Raised on Android (like musl) since Termux has low defaults.
- **npm libc detection**: Reports as `glibc` for package resolution compatibility.

#### Other
- **Post-build test skip** -- CMake tries to run `bun --revision` after linking; can't run aarch64 binary on x86_64 host. Added `if(NOT ANDROID)` guard.
- **`features.json` skip** -- Same issue; generation requires running the binary.
- **CI artifact naming** -- Uses `bun-android-aarch64` triplet.

### WebKit Patches (5 files)

- **`bcmp` replaced with `memcmp`** -- `bcmp` is BSD, not available in Bionic's `libpas`.
- **`aligned_alloc` replaced with `posix_memalign`** -- `aligned_alloc` requires API 28, we target API 24.
- **`backtrace()` stubbed** -- Requires API 33.
- **`pthread_getname_np` stubbed** -- Requires API 26.
- **JSC `InitializeThreading.cpp`** -- Force polling traps and disable Wasm signal handler on Android (same rationale as Bun patches).

### Zig Stdlib Patch (1 file)

- **`sigaction()` and `sigprocmask()` bypass Bionic libc** -- Bionic's `struct sigaction` is 32 bytes with 8-byte `sigset_t`, but Zig's `linux.Sigaction` is 152 bytes with 128-byte `sigset_t`. Passing Zig's struct through Bionic's `sigaction()` causes silent memory corruption. The patch makes these functions use raw `rt_sigaction`/`rt_sigprocmask` syscalls on Android, which correctly handle the kernel's struct layout.

### OpenTUI Patch (1 file)

- **Link NDK `libc.so` stub** -- On Android, the `.so` must have `NEEDED: libc.so` in its ELF headers so `dlopen()` can resolve symbols like `getauxval`. Zig doesn't bundle Android libc, so we directly add the NDK sysroot's `libc.so` stub as a link input.

---

## How the Standalone Binary Works

Since `bun build --compile` has no Android cross-compilation target, we use a manual approach:

1. Use **host Bun (v1.3.2)** to `bun build --compile` OpenCode for the host platform
2. Extract the serialized **module graph** from the host standalone binary by locating the `\n---- Bun! ----\n` trailer and reading the `Offsets` struct
3. Patch the module graph in-place (fix `undici` global reference)
4. Stage the ARM64 Android-built `libopentui.so` and expose it at runtime through `OPENTUI_LIB_PATH`; it is not embedded in the graph
5. Append the module graph to our **Android Bun** binary
6. Write a new 8-byte `total_byte_count` footer

The standalone binary format:
```
[Android Bun binary (~96 MB)]
[Module graph bytes (~96 MB)]
[total_byte_count as u64 LE (8 bytes)]
```

### Why host and target Bun must be compatible

The serialized module graph is not self-describing: both the `Offsets` struct and the
`CompiledModuleGraphFile` stride are positional, so the host bundler and the Android
runtime must use compatible Bun releases.

| Bun | `Offsets` | Module stride | Layout |
|---|---|---|---|
| 1.2.x (target: 1.2.13) | 24 bytes | 36 bytes (4 StringPointers + 3 u8 + 1 padding) | graph ends at `EOF-8`, `total_byte_count == file size` |
| 1.3.0-1.3.2 (host: 1.3.2) | 32 bytes (`compile_exec_argv`, `flags`) | 36 bytes (same module list) | host graph ends at `EOF-8`; the transplant strips the extra fields for the 1.2.13 runtime |
| >= 1.3.11 | 32 bytes | 52 bytes (6 StringPointers + 4 u8) | trailing data after the trailer, no size footer at EOF |

This pipeline pins **host Bun 1.3.2** and **target Bun 1.2.13**. Both use the
36-byte module stride; 1.3.2 writes the 32-byte `Offsets` variant, and
`scripts/transplant-bun-graph.py` strips `compile_exec_argv`/`flags` to the
24-byte struct the Android runtime reads. This is a **source-mode** graft: upstream
says the graph is not portable between arbitrary Bun binaries (oven-sh/bun#43638),
and a bytecode graph would embed host builtins, so the build must not use
`--bytecode`.

`scripts/transplant-bun-graph.py` locates the trailer from the end of the file,
auto-detects the `Offsets` size and the module stride, validates every StringPointer
against the string-data region, and refuses to graft a graph whose stride does not
match the target. CI runs its `verify` subcommand on the finished binary, so a
host/target mismatch fails the build instead of shipping a binary that dies at startup.

The previous helper hardcoded a 32-byte `Offsets` struct (the 1.3.x layout).
Against the 1.2.13 target runtime it read past the struct and derived a
negative graph size, so the transplant step could not succeed.

OpenCode's monorepo uses the `catalog:` workspace protocol. `build-opencode.sh`
rewrites those references from the root catalog before `bun install`, so the host
bundler remains independent of `catalog:` support.

### Termux self-executable lookup

Termux can enter an executable through `linker64`, where `/proc/self/exe` points at
the linker instead of the file containing the graph. `patches/bun/standalone-self-exe.patch`
backports upstream `BUN_SELF_EXE` ([oven-sh/bun#26752](https://github.com/oven-sh/bun/issues/26752));
the launcher exports it before `exec`, and the build and CI verification check the
marker in both the launcher and the packaged runtime.

### Upgrade status: Bun 1.3.14

Moving the runtime to Bun 1.3.14 is **not** a patch rebase, so the pipeline stays on
1.2.13 until that work is done:

- Bun v1.3.14 no longer ships a `cmake/` tree at all (`git ls-tree -r --name-only bun-v1.3.14 | grep '^cmake/'` is empty); the build moved to `build.zig`. `scripts/build-bun.sh` drives CMake plus `cmake/toolchains/android-aarch64.cmake`, so it needs a full port to the new build system.
- About half of the 33 files in `patches/bun/android-support.patch` moved: `src/standalone/` -> `src/standalone_graph/`, `src/bun.js/*` -> `src/jsc/*`, `src/deps/*` -> `src/cares_sys|tcc_sys/*`, `src/Global.zig` -> `src/bun_core/Global.zig`, `src/env.zig` -> `src/bun_core/env.zig`.
- That release also uses graph layout v2 (32-byte `Offsets`, 52-byte stride, trailing data after the trailer), which a 1.2.13 runtime cannot read.

`scripts/transplant-bun-graph.py inspect` reports the layout of any standalone binary,
so the format half of a version bump can be checked before starting the build-system
port:

```bash
python3 scripts/transplant-bun-graph.py inspect path/to/standalone-binary
```

---

## Known Issues

### Working
- Full TUI rendering (ASCII art logo, prompt, model selector, status bar)
- All backend services (server, provider, file watcher, LSP)
- `opencode --version` outputs correct version
- AI provider connections (tested with Claude, GitHub Copilot)

### Not working / degraded

| Issue | Severity | Details |
|-------|----------|---------|
| File watcher native module | Low | `@parcel/watcher` `.node` binding is compiled for x86_64. Falls back gracefully to polling. Logs: `dlopen failed: "...00000001.node" is for EM_X86_64 (62) instead of EM_AARCH64 (183)` |
| `bun upgrade` | Low | Disabled on Android -- no Android release channel exists upstream |
| TinyCC FFI compilation | Low | `libtcc.a` is linked but TCC's runtime code generation may not produce valid ARM64 code. FFI is not commonly used by OpenCode. |
| SIGPWR signals | None | Many SIGPWR signals appear in strace -- related to Android's power management or Bun's signal handling. Not errors. |

### Workarounds in use

| Workaround | Why |
|-----------|-----|
| Host Bun pinned to 1.3.2, target 1.2.13 | 36-byte module stride; the transplant strips 1.3.x `Offsets` fields for the 1.2.13 runtime (see above) |
| `close_range()` replaced with `/proc/self/fd` iteration | Android seccomp blocks the `close_range` syscall in app processes |
| `preadv2`/`pwritev2`/`epoll_pwait2` return ENOSYS | Seccomp may block these; callers fall back gracefully |
| `setenv("JSC_*")` before `JSC::initialize()` | Options API is reset during initialization; env vars survive the reset |
| `.tbss` section with 64-byte alignment in assembly | Forces `PT_TLS p_align=64` to avoid corrupting Bionic's TCB slots |
| Raw `rt_sigaction`/`rt_sigprocmask` syscalls | Zig's struct layout doesn't match Bionic's; bypass libc entirely |
| NDK `libc.so` stub linked into `libopentui.so` | Zig doesn't provision Android libc; explicit link needed for `dlopen` symbol resolution |
| Module graph extracted via trailer, not `process.execPath` | `process.execPath` is unreliable in CI; trailer-based extraction is version-agnostic |

---

## Upstream PR Opportunities

These patches could potentially be contributed upstream to reduce the maintenance burden of this project.

### Bun (oven-sh/bun) -- Partial upstreaming possible

The Bun team [closed Android support as "not planned"](https://github.com/oven-sh/bun/issues/9). However, some patches are clean improvements regardless of Android:

| Patch | Upstreamable? | Notes |
|-------|:---:|-------|
| `StandaloneModuleGraph.zig` `find()` bug fix (`base_path` -> `name`) | Yes | This is an actual bug in upstream Bun |
| `CARGO_ENCODED_RUSTFLAGS` -> `RUSTFLAGS` | Maybe | Simpler, avoids CMake 0x1F encoding issues. May have side effects on other platforms. |
| `open()` mode argument fix in `bsd.c` | Yes | Passing a mode to `open()` without `O_CREAT` is technically undefined behavior |
| Android CMake toolchain + `if(ANDROID)` guards | No | Team has explicitly declined Android support |
| Syscall fallbacks (`close_range`, `preadv2`, etc.) | No | Only needed on Android |
| Bionic libc stubs (`pthread_setcancelstate`, etc.) | No | Only needed on Android |
| TLS alignment fix | No | Only needed for Android/aarch64 Bionic |
| JSC signal trap changes | No | Only needed on Android due to debuggerd |
| `isAndroid` environment detection | No | Only needed on Android |

**Recommendation**: Submit a small PR with the `find()` bug fix and the `open()` mode fix. These are correctness improvements that benefit all platforms. The rest is Android-specific and will be rejected per Bun team policy.

### WebKit (oven-sh/WebKit) -- Unlikely

| Patch | Upstreamable? | Notes |
|-------|:---:|-------|
| `bcmp` -> `memcmp` | Maybe | `memcmp` is more portable, but oven-sh may not care since they only target macOS/Linux/Windows |
| `aligned_alloc` -> `posix_memalign` | No | Only needed for Android API < 28 |
| `backtrace()` stub | No | Only needed for Android API < 33 |
| `pthread_getname_np` stub | No | Only needed for Android API < 26 |
| Polling traps + Wasm signal handler | No | Only needed on Android |

**Recommendation**: The `bcmp` -> `memcmp` change is the only candidate, but it's unlikely to be accepted since oven-sh/WebKit is a Bun-specific fork. Not worth the effort.

### Zig (oven-sh/zig) -- Should be upstreamed

| Patch | Upstreamable? | Notes |
|-------|:---:|-------|
| `sigaction`/`sigprocmask` Android bypass | Yes | This is a real bug: Zig's POSIX layer corrupts memory on Android/Bionic due to struct size mismatch |

**Recommendation**: This should be submitted to upstream Zig (ziglang/zig), not just oven-sh/zig. The struct layout mismatch between Zig's `Sigaction` (152 bytes) and Bionic's `struct sigaction` (32 bytes) is a genuine bug that affects any Zig program targeting Android. The fix (using raw syscalls on Android) is clean and correct.

**Note**: oven-sh/zig is Bun's custom Zig fork (v0.14.0), not upstream Zig. The patch should be adapted for current Zig master as well.

### OpenTUI (anomalyco/opentui) -- Should be upstreamed

| Patch | Upstreamable? | Notes |
|-------|:---:|-------|
| NDK libc.so stub linking for Android | Yes | Clean, conditionally compiled, needed for any Android target |

**Recommendation**: Submit a PR to `anomalyco/opentui`. The patch correctly detects Android targets in `build.zig` and links the NDK's `libc.so` stub only when targeting `aarch64-linux-android`. It's a small, self-contained change that enables Android support without affecting other targets.

### What will never make it upstream

- **Bun Android support as a whole** -- The Bun team has explicitly declined this. The CMake toolchain, all `if(ANDROID)` guards, syscall fallbacks, Bionic stubs, and TLS alignment fix are permanent patches we'll need to maintain for every Bun version bump.
- **WebKit Android patches** -- oven-sh/WebKit only supports macOS/Linux/Windows. No incentive to accept Android-specific changes.
- **Host Bun version pinning** -- This is a build-time constraint, not a code patch. It will need to be re-evaluated with each Bun version bump (checking if the `CompiledModuleGraphFile` struct changed).
- **Standalone binary surgery** (module graph extraction + transplant) -- This entire approach is a workaround for the lack of cross-compilation in `bun build --compile`. If Bun ever adds cross-compile targets, this becomes unnecessary.

---

## Version Pins

| Component | Version/Commit | Why pinned |
|-----------|---------------|------------|
| Bun (target) | v1.2.13 (tag `bun-v1.2.13`) | Verified Android build; see upgrade status |
| Bun (host) | v1.2.13 | Module graph compat (36-byte stride, layout v1) |
| WebKit/JSC | `017930eb` (oven-sh/WebKit) | Matches Bun v1.2.13's expected WebKit |
| ICU | 75.1 | Matches Bun v1.2.13's expected ICU |
| Android NDK | r28b (28.1.13356709) | Clang 19, stable |
| Android API level | 24 (Android 7.0+) | Minimum for 64-bit Termux |
| Zig (for opentui) | 0.16.0 | `build.zig` uses the 0.16 API (`addLibrary`, `root_module`) |
| OpenCode | 1.19.4 | Target release |
| TinyCC | `b91835d8` (oven-sh/tinycc) | Matches Bun v1.2.13's expected TinyCC |

---

## Build Requirements

- **Build host**: x86_64 Linux (Ubuntu 22.04+)
- **RAM**: 16GB minimum (30GB recommended for WebKit link step)
- **Disk**: 60GB+ free space
- **CPU**: 8+ cores recommended (4 cores works but slow)

### Required tools

| Tool | Version | Purpose |
|------|---------|---------|
| Android NDK | r28b (28.1.13356709) | Cross-compiler toolchain |
| CMake | 3.24+ (CI installs 3.28) | Build system |
| Ninja | 1.10+ | Build tool |
| Rust | stable | lol-html crate (with `aarch64-linux-android` target) |
| Go | 1.20+ | BoringSSL |
| Zig | 0.16.0 | libopentui.so build |
| Bun | 1.2.13 (host, pinned) | OpenCode bundling |
| Python3 | 3.8+ | WebKit code generation |
| Ruby | 2.7+ | WebKit code generation |
| Perl | 5.20+ | WebKit code generation |

---

## Tested On

- Samsung Galaxy S10e (Android 12, Termux, aarch64) -- full TUI confirmed working
- Meta Quest 2 (Android 12L, adb shell)

---

## Credits

- [OpenCode](https://github.com/anomalyco/opencode) by Anomaly
- [Bun](https://github.com/oven-sh/bun) by Oven
- [WebKit/JavaScriptCore](https://github.com/oven-sh/WebKit) (oven-sh fork)
- [OpenTUI](https://github.com/anomalyco/opentui) by Anomaly
- [Termux](https://termux.dev/) -- terminal emulator for Android

## License

MIT
