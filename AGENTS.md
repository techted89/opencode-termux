# OpenCode Termux AGENTS.md

## Build Architecture

This repository cross-compiles OpenCode for Android/Termux (aarch64) using GitHub Actions. The build produces:
- Standalone `opencode` binary (ELF aarch64)
- `.pkg.tar.xz` (pacman), `.deb`, and `.zip` packages

**Key directories** (relative to repo root):
- `scripts/` — build orchestration scripts
- `.github/workflows/build.yml` — CI pipeline
- `patches/` — upstream patches for Bun, WebKit, Zig, OpenTUI
- `build/` — ephemeral build artifacts (gitignored)

## Build Execution: GitHub Actions Remote Runner Required

**IMPORTANT**: All builds MUST be executed via GitHub Actions remote runner (`ubuntu-latest`). Local Termux development environment has:
- No root access (`/opt`, `/` not writable)
- Limited directory access (only `/data/data/com.termux/files/home/`)
- No Android NDK pre-installed
- Resource constraints (memory, CPU) insufficient for WebKit/Bun compilation

**Development workflow**:
1. Make changes locally in Termux
2. Commit and push to GitHub
3. Trigger GitHub Actions workflow (manual or on push)
4. Monitor build logs and download artifacts
5. Verify artifacts on device if needed

**Path handling**: Scripts use `REPO_ROOT` + relative paths so they work in both environments. GitHub Actions runner paths:
- Repo root: `/home/runner/work/opencode-termux/opencode-termux`
- Work dir: `/home/runner/work/opencode-termux/opencode-termux/build`
- NDK: `/opt/android-ndk` (pre-installed on runner)

## Mandatory Context7 MCP & Runner Intelligence Protocol

1. **Context7 MCP Research Gate:** Prior to executing any shell command, cross-compilation task, or patch application, the agent **must** utilize the Context7 MCP server and online web/repository search utilities to research exact GitHub Actions runner environments, Zig build options, and library dependencies. Never guess dependency hashes, compiler flags, or API level requirements.

2. **Active Runner Log Surveillance:** While GitHub Actions workflows execute, the agent must continuously poll runner logs, intercept build warnings, compiler panics (`SIGABRT`), and missing dependency traces (e.g., missing `zlib` in `build.zig.zon` or `uucode-ghostty` paths).

3. **Dynamic Patch Identification & Management:** When build errors or runner regressions occur, the agent must actively identify, generate, and apply targeted source patches or script fixes. Simultaneously, the agent must remove obsolete patch changes from legacy code that are no longer relevant to current upstream releases.

## Critical Build Dependencies

| Component | Version | Notes |
|-----------|---------|-------|
| Bun | 1.3.2 host / 1.2.13 target | Host needs `Bun.build({compile})`; `android-support.patch` gives the 1.2.13 target the same 32-byte Offsets as host 1.3.2 |
| Zig | 0.16.0 | Builds `libopentui.so` |
| Android NDK | r28b | API 24, aarch64-linux-android |
| WebKit/JSC | 017930ebf9 | Bundled in Bun |
| ICU | 75.1 | Static libs for WebKit |
| OpenTUI | 0.5.10 | Native Zig library, patched for Android |

## Common Failure Modes & Fixes

### 1. `@types/bun` git clone failure in CI
**Symptom**: `error: "git clone" for "@types/bun" failed` (or `@types/node`)
**Root cause**: Bun 1.2.13 cannot parse the `catalog:` entries in OpenCode's `bun.lock`
and treats the unknown protocol as a Git spec. Rewriting `package.json` alone is not enough.
**Fix**: `build-opencode.sh` deletes `bun.lock`/`bun.lockb` before `bun install`; the global
`@types/bun` pre-install in the workflow is only a belt-and-braces measure.

### 2. ARM64 `libopentui.so` missing or wrong architecture
**Symptom**: `WARNING: ARM64 libopentui.so not found... keeping x86_64 version`
**Root cause**: Zig build didn't produce ARM64 artifact, or path mismatch
**Fix**: 
- Build with `-Dlibrary-target=aarch64-linux-android -Doptimize=ReleaseSafe` (OpenTUI 0.5.10 has no `strip` option)
- Verify output at `packages/native/lib/aarch64-linux-android/libopentui.so`
- Copy to `packages/core/src/lib/aarch64-linux-android/` and `webkit-android/lib/`
- Verify with `file` (must show `aarch64`) and `readelf -d` (must have `NEEDED libc.so`)

### 3. Native package resolution errors during bundling
**Symptom**: `Could not resolve: "@opentui/core-linux-arm64-musl"`
**Fix**: Explicitly install all 4 native variants before build:
```bash
bun add -D @opentui/core-linux-arm64@0.5.10 --no-cache
bun add -D @opentui/core-linux-x64@0.5.10 --no-cache
bun add -D @opentui/core-linux-arm64-musl@0.5.10 --no-cache
bun add -D @opentui/core-linux-x64-musl@0.5.10 --no-cache
```

### 4. Zig cache stale references causing FileNotFound
**Symptom**: `FileNotFound` errors in translate-c output cache
**Fix**: Clear Zig cache between builds:
```bash
rm -rf "$BUN_BUILD_ABS/cache/zig" "$BUN_SRC_ABS/.zig-cache"
ln -sfn "$BUN_BUILD_ABS/cache/zig/local" "$BUN_SRC_ABS/.zig-cache"
```

### 5. OpenCode bundler cannot resolve the TUI worker or @opentui platform packages
**Symptom**: `ModuleNotFound resolving .../src/cli/cmd/tui/worker.ts` or `Could not resolve: "@opentui/core-darwin-x64"`
**Root cause**: OpenCode 1.19.4 moved the worker to `src/cli/tui/worker.ts`; `bun add` will not unpack
platform packages whose `os`/`cpu` do not match the runner, but the bundler resolves every literal import.
**Fix**: `build-opencode-android.ts` uses the new worker path and redirects the seven non-host
`@opentui/core-*` imports with a Bun.build plugin that returns `OPENTUI_LIB_PATH` at runtime.

### 6. Termux prints `1.2.13` / Bun help instead of OpenCode
**Symptom**: `opencode --version` prints `1.2.13`; `opencode` prints Bun's CLI help.
**Root causes**:
1. Termux may enter the binary through `linker64`, so `/proc/self/exe` points at the
   linker rather than the file containing the module graph. `BUN_SELF_EXE` addresses this.
2. More importantly, the Android runtime's `Offsets` is 32 bytes because
   `android-support.patch` extends Bun 1.2.13 to match host Bun 1.3.2. Writing a
   24-byte transplant makes the runtime read the module list as offsets; it then
   silently falls back to the CLI. This was the `.2`/`.3` failure.
**Fix**: `patches/bun/standalone-self-exe.patch` backports `BUN_SELF_EXE`
(oven-sh/bun#26752), and `scripts/transplant-bun-graph.py` must preserve or
widen to the 32-byte `Offsets`. The launcher exports the absolute `opencode.bin`
path, and `build-opencode.sh` fails if either the launcher export or the runtime
marker is missing.
**Verify**: `python3 scripts/transplant-bun-graph.py verify build/dist/libexec/opencode/opencode.bin --expect-stride 36`
must report `offsets=32B`, plus the launcher/runtime marker checks:
`grep -qF 'export BUN_SELF_EXE=' build/dist/bin/opencode` and
`grep -aqF 'BUN_SELF_EXE' build/dist/libexec/opencode/opencode.bin`.

### 7. `EACCES: permission denied, mkdir '/tmp/opencode'`
**Symptom**: OpenCode's graph loads, then startup exits with
`EACCES: permission denied, mkdir '/tmp/opencode'`.
**Root cause**: Android has no writable `/tmp`; OpenCode's scratch directory is
`os.tmpdir()/opencode`. The launcher did not export `TMPDIR`, so the app used
the unusable default.
**Fix**: The launcher and installer export `TMPDIR="$PREFIX/tmp"` (or keep an
inherited writable `TMPDIR`) and create it. `build-opencode.sh` and the installer
reject a launcher without the `export TMPDIR=` marker.
**Verify**: `grep -qF 'export TMPDIR=' build/dist/bin/opencode`, and on device
`opencode --version` prints the OpenCode version.

## Build Order (must be sequential)

1. **ICU** → `scripts/build-icu.sh`
2. **WebKit/JSC** → `scripts/build-webkit.sh` (needs ICU)
3. **TinyCC** → `scripts/build-tinycc.sh`
4. **Bun** → `scripts/build-bun.sh` (needs WebKit, TinyCC)
5. **libopentui.so** → `scripts/build-opentui.sh` (needs Zig, NDK)
6. **OpenCode binary** → `scripts/build-opencode.sh` (needs Bun, libopentui.so; emits `dist/{bin,libexec,lib}`)
7. **Packages** → `scripts/make-packages.sh`

## Environment Setup

Source `scripts/env.sh` before any build script. Key exports:
- `REPO_ROOT`, `WORK_DIR`, `BUN_SRC`, `WEBKIT_SRC`, `OPENTUI_SRC`, `OPENCODE_SRC`
- `ANDROID_NDK_HOME`, `ANDROID_API`, `ANDROID_TRIPLE`
- `BUN_VERSION`, `ZIG_VERSION`, `OPENCODE_VERSION`

## GitHub Actions Workflow Notes

- Runner: `ubuntu-latest` (x86_64 host, cross-compiles to aarch64)
- Timeout: 360 min (WebKit link is memory-intensive)
- Caches: ICU, WebKit, Bun binary (keyed by patch hashes)
- `continue-on-error: true` on build job — check artifacts/upload for success

## Path Mapping (GitHub Actions → Termux)

| GitHub Actions | Termux |
|----------------|--------|
| `/home/runner/work/opencode-termux/opencode-termux/build` | `/data/data/com.termux/files/home/opencode-termux/build` |
| `${{ env.WORK_DIR }}` (./build) | `/data/data/com.termux/files/home/opencode-termux/build` |

Scripts use `REPO_ROOT` + relative paths so they work in both environments.

## Verification Commands

```bash
# Verify Bun binary architecture
file build/bun-build/bun | grep aarch64

# Verify libopentui.so
file build/opentui-src/packages/native/lib/aarch64-linux-android/libopentui.so
readelf -d build/opentui-src/packages/native/lib/aarch64-linux-android/libopentui.so | grep NEEDED

# Verify final OpenCode binary and its embedded module graph
file build/dist/libexec/opencode/opencode.bin
readelf -h build/dist/libexec/opencode/opencode.bin | grep -E "Machine|Class"
python3 scripts/lint-patch-application.py
python3 scripts/transplant-bun-graph.py verify build/dist/libexec/opencode/opencode.bin --expect-stride 36
bash -n build/dist/bin/opencode
grep -qF 'export BUN_SELF_EXE=' build/dist/bin/opencode
grep -qF 'export TMPDIR=' build/dist/bin/opencode
grep -aqF 'BUN_SELF_EXE' build/dist/libexec/opencode/opencode.bin
```

## Patches Applied

- `patches/bun/android-support.patch` — Android sysroot, seccomp, ARM64 flags
- `patches/bun/standalone-self-exe.patch` — `BUN_SELF_EXE` override for Termux/linker64 (upstream #26752)
- `patches/webkit/android-support.patch` — JSCOnly Android build fixes
- `patches/zig/posix-android-sigaction.patch` — Bionic sigaction/sigprocmask bypass
- `patches/opentui/v2-0.5.10-android.patch` — aarch64-linux-android target, bionic sysroot, u32 bounds checks
