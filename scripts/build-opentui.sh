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
OPENTUI_SRC_ABS="${REPO_ROOT_ABS}/${OPENTUI_SRC#./}"
WORK_DIR_ABS="${REPO_ROOT_ABS}/${WORK_DIR#./}"

OPENTUI_VERSION="${OPENTUI_VERSION:-0.5.10}"
OPENTUI_COMMIT_OR_TAG="v${OPENTUI_VERSION}"
ZIG_BIN="${ZIG_BIN:-zig}"

# Bionic sysroot shim dir (merged NDK usr/include for translate-c)
BIONIC_SYSROOT_INC="${WORK_DIR_ABS}/bionic-include"

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

# Build a merged bionic sysroot include dir so Zig translate-c can parse bionic
# headers (nullability annotations are expanded by the shim headers).
rm -rf "$BIONIC_SYSROOT_INC"
mkdir -p "$BIONIC_SYSROOT_INC"
cp -a "$NDK_SYSROOT/usr/include/." "$BIONIC_SYSROOT_INC/"
cp -a "$NDK_SYSROOT/usr/include/aarch64-linux-android/." "$BIONIC_SYSROOT_INC/"

# Vendored deps the shim headers reference as "../miniaudio.h" / "../yoga/yoga/Yoga.h"
mkdir -p "$BIONIC_SYSROOT_INC/yoga"
cp -a "$OPENTUI_SRC_ABS/packages/native/src/vendor/miniaudio/miniaudio.h" "$BIONIC_SYSROOT_INC/miniaudio.h"
cp -a "$OPENTUI_SRC_ABS/packages/native/zig-deps/yoga/yoga" "$BIONIC_SYSROOT_INC/yoga/yoga"
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

export ANDROID_NDK_HOME BIONIC_SYSROOT_INC

OPENTUI_ZIG_DIR="$OPENTUI_SRC_ABS/packages/native"

if [ ! -f "$OPENTUI_ZIG_DIR/build.zig" ]; then
    echo "ERROR: build.zig not found at $OPENTUI_ZIG_DIR"
    exit 1
fi

echo ">>> Building with Zig (target: aarch64-linux-android)..."
cd "$OPENTUI_ZIG_DIR"

"$ZIG_BIN" build \
    -Dlibrary-target=aarch64-linux-android \
    -Doptimize=ReleaseSafe \
    2>&1

# The build installs shared library to ../lib/{output_name} relative to
# packages/native, i.e. packages/native/lib/aarch64-linux-android/libopentui.so
LIBOPENTUI="$OPENTUI_ZIG_DIR/lib/aarch64-linux-android/libopentui.so"
if [ ! -f "$LIBOPENTUI" ]; then
    echo "ERROR: libopentui.so not found"
    echo "  Expected at: $LIBOPENTUI"
    echo "  Searching for any libopentui.so under opentui-src..."
    find "$OPENTUI_SRC_ABS" -name "libopentui.so" -type f 2>/dev/null || true
    exit 1
fi

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
