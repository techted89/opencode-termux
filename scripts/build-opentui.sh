#!/usr/bin/env bash
# Build libopentui.so for Android aarch64
#
# Usage: ./scripts/build-opentui.sh
#
# OpenCode's TUI renderer (@opentui/core) uses a native Zig library.
# We build opentui v0.5.10 with the Android patch (packages/native/build.zig)
# targeting aarch64-linux-android, producing libopentui.so with NEEDED libc.so.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

# Use absolute paths so they remain valid after cd into subdirectories
REPO_ROOT_ABS="$(cd "$REPO_ROOT" && pwd)"
# Handle paths that may already be absolute
if [[ "$OPENTUI_SRC" = /* ]]; then
    OPENTUI_SRC_ABS="$OPENTUI_SRC"
else
    OPENTUI_SRC_ABS="${REPO_ROOT_ABS}/${OPENTUI_SRC#./}"
fi
if [[ "$WORK_DIR" = /* ]]; then
    WORK_DIR_ABS="$WORK_DIR"
else
    WORK_DIR_ABS="${REPO_ROOT_ABS}/${WORK_DIR#./}"
fi

OPENTUI_VERSION="${OPENTUI_VERSION:-0.5.10}"
OPENTUI_COMMIT_OR_TAG="v${OPENTUI_VERSION}"
# Resolve ZIG_BIN to absolute path so it remains valid after cd
if [ -z "$ZIG_BIN" ] || [ "$ZIG_BIN" = "zig" ]; then
    ZIG_BIN_ABS="$(command -v zig || true)"
else
    ZIG_BIN_ABS="${REPO_ROOT_ABS}/${ZIG_BIN#./}"
fi

# Android bionic sysroot + zig libc config (required by v2-0.5.10-android.patch
# bionicSysrootInclude()/bionicSysrootLib())
export BIONIC_SYSROOT_INC="${WORK_DIR_ABS}/bionic-include"
export ZIG_LIBC="${WORK_DIR_ABS}/bionic-libc.txt"
export ANDROID_NDK_LIB_DIR="${NDK_SYSROOT}/usr/lib/${ANDROID_TRIPLE}/${ANDROID_API}"

echo "=== Building libopentui.so for Android aarch64 (opentui v${OPENTUI_VERSION}) ==="

# Clone opentui at the pinned version the android patch targets
if [ ! -d "$OPENTUI_SRC_ABS/.git" ]; then
    echo ">>> Cloning opentui v${OPENTUI_VERSION}..."
    mkdir -p "$OPENTUI_SRC_ABS"
    cd "$OPENTUI_SRC_ABS"
    git init
    git remote add origin https://github.com/anomalyco/opentui.git
    git fetch --depth=1 origin "${OPENTUI_COMMIT_OR_TAG}"
    git checkout FETCH_HEAD
else
    echo ">>> opentui source exists at $OPENTUI_SRC_ABS"
fi

# Apply the opentui Android patch (adds aarch64-linux-android library target,
# bionic sysroot handling, pthread/m guards for android)
# Apply a git-format patch and prove it took effect. Upstream context moves, and a
# patch that silently fails leaves an unpatched vendor tree that only breaks much
# later in the build (docs section 24).
apply_verified_patch() {
    local dir="$1" patch_file="$2" target_rel="$3" marker="$4" label="$5"

    if [ ! -f "$patch_file" ]; then
        echo "ERROR: $label patch not found: $patch_file" >&2
        exit 1
    fi

    # `git apply` resolves patch paths from the worktree root of the repository
    # that encloses the current directory, not from the current directory. The
    # ghostty tree is extracted into build/ inside this project but is not a
    # repository, so without this Git resolved "src/build/SharedDeps.zig"
    # against opencode-termux, printed "Skipped patch ...", and still exited 0.
    # Give every vendor tree its own repository so patch paths are relative to
    # it. (docs section 11.4b)
    if [ ! -d "$dir/.git" ]; then
        git -C "$dir" init -q
    fi

    local apply_output=""
    if (cd "$dir" && git apply --check "$patch_file" 2>/dev/null); then
        apply_output="$(cd "$dir" && git apply --verbose "$patch_file" 2>&1)"
        echo "    $label: applied"
    elif (cd "$dir" && git apply -R --check "$patch_file" 2>/dev/null); then
        echo "    $label: already applied"
    else
        echo "ERROR: $label patch does not apply to $dir" >&2
        (cd "$dir" && git apply --stat "$patch_file") >&2 || true
        exit 1
    fi

    # A skipped hunk exits 0. Belt and braces beside the repository init above.
    if [[ "$apply_output" == *"Skipped patch"* ]]; then
        echo "ERROR: $label patch was skipped in $dir" >&2
        printf '%s\n' "$apply_output" >&2
        exit 1
    fi

    if ! grep -qF -- "$marker" "$dir/$target_rel"; then
        echo "ERROR: $label patch did not take effect in $target_rel" >&2
        echo "       expected marker: $marker" >&2
        exit 1
    fi
}

OPENTUI_PATCH="$REPO_ROOT/patches/opentui/v2-0.5.10-android.patch"
echo ">>> Applying opentui Android patch..."
apply_verified_patch "$OPENTUI_SRC_ABS" "$OPENTUI_PATCH" \
    "packages/native/build.zig" "fn bionicSysrootInclude" "opentui android"

# The old android-libc-link.patch is retired: its target
# packages/core/src/zig/build.zig does not exist in OpenTUI 0.5.10, and the native
# build already sets module.link_libc = true. The NEEDED libc.so postcondition is
# enforced by the readelf check after the build.


OPENTUI_ZIG_DIR="$OPENTUI_SRC_ABS/packages/native"
OPENTUI_ZIG_DEPS="$OPENTUI_ZIG_DIR/zig-deps"

if [ ! -f "$OPENTUI_ZIG_DIR/build.zig" ]; then
    echo "ERROR: build.zig not found at $OPENTUI_ZIG_DIR"
    exit 1
fi

# Vendored zig dependencies required by build.zig.zon:
#   yoga      -> zig-deps/yoga  (required unconditionally)
#   uucode    -> zig-deps/uucode-opentui (lazy dep, may be needed)
# These are not committed to the opentui git repo; populate them now.
mkdir -p "$OPENTUI_ZIG_DEPS"

if [ ! -d "$OPENTUI_ZIG_DEPS/yoga" ]; then
    echo ">>> Downloading yoga zig dependency..."
    curl -fsSL "https://github.com/facebook/yoga/archive/refs/tags/v3.2.1.tar.gz" -o "$WORK_DIR_ABS/yoga.tar.gz"
    mkdir -p "$OPENTUI_ZIG_DEPS/yoga"
    tar -xzf "$WORK_DIR_ABS/yoga.tar.gz" --strip-components=1 -C "$OPENTUI_ZIG_DEPS/yoga"
    rm -f "$WORK_DIR_ABS/yoga.tar.gz"
fi

if [ ! -d "$OPENTUI_ZIG_DEPS/uucode-opentui" ]; then
    echo ">>> Downloading uucode-opentui zig dependency..."
    curl -fsSL "https://github.com/jacobsandlund/uucode/archive/8ad04b756f85a5ba1ac8d2b8cb48d0946f06b630.tar.gz" -o "$WORK_DIR_ABS/uucode-opentui.tar.gz"
    mkdir -p "$OPENTUI_ZIG_DEPS/uucode-opentui"
    tar -xzf "$WORK_DIR_ABS/uucode-opentui.tar.gz" --strip-components=1 -C "$OPENTUI_ZIG_DEPS/uucode-opentui"
    rm -f "$WORK_DIR_ABS/uucode-opentui.tar.gz"
fi

# ghostty build.zig.zon depends on uucode-ghostty. Test for a file inside the
# package, not for the directory: the workflow used to `mkdir -p` this path as
# a legacy workaround for the old stub, so a `-d` guard skipped the extraction
# and left Zig with only the two build files (run 41280659177).
if [ ! -f "$OPENTUI_ZIG_DEPS/uucode-ghostty/src/ucd_inputs.zig" ]; then
    echo ">>> Downloading uucode-ghostty zig dependency..."
    curl -fsSL "https://github.com/jacobsandlund/uucode/archive/9d55524551411b493cca41ca06363625d90aff1e.tar.gz" -o "$WORK_DIR_ABS/uucode-ghostty.tar.gz"
    mkdir -p "$OPENTUI_ZIG_DEPS/uucode-ghostty"
    tar -xzf "$WORK_DIR_ABS/uucode-ghostty.tar.gz" --strip-components=1 -C "$OPENTUI_ZIG_DEPS/uucode-ghostty"
    rm -f "$WORK_DIR_ABS/uucode-ghostty.tar.gz"
fi

# uucode-ghostty must be the real uucode package, not a hand-written stub.
# ghostty's SharedDeps.init asks the dependency for `.build_config_path`,
# `namedLazyPath("tables.zig")` and `module("uucode")`; only uucode's own
# build.zig declares those options and named paths. The stub that used to live
# here accepted only the standard options, so run 41280310141 failed with
# "invalid option: -Dbuild_config_path" and "unable to find named lazypath
# 'tables.zig'". The archive is already pinned by commit, so re-fetching the
# build files from that same commit keeps them from drifting.
UUCODE_GHOSTTY_COMMIT="9d55524551411b493cca41ca06363625d90aff1e"
UUCOD_GHOSTTY_BUILD="$OPENTUI_ZIG_DEPS/uucode-ghostty/build.zig"
UUCOD_GHOSTTY_ZON="$OPENTUI_ZIG_DEPS/uucode-ghostty/build.zig.zon"
echo ">>> Installing upstream build files for uucode-ghostty..."
for build_file in build.zig build.zig.zon; do
    curl -fsSL "https://raw.githubusercontent.com/jacobsandlund/uucode/${UUCODE_GHOSTTY_COMMIT}/${build_file}" \
        -o "$OPENTUI_ZIG_DEPS/uucode-ghostty/${build_file}"
done

# Validate the dependency interface before spending time on the real build. A
# Zig API mismatch fails here instead of as an opaque "Build libopentui.so"
# failure (see docs section 24).
echo ">>> Validating uucode-ghostty/build.zig..."
if ! UUCODE_HELP="$(cd "$OPENTUI_ZIG_DEPS/uucode-ghostty" && "$ZIG_BIN_ABS" build --help 2>&1)"; then
    echo "ERROR: uucode-ghostty/build.zig does not evaluate with $( "$ZIG_BIN_ABS" version )."
    echo "       This is a Zig build API change, not a network or NDK problem."
    printf '%s\n' "$UUCODE_HELP" | head -20 >&2 || true
    exit 1
fi
for option in build_config_path tables_path; do
    if ! grep -qF -- "-D${option}" <<<"$UUCODE_HELP"; then
        echo "ERROR: uucode-ghostty/build.zig no longer declares -D${option}." >&2
        echo "       ghostty's SharedDeps.init passes it; update the pinned uucode commit." >&2
        exit 1
    fi
done
if ! grep -qF 'addNamedLazyPath("tables.zig"' "$UUCOD_GHOSTTY_BUILD"; then
    echo "ERROR: uucode-ghostty/build.zig no longer exports named lazypath tables.zig." >&2
    echo "       ghostty's SharedDeps.init requires it; update the pinned uucode commit." >&2
    exit 1
fi

if [ ! -d "$OPENTUI_ZIG_DEPS/ghostty" ]; then
    echo ">>> Downloading ghostty zig dependency..."
    curl -fsSL "https://github.com/ghostty-org/ghostty/archive/aeda37b305ee3d897ff1bfeddfe39d7fa9366a74.tar.gz" -o "$WORK_DIR_ABS/ghostty.tar.gz"
    mkdir -p "$WORK_DIR_ABS/ghostty-staging"
    tar -xzf "$WORK_DIR_ABS/ghostty.tar.gz" --strip-components=1 -C "$WORK_DIR_ABS/ghostty-staging"
    mkdir -p "$OPENTUI_ZIG_DEPS/ghostty/pkg"
    cp "$WORK_DIR_ABS/ghostty-staging/LICENSE" "$OPENTUI_ZIG_DEPS/ghostty/LICENSE"
    cp -r "$WORK_DIR_ABS/ghostty-staging/include" "$OPENTUI_ZIG_DEPS/ghostty/include"
    cp -r "$WORK_DIR_ABS/ghostty-staging/src" "$OPENTUI_ZIG_DEPS/ghostty/src"
    rm -rf "$OPENTUI_ZIG_DEPS/ghostty/src/font/res"
    cp -r "$WORK_DIR_ABS/ghostty-staging/pkg/android-ndk" "$OPENTUI_ZIG_DEPS/ghostty/pkg/android-ndk"
    cp -r "$WORK_DIR_ABS/ghostty-staging/pkg/apple-sdk" "$OPENTUI_ZIG_DEPS/ghostty/pkg/apple-sdk"
    # Kitty graphics is enabled for lib artifacts on Android, and GhosttyZig
    # wires wuffs in for it; the wuffs shim itself imports translate-c. SIMD is
    # enabled too, and addSimd unconditionally asks for simdutf and highway.
    # All four path dependencies must be present (runs 41281095820 and later).
    cp -r "$WORK_DIR_ABS/ghostty-staging/pkg/translate-c" "$OPENTUI_ZIG_DEPS/ghostty/pkg/translate-c"
    cp -r "$WORK_DIR_ABS/ghostty-staging/pkg/wuffs" "$OPENTUI_ZIG_DEPS/ghostty/pkg/wuffs"
    cp -r "$WORK_DIR_ABS/ghostty-staging/pkg/highway" "$OPENTUI_ZIG_DEPS/ghostty/pkg/highway"
    cp -r "$WORK_DIR_ABS/ghostty-staging/pkg/simdutf" "$OPENTUI_ZIG_DEPS/ghostty/pkg/simdutf"
    # Custom ghostty build files from opentui vendor
    curl -fsSL "https://raw.githubusercontent.com/anomalyco/opentui/v0.5.10/packages/native/src/vendor/zig-deps/ghostty-build.zig" -o "$OPENTUI_ZIG_DEPS/ghostty/build.zig"
    curl -fsSL "https://raw.githubusercontent.com/anomalyco/opentui/v0.5.10/packages/native/src/vendor/zig-deps/ghostty-build.zig.zon" -o "$OPENTUI_ZIG_DEPS/ghostty/build.zig.zon"
    GHOSTTY_SHARED_DEPS_PATCH="$WORK_DIR_ABS/ghostty-shared-deps.patch"
    curl -fsSL "https://raw.githubusercontent.com/anomalyco/opentui/v0.5.10/packages/native/src/vendor/zig-deps/ghostty-shared-deps.patch" -o "$GHOSTTY_SHARED_DEPS_PATCH"
    apply_verified_patch "$OPENTUI_ZIG_DEPS/ghostty" "$GHOSTTY_SHARED_DEPS_PATCH" \
        "src/build/SharedDeps.zig" ".framedata = undefined," "ghostty shared-deps"

    # Skip the Metal shader library on Android. This patch carries only the guard
    # hunk; the framedata change above comes from the shared-deps patch.
    GHOSTTY_METALLIB_PATCH="$REPO_ROOT/patches/opentui/ghostty-android-metallib.patch"
    echo ">>> Applying ghostty Android metallib patch..."
    apply_verified_patch "$OPENTUI_ZIG_DEPS/ghostty" "$GHOSTTY_METALLIB_PATCH" \
        "src/build/SharedDeps.zig" "Only create metallib for Apple targets" "ghostty metallib"
    rm -rf "$WORK_DIR_ABS/ghostty-staging" "$WORK_DIR_ABS/ghostty.tar.gz" "$WORK_DIR_ABS/ghostty-shared-deps.patch"
fi

# Ensure uucode-ghostty directory exists (from reference guide)
mkdir -p "$OPENTUI_ZIG_DEPS/uucode-ghostty"

# Patch ghostty build.zig.zon: the manifest vendored by OpenTUI omits ghostty's
# own path dependencies. GhosttyZig.initVt needs wuffs whenever Kitty graphics
# is enabled, which it is for lib artifacts on Android (only freestanding
# targets force it off), and the wuffs shim imports translate-c (run
# 41281095820). zlib is URL-pinned because the vendored zon has no pkg/zlib
# entry; zlib.net served the runner HTML, so the GitHub release asset is used
# instead (same bytes, verified with `zig fetch`).
GHOSTTY_ZON="$OPENTUI_ZIG_DEPS/ghostty/build.zig.zon"
if [ -f "$GHOSTTY_ZON" ]; then
    echo ">>> Patching ghostty build.zig.zon with vendored dependencies..."
    python3 - "$GHOSTTY_ZON" <<'PYEOF'
import sys

zon_path = sys.argv[1]
with open(zon_path, "r") as f:
    content = f.read()

deps = {
    "wuffs": '    .wuffs = .{ .path = "./pkg/wuffs", .lazy = true },\n',
    "simdutf": '    .simdutf = .{ .path = "./pkg/simdutf", .lazy = true },\n',
    "highway": '    .highway = .{ .path = "./pkg/highway", .lazy = true },\n',
    "translate_c": '    .translate_c = .{ .path = "./pkg/translate-c" },\n',
    "zlib": (
        '    .zlib = .{\n'
        '        .url = "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz",\n'
        '        .hash = "N-V-__8AAJj_QgDBhU17TCtcvdjOZZPDfkvxrEAyZkc14VN8",\n'
        '    },\n'
    ),
}

missing = [name for name in deps if f".{name} = " not in content]
if missing:
    marker = ".dependencies = .{"
    if marker not in content:
        print("ERROR: ghostty build.zig.zon has no dependencies block", file=sys.stderr)
        sys.exit(1)
    content = content.replace(marker, marker + "".join(deps[name] for name in missing), 1)
    with open(zon_path, "w") as f:
        f.write(content)
    print("Added ghostty dependencies: " + ", ".join(missing))
else:
    print("ghostty dependencies already present")
PYEOF
fi

# Create merged bionic sysroot with shimmed C headers (required by the
# android patch's bionicSysrootInclude() for miniaudio/yoga translate-c)
echo ">>> Preparing bionic sysroot at $BIONIC_SYSROOT_INC..."
rm -rf "$BIONIC_SYSROOT_INC"
mkdir -p "$BIONIC_SYSROOT_INC"
cp -a "$NDK_SYSROOT/usr/include/." "$BIONIC_SYSROOT_INC/"
cp -a "$NDK_SYSROOT/usr/include/${ANDROID_TRIPLE}/." "$BIONIC_SYSROOT_INC/"

# Vendored deps the shim headers reference as "../miniaudio.h" / "../yoga/yoga/Yoga.h"
mkdir -p "$BIONIC_SYSROOT_INC/yoga"
cp -a "$OPENTUI_SRC_ABS/packages/native/src/vendor/miniaudio/miniaudio.h" "$BIONIC_SYSROOT_INC/miniaudio.h"
cp -a "$OPENTUI_ZIG_DEPS/yoga/yoga" "$BIONIC_SYSROOT_INC/yoga/yoga"
mkdir -p "$BIONIC_SYSROOT_INC/__opentui"
cat > "$BIONIC_SYSROOT_INC/__opentui/miniaudio_shimmed.h" <<'EOF'
#define _Nullable
#define _Nonnull
#include "../miniaudio.h"
EOF
cat > "$BIONIC_SYSROOT_INC/__opentui/Yoga_shimmed.h" <<'EOF'
#define _Nullable
#define _Nonnull
#include "../yoga/yoga/Yoga.h"
EOF

# Zig libc config file
cat > "$ZIG_LIBC" <<EOF
include_dir=$BIONIC_SYSROOT_INC
sys_include_dir=$BIONIC_SYSROOT_INC
crt_dir=$NDK_SYSROOT/usr/lib/${ANDROID_TRIPLE}/${ANDROID_API}
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
EOF

export ANDROID_NDK_HOME BIONIC_SYSROOT_INC ZIG_LIBC ANDROID_NDK_LIB_DIR

echo ">>> Building with Zig (target: aarch64-linux-android)..."
cd "$OPENTUI_ZIG_DIR"

# Clean any previous build artifacts for this target
rm -rf "$OPENTUI_ZIG_DIR/lib/aarch64-linux-android"

# OpenTUI 0.5.10 does not declare a -Dstrip option; passing it makes Zig
# reject the whole invocation (run 41281508898). ReleaseSafe output is left
# unstripped here and stripped when the packages are assembled.
"$ZIG_BIN_ABS" build \
    -Dlibrary-target=aarch64-linux-android \
    -Doptimize=ReleaseSafe \
    2>&1

# The build installs shared library to ../lib/{output_name} relative to
# packages/native, i.e. packages/native/lib/aarch64-linux-android/libopentui.so
LIBOPENTUI="$OPENTUI_ZIG_DIR/lib/aarch64-linux-android/libopentui.so"
if [ ! -f "$LIBOPENTUI" ]; then
    # Try alternative location
    LIBOPENTUI="$OPENTUI_SRC_ABS/packages/core/src/lib/aarch64-linux-android/libopentui.so"
fi
if [ ! -f "$LIBOPENTUI" ]; then
    echo "ERROR: libopentui.so not found"
    echo "  Expected at: $OPENTUI_ZIG_DIR/lib/aarch64-linux-android/libopentui.so"
    echo "  Or at: $OPENTUI_SRC_ABS/packages/core/src/lib/aarch64-linux-android/libopentui.so"
    echo "  Searching for any libopentui.so under opentui-src..."
    find "$OPENTUI_SRC_ABS" -name "libopentui.so" -type f 2>/dev/null || true
    echo "  Zig build output directory contents:"
    ls -la "$OPENTUI_ZIG_DIR/lib/" 2>/dev/null || echo "  lib directory does not exist"
    exit 1
fi

# Also copy to the core package lib directory where build-opencode.sh looks
mkdir -p "$OPENTUI_SRC_ABS/packages/core/src/lib/aarch64-linux-android"
cp "$LIBOPENTUI" "$OPENTUI_SRC_ABS/packages/core/src/lib/aarch64-linux-android/libopentui.so"

# Copy into webkit-android output (where Bun's CMake expects it via SetupWebKit.cmake)
WEBKIT_OUTPUT_ABS="${REPO_ROOT_ABS}/${WEBKIT_OUTPUT#./}"
mkdir -p "$WEBKIT_OUTPUT_ABS/lib"
cp "$LIBOPENTUI" "$WEBKIT_OUTPUT_ABS/lib/"

echo ""
echo "=== libopentui.so build complete ==="
echo "Output: $WEBKIT_OUTPUT_ABS/lib/libopentui.so"
echo "Size: $(du -h "$WEBKIT_OUTPUT_ABS/lib/libopentui.so" | cut -f1)"
file "$WEBKIT_OUTPUT_ABS/lib/libopentui.so"

# Verify the .so has NEEDED: libc.so (required for Android dlopen)
if readelf -d "$WEBKIT_OUTPUT_ABS/lib/libopentui.so" 2>/dev/null | grep -q "NEEDED.*libc.so"; then
    echo "OK: libopentui.so has NEEDED: libc.so (required for Android)"
else
    echo "ERROR: libopentui.so is missing NEEDED: libc.so dependency"
    echo "       Android dlopen() will fail without this."
    readelf -d "$WEBKIT_OUTPUT_ABS/lib/libopentui.so" 2>/dev/null | grep NEEDED || echo "       (no NEEDED entries found)"
    exit 1
fi
