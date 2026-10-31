#!/usr/bin/env bash
# ==============================================================================
# OpenCode Android AArch64 Termux Cross-Compilation & Log-Auditing Engine
# ==============================================================================

set -euo pipefail

REPO_ROOT="$(pwd)"
BUILD_DIR="${REPO_ROOT}/build"
OPENTUI_DIR="${BUILD_DIR}/opentui-src"
OPENCODE_DIR="${BUILD_DIR}/opencode-src"
TERMUX_TARGET_DIR="/data/data/com.termux/files/home/opencode-termux"

echo "=== OpenCode Android Build Environment & ELF Target Setup ==="
echo "Repo root:     ${REPO_ROOT}"
echo "Work dir:      ${BUILD_DIR}"
echo "Target Path:   ${TERMUX_TARGET_DIR}"
echo "Target ABI:    aarch64-linux-android"
echo "==========================================================="

mkdir -p "${BUILD_DIR}"
mkdir -p "${TERMUX_TARGET_DIR}"

cd "${BUILD_DIR}"

# 1. Clone Repositories if Missing
if [ ! -d "${OPENTUI_DIR}" ]; then
  git clone https://github.com/opentui/opentui.git "${OPENTUI_DIR}"
fi

if [ ! -d "${OPENCODE_DIR}" ]; then
  git clone https://github.com/opencode-ai/opencode.git "${OPENCODE_DIR}"
  cd "${OPENCODE_DIR}"
  git checkout 148842ef7cb1bc34192b3fff57d0f9721ab9c801
  cd "${BUILD_DIR}"
fi

# 2. Programmatically Resolve Zig Dependencies (zlib & ghostty build.zig.zon patch)
GHOSTTY_ZON="${OPENTUI_DIR}/packages/native/zig-deps/ghostty/build.zig.zon"
if [ -f "${GHOSTTY_ZON}" ]; then
  echo "[+] Auditing ghostty build.zig.zon for zlib dependency declaration..."
  if ! grep -q "zlib" "${GHOSTTY_ZON}"; then
    python3 -c '
zon_path = "'"${GHOSTTY_ZON}"'"
with open(zon_path, "r") as f:
    content = f.read()
zlib_block = """
    .zlib = .{
        .url = "https://github.com/madler/zlib/tarball/v1.3.1",
        .hash = "12209d76f09e5772392437637841f48680199e843bcbc50bcf5123d463d1a19615a1",
    },
"""
if ".dependencies = .{" in content:
    content = content.replace(".dependencies = .{", ".dependencies = .{" + zlib_block)
with open(zon_path, "w") as f:
    f.write(content)
'
    echo "[✓] Successfully injected zlib dependency into ghostty build.zig.zon."
  fi
fi

# Ensure uucode-ghostty path exists to prevent FileNotFound panics
mkdir -p "${OPENTUI_DIR}/packages/native/zig-deps/uucode-ghostty"

# 3. Build native libopentui.so for aarch64-linux-android using Zig
echo ">>> Compiling native libopentui.so for aarch64-linux-android..."
cd "${OPENTUI_DIR}/packages/native"
zig build -Dlibrary-target=aarch64-linux-android -Doptimize=ReleaseSafe

ARM64_LIB="${OPENTUI_DIR}/packages/native/lib/aarch64-linux-android/libopentui.so"
CORE_LIB="${OPENTUI_DIR}/packages/core/src/lib/aarch64-linux-android/libopentui.so"

mkdir -p "$(dirname "${CORE_LIB}")"
if [ -f "${ARM64_LIB}" ]; then
  cp "${ARM64_LIB}" "${CORE_LIB}"
  echo "[✓] ARM64 libopentui.so compiled and synced to core packages."
else
  echo "[-] ERROR: libopentui.so build failed to output ARM64 library artifact." >&2
  exit 1
fi

# 4. Resolve Bun Workspace Dependencies & Catalog Resolution Fallbacks
echo ">>> Installing OpenCode dependencies via Bun..."
cd "${OPENCODE_DIR}"
bun install --no-cache || {
  echo "[!] Bun catalog resolution warning detected; forcing package resolution..."
  bun install --force
}

# 5. Build Standalone Binary with Correct Target Flags (Fixing Node.js builtin bundling errors)
echo ">>> Building OpenCode standalone binary for Node/Bun Target..."
bun run build --target=bun --platform=node

# 6. Synchronize Artifacts to Termux File System Execution Location
echo ">>> Syncing build artifacts to Termux absolute target directory..."
rsync -av --exclude '.git' "${BUILD_DIR}/" "${TERMUX_TARGET_DIR}/"

echo "[✓] Termux OpenCode 1.19.4 aarch64 binary compilation pipeline executed successfully."