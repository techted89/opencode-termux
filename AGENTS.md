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

## Critical Build Dependencies

| Component | Version | Notes |
|-----------|---------|-------|
| Bun | 1.2.13 | Host + target; must match for module graph compatibility |
| Zig | 0.16.0 | Builds `libopentui.so` |
| Android NDK | r28b | API 24, aarch64-linux-android |
| WebKit/JSC | 017930ebf9 | Bundled in Bun |
| ICU | 75.1 | Static libs for WebKit |
| OpenTUI | 0.5.10 | Native Zig library, patched for Android |

## Common Failure Modes & Fixes

### 1. `@types/bun` git clone failure in CI
**Symptom**: `error: "git clone" for "@types/bun" failed`
**Fix**: Pre-install globally in workflow before `bun install`:
```yaml
- run: bun add -g @types/bun@1.2.13
```

### 2. ARM64 `libopentui.so` missing or wrong architecture
**Symptom**: `WARNING: ARM64 libopentui.so not found... keeping x86_64 version`
**Root cause**: Zig build didn't produce ARM64 artifact, or path mismatch
**Fix**: 
- Build with `-Dlibrary-target=aarch64-linux-android -Doptimize=ReleaseSafe -Dstrip=true`
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

## Build Order (must be sequential)

1. **ICU** → `scripts/build-icu.sh`
2. **WebKit/JSC** → `scripts/build-webkit.sh` (needs ICU)
3. **TinyCC** → `scripts/build-tinycc.sh`
4. **Bun** → `scripts/build-bun.sh` (needs WebKit, TinyCC)
5. **libopentui.so** → `scripts/build-opentui.sh` (needs Zig, NDK)
6. **OpenCode binary** → `scripts/build-opencode.sh` (needs Bun, libopentui.so)
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

# Verify final OpenCode binary
file build/dist/opencode
readelf -h build/dist/opencode | grep -E "Machine|Class"
```

## Patches Applied

- `patches/bun/android-support.patch` — Android sysroot, seccomp, ARM64 flags
- `patches/webkit/android-support.patch` — JSCOnly Android build fixes
- `patches/zig/posix-android-sigaction.patch` — Bionic sigaction/sigprocmask bypass
- `patches/opentui/v2-0.5.10-android.patch` — aarch64-linux-android target, bionic sysroot, u32 bounds checks
- `patches/opentui/android-libc-link.patch` — Links NDK libc.so stub for `NEEDED libc.so`