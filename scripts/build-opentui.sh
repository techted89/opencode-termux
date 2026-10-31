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
# bionicSysrootInclude()/bionicSysrootLib() and android-libc-link.patch)
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
OPENTUI_PATCH="$REPO_ROOT/patches/opentui/v2-0.5.10-android.patch"
if [ -f "$OPENTUI_PATCH" ]; then
    echo ">>> Applying opentui Android patch..."
    cd "$OPENTUI_SRC_ABS"
    if ! git apply --check "$OPENTUI_PATCH" 2>/dev/null; then
        echo "    Patch already applied or does not apply cleanly, skipping"
    else
        git apply "$OPENTUI_PATCH"
        echo "    Patch applied successfully"
    fi
fi

# Apply android-libc-link.patch (links NDK libc.so stub so .so has NEEDED libc.so)
ANDROID_LIBC_PATCH="$REPO_ROOT/patches/opentui/android-libc-link.patch"
if [ -f "$ANDROID_LIBC_PATCH" ]; then
    echo ">>> Applying android-libc-link.patch..."
    cd "$OPENTUI_SRC_ABS"
    if ! git apply --check "$ANDROID_LIBC_PATCH" 2>/dev/null; then
        echo "    Patch already applied or does not apply cleanly, skipping"
    else
        git apply "$ANDROID_LIBC_PATCH"
        echo "    Patch applied successfully"
    fi
fi

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

# ghostty build.zig.zon depends on uucode-ghostty
if [ ! -d "$OPENTUI_ZIG_DEPS/uucode-ghostty" ]; then
    echo ">>> Downloading uucode-ghostty zig dependency..."
    curl -fsSL "https://github.com/jacobsandlund/uucode/archive/9d55524551411b493cca41ca06363625d90aff1e.tar.gz" -o "$WORK_DIR_ABS/uucode-ghostty.tar.gz"
    mkdir -p "$OPENTUI_ZIG_DEPS/uucode-ghostty"
    tar -xzf "$WORK_DIR_ABS/uucode-ghostty.tar.gz" --strip-components=1 -C "$OPENTUI_ZIG_DEPS/uucode-ghostty"
    rm -f "$WORK_DIR_ABS/uucode-ghostty.tar.gz"
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
    # Custom ghostty build files from opentui vendor
    curl -fsSL "https://raw.githubusercontent.com/anomalyco/opentui/v0.5.10/packages/native/src/vendor/zig-deps/ghostty-build.zig" -o "$OPENTUI_ZIG_DEPS/ghostty/build.zig"
    curl -fsSL "https://raw.githubusercontent.com/anomalyco/opentui/v0.5.10/packages/native/src/vendor/zig-deps/ghostty-build.zig.zon" -o "$OPENTUI_ZIG_DEPS/ghostty/build.zig.zon"
    curl -fsSL "https://raw.githubusercontent.com/anomalyco/opentui/v0.5.10/packages/native/src/vendor/zig-deps/ghostty-shared-deps.patch" -o "$WORK_DIR_ABS/ghostty-shared-deps.patch"
    (cd "$OPENTUI_ZIG_DEPS/ghostty" && git apply "$WORK_DIR_ABS/ghostty-shared-deps.patch") || true
    rm -rf "$WORK_DIR_ABS/ghostty-staging" "$WORK_DIR_ABS/ghostty.tar.gz" "$WORK_DIR_ABS/ghostty-shared-deps.patch"
fi

# Ensure uucode-ghostty directory exists (from reference guide)
mkdir -p "$OPENTUI_ZIG_DEPS/uucode-ghostty"

# Patch ghostty build.zig.zon for zlib dependency (from reference guide)
GHOSTTY_ZON="$OPENTUI_ZIG_DEPS/ghostty/build.zig.zon"
if [ -f "$GHOSTTY_ZON" ]; then
    if ! grep -q "zlib" "$GHOSTTY_ZON"; then
        echo ">>> Skipping zlib patch - testing without explicit zlib dependency"
        # python3 - "$GHOSTTY_ZON" <<'PYEOF'
        # import sys
        # zon_path = sys.argv[1]
        # with open(zon_path, "r") as f:
        #     content = f.read()
        # zlib_dep = """
        #     .zlib = .{
        #         .url = "https://zlib.net/fossils/zlib-1.3.1.tar.gz",
        #         .hash = "sha256-mpOyt9/ax3zrpaVYpYDnRmfdb+3kWFuR7vtg8Dty3yM",
        #     },
        # """
        # content = content.replace(".dependencies = .{", ".dependencies = .{" + zlib_dep)
        # with open(zon_path, "w") as f:
        #     f.write(content)
        # print("Patched ghostty build.zig.zon with zlib dependency")
        # PYEOF
    fi
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

"$ZIG_BIN_ABS" build \
    -Dlibrary-target=aarch64-linux-android \
    -Doptimize=ReleaseSafe \
    -Dstrip=true \
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
