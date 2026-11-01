#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-v2.sh"

src="${OPENTUI_SRC:-${WORK_DIR}/opentui-${OPENTUI_VERSION}}"
mkdir -p "$WORK_DIR"
if [ ! -d "$src/.git" ]; then
  git clone --depth 1 --branch "v${OPENTUI_VERSION}" https://github.com/anomalyco/opentui.git "$src"
fi
OPENTUI_PATCH="$REPO_ROOT/patches/opentui/v2-0.5.10-android.patch"
if git -C "$src" apply --check "$OPENTUI_PATCH" 2>/dev/null; then
    git -C "$src" apply "$OPENTUI_PATCH"
    echo "    opentui android patch: applied"
elif git -C "$src" apply -R --check "$OPENTUI_PATCH" 2>/dev/null; then
    echo "    opentui android patch: already applied"
else
    echo "ERROR: opentui android patch does not apply to $src" >&2
    exit 1
fi
grep -qF "fn bionicSysrootInclude" "$src/packages/native/build.zig" || {
    echo "ERROR: opentui android patch did not take effect in packages/native/build.zig" >&2
    exit 1
}

rm -rf "$BIONIC_SYSROOT_INC"
mkdir -p "$BIONIC_SYSROOT_INC"
cp -a "$NDK_SYSROOT/usr/include/." "$BIONIC_SYSROOT_INC/"
cp -a "$NDK_SYSROOT/usr/include/aarch64-linux-android/." "$BIONIC_SYSROOT_INC/"

# Vendored deps the shim headers reference as "../miniaudio.h" / "../yoga/yoga/Yoga.h"
mkdir -p "$BIONIC_SYSROOT_INC/yoga"
cp -a "$src/packages/native/src/vendor/miniaudio/miniaudio.h" "$BIONIC_SYSROOT_INC/miniaudio.h"
cp -a "$src/packages/native/zig-deps/yoga/yoga" "$BIONIC_SYSROOT_INC/yoga/yoga"
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

cat > "$ZIG_LIBC" <<EOF
include_dir=$BIONIC_SYSROOT_INC
sys_include_dir=$BIONIC_SYSROOT_INC
crt_dir=$NDK_SYSROOT/usr/lib/aarch64-linux-android/29
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
EOF

export ANDROID_NDK_HOME BIONIC_SYSROOT_INC ZIG_LIBC
cd "$src/packages/native"
"$ZIG_BIN" build -Dlibrary-target=aarch64-linux-android -Doptimize=ReleaseSafe
cp "lib/aarch64-linux-android/libopentui.so" "$OPENTUI_LIB"
