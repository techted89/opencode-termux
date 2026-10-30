#!/usr/bin/env bash
# Build OpenCode standalone binary for Android aarch64
#
# Usage: ./scripts/build-opencode.sh
#
# This script:
# 1. Clones OpenCode if needed
# 2. Swaps x86_64 libopentui.so with ARM64 version
# 3. Runs the TypeScript build script to create the standalone binary
# 4. Restores original libopentui.so
#
# Requires:
# - Android Bun binary built (scripts/build-bun.sh)
# - libopentui.so built (scripts/build-opentui.sh)
# - Host Bun installed (for bundling)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

# Use absolute paths so they remain valid after cd into subdirectories
REPO_ROOT_ABS="$(cd "$REPO_ROOT" && pwd)"
OPENCODE_SRC_ABS="${REPO_ROOT_ABS}/${OPENCODE_SRC#./}"
OPENTUI_SRC_ABS="${REPO_ROOT_ABS}/${OPENTUI_SRC#./}"
BUN_BUILD_ABS="${REPO_ROOT_ABS}/${BUN_BUILD#./}"
DIST_DIR_ABS="${REPO_ROOT_ABS}/${DIST_DIR#./}"

HOST_BUN="${HOST_BUN:-bun}"

echo "=== Building OpenCode v${OPENCODE_VERSION} for Android aarch64 ==="

# Clone OpenCode if needed
if [ ! -d "$OPENCODE_SRC_ABS/.git" ]; then
    echo ">>> Cloning OpenCode..."
    git clone --depth 1 --branch "v${OPENCODE_VERSION}" https://github.com/anomalyco/opencode.git "$OPENCODE_SRC_ABS"
else
    echo ">>> OpenCode source exists at $OPENCODE_SRC_ABS"
fi

# Patch package.json: replace "catalog:" references with actual versions
# from the catalog field, so host bun 1.2.13 can resolve them without
# needing catalog support (which bun 1.2.13 may lack).
# Also remove @types/bun from dependencies/overrides to avoid git clone failures.
OPENCODE_PKG_JSON="$OPENCODE_SRC_ABS/package.json"
if [ -f "$OPENCODE_PKG_JSON" ]; then
    echo ">>> Patching catalog: references in package.json files..."
    python3 - "$OPENCODE_SRC_ABS" <<'PYEOF'
import json, sys, os

repo_root = sys.argv[1]

# Read root package.json to get the catalog
root_pkg_path = os.path.join(repo_root, "package.json")
with open(root_pkg_path) as f:
    root_pkg = json.load(f)
catalog = root_pkg.get("workspaces", {}).get("catalog", {})

def replace_catalog(obj):
    if isinstance(obj, dict):
        return {k: (catalog.get(k, v) if isinstance(v, str) and v == "catalog:" else replace_catalog(v)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [replace_catalog(v) for v in obj]
    return obj

# Find and patch all package.json files under the repo root
for root, dirs, files in os.walk(repo_root):
    # Skip node_modules directories
    dirs[:] = [d for d in dirs if d != "node_modules"]
    if "package.json" in files:
        pkg_path = os.path.join(root, "package.json")
        try:
            with open(pkg_path) as f:
                pkg = json.load(f)
        except (json.JSONDecodeError, IOError):
            continue
        modified = False
        for section in ("dependencies", "devDependencies"):
            if section in pkg:
                new_section = replace_catalog(pkg[section])
                # Drop @types/bun from dependencies: catalog version 1.4.3
                # causes bun to try git clone which fails in CI.
                if "@types/bun" in new_section:
                    del new_section["@types/bun"]
                    modified = True
                if new_section != pkg[section]:
                    pkg[section] = new_section
                    modified = True
        # For overrides, replace "catalog:" with catalog version if available,
        # otherwise drop the entry (overrides with unresolvable versions cause
        # bun to try git clone which fails in CI).
        if "overrides" in pkg:
            new_overrides = {}
            for k, v in pkg["overrides"].items():
                # Drop @types/bun from overrides: catalog version 1.4.3 causes
                # bun to try git clone which fails in CI. @types/bun is type
                # definitions only - the build works without it.
                if k == "@types/bun":
                    modified = True
                    continue
                if isinstance(v, str) and v == "catalog:":
                    if k in catalog:
                        new_overrides[k] = catalog[k]
                        modified = True
                    # else: drop the override entry
                else:
                    new_overrides[k] = replace_catalog(v)
            if new_overrides != pkg["overrides"]:
                pkg["overrides"] = new_overrides
                modified = True
        # Also remove @types/bun from peerDependencies if present
        if "peerDependencies" in pkg and "@types/bun" in pkg["peerDependencies"]:
            del pkg["peerDependencies"]["@types/bun"]
            modified = True
        if modified:
            with open(pkg_path, "w") as f:
                json.dump(pkg, f, indent=2)
                f.write("\n")
            print(f"Patched {pkg_path}")

print("Catalog references patched.")
PYEOF
fi

# Additional: explicitly remove @types/bun from packages/opencode/package.json
# since it's a known CI failure point
OPENCODE_PKG_JSON="$OPENCODE_SRC_ABS/packages/opencode/package.json"
if [ -f "$OPENCODE_PKG_JSON" ]; then
    python3 - "$OPENCODE_PKG_JSON" <<'PYEOF'
import json, sys
pkg_path = sys.argv[1]
with open(pkg_path) as f:
    pkg = json.load(f)
modified = False
for section in ("dependencies", "devDependencies", "overrides", "peerDependencies"):
    if section in pkg and "@types/bun" in pkg[section]:
        del pkg[section]["@types/bun"]
        modified = True
        print(f"Removed @types/bun from {section} in {pkg_path}")
if modified:
    with open(pkg_path, "w") as f:
        json.dump(pkg, f, indent=2)
        f.write("\n")
PYEOF
fi

OPENCODE_PKG="$OPENCODE_SRC_ABS/packages/opencode"

# Install OpenCode dependencies
echo ">>> Installing OpenCode dependencies..."
cd "$OPENCODE_SRC_ABS"
# Install without --ignore-scripts to ensure optional native packages are installed
# Use --platform and --arch to ensure all platform-specific native packages are available
"$HOST_BUN" install --no-cache

# Also explicitly install the ARM64 native package for the libopentui.so swap
# This ensures @opentui/core-linux-arm64 is available even on x64 host
echo ">>> Installing ARM64 native package..."
"$HOST_BUN" add -D @opentui/core-linux-arm64@0.5.10 --no-cache 2>/dev/null || true
# Ensure x64 native package is installed for the libopentui.so swap
"$HOST_BUN" add -D @opentui/core-linux-x64@0.5.10 --no-cache 2>/dev/null || true
# Also install musl variants to avoid resolution errors during bundling
"$HOST_BUN" add -D @opentui/core-linux-arm64-musl@0.5.10 --no-cache 2>/dev/null || true
"$HOST_BUN" add -D @opentui/core-linux-x64-musl@0.5.10 --no-cache 2>/dev/null || true

# Find the Android bun binary
ANDROID_BUN="$BUN_BUILD_ABS/bun"
if [ ! -f "$ANDROID_BUN" ]; then
    echo "ERROR: Android bun binary not found at $ANDROID_BUN"
    echo "       Run scripts/build-bun.sh first."
    exit 1
fi

# Find ARM64 libopentui.so
# build.zig installs to ../lib/{target} relative to the zig dir
ARM64_LIBOPENTUI="$OPENTUI_SRC_ABS/packages/native/lib/aarch64-linux-android/libopentui.so"
# Fallback: packages/core/src/lib/aarch64-linux-android/libopentui.so (copied by build-opentui.sh)
if [ ! -f "$ARM64_LIBOPENTUI" ]; then
    ALT_LIBOPENTUI="$OPENTUI_SRC_ABS/packages/core/src/lib/aarch64-linux-android/libopentui.so"
    if [ -f "$ALT_LIBOPENTUI" ]; then
        ARM64_LIBOPENTUI="$ALT_LIBOPENTUI"
    else
        # Additional fallback: check webkit-android output
        WEBKIT_LIBOPENTUI="$WEBKIT_OUTPUT_ABS/lib/libopentui.so"
        if [ -f "$WEBKIT_LIBOPENTUI" ]; then
            ARM64_LIBOPENTUI="$WEBKIT_LIBOPENTUI"
        else
            echo "WARNING: ARM64 libopentui.so not found at $ARM64_LIBOPENTUI or $ALT_LIBOPENTUI or $WEBKIT_LIBOPENTUI"
            echo "         The OpenCode binary may embed the wrong architecture libopentui.so"
            ARM64_LIBOPENTUI=""
        fi
    fi
fi

# Verify the found libopentui.so has the correct architecture
if [ -n "$ARM64_LIBOPENTUI" ] && [ -f "$ARM64_LIBOPENTUI" ]; then
    echo ">>> Verifying ARM64 libopentui.so architecture..."
    file "$ARM64_LIBOPENTUI" | grep -q "aarch64" || {
        echo "ERROR: libopentui.so at $ARM64_LIBOPENTUI is not ARM64 architecture"
        file "$ARM64_LIBOPENTUI"
        exit 1
    }
    readelf -d "$ARM64_LIBOPENTUI" | grep -q "NEEDED.*libc.so" || {
        echo "ERROR: libopentui.so is missing NEEDED: libc.so dependency"
        readelf -d "$ARM64_LIBOPENTUI" | grep NEEDED || echo "       (no NEEDED entries found)"
        exit 1
    }
    echo "    libopentui.so architecture and dependencies verified OK"
fi

# Find x86_64 libopentui.so in node_modules and swap it
# OpenCode uses @opentui/core-linux-x64 which has the x86_64 version
OPENTUI_NODE_MODULE=""
for candidate in \
    "$OPENCODE_SRC_ABS/node_modules/@opentui/core-linux-x64/libopentui.so" \
    "$OPENCODE_PKG/node_modules/@opentui/core-linux-x64/libopentui.so" \
    "$OPENCODE_SRC_ABS/node_modules/.bun/@opentui+core-linux-x64@*/node_modules/@opentui/core-linux-x64/libopentui.so"
do
    # Handle glob
    for f in $candidate; do
        if [ -f "$f" ]; then
            OPENTUI_NODE_MODULE="$f"
            break 2
        fi
    done
done

BACKUP_FILE=""
if [ -n "$OPENTUI_NODE_MODULE" ]; then
    echo ">>> Swapping x86_64 libopentui.so with ARM64 version..."
    if [ -n "$ARM64_LIBOPENTUI" ] && [ -f "$ARM64_LIBOPENTUI" ]; then
        BACKUP_FILE="${OPENTUI_NODE_MODULE}.x64.bak"
        cp "$OPENTUI_NODE_MODULE" "$BACKUP_FILE"
        cp "$ARM64_LIBOPENTUI" "$OPENTUI_NODE_MODULE"
        echo "    Backed up to $BACKUP_FILE"
        # Verify the swap
        echo "    Verifying swapped libopentui.so..."
        file "$OPENTUI_NODE_MODULE" | grep -q "aarch64" || {
            echo "ERROR: Swapped libopentui.so is not ARM64 architecture"
            file "$OPENTUI_NODE_MODULE"
            exit 1
        }
        echo "    Swap verified OK"
    else
        echo "WARNING: No ARM64 libopentui.so available; keeping x86_64 version"
    fi
else
    echo "WARNING: Could not find x86_64 libopentui.so in node_modules"
    echo "         The build may embed the wrong architecture"
fi

# Create dist directory
mkdir -p "$DIST_DIR_ABS"

# Run the TypeScript build script
# Copy it into the OpenCode tree so Bun can resolve @opentui/solid/bun-plugin
# from node_modules (Bun resolves bare imports relative to the script file's location)
echo ">>> Building OpenCode standalone binary..."
BUILD_SCRIPT="$REPO_ROOT/scripts/build-opencode-android.ts"
BUILD_SCRIPT_LOCAL="$OPENCODE_PKG/build-opencode-android.ts"
cp "$BUILD_SCRIPT" "$BUILD_SCRIPT_LOCAL"
cd "$OPENCODE_PKG"

OPENCODE_VERSION="$OPENCODE_VERSION" \
    ANDROID_BUN="$ANDROID_BUN" \
    OUTPUT_DIR="$DIST_DIR_ABS" \
    OPENCODE_DIR="$OPENCODE_PKG" \
    "$HOST_BUN" run "$BUILD_SCRIPT_LOCAL"

# Clean up copied script
rm -f "$BUILD_SCRIPT_LOCAL"

# Restore original libopentui.so
if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
    echo ">>> Restoring original x86_64 libopentui.so..."
    mv "$BACKUP_FILE" "$OPENTUI_NODE_MODULE"
fi

# Verify output
OPENCODE_BINARY="$DIST_DIR_ABS/opencode"
if [ ! -f "$OPENCODE_BINARY" ]; then
    echo "ERROR: OpenCode binary not found at $OPENCODE_BINARY"
    exit 1
fi

echo ""
echo "=== OpenCode build complete ==="
echo "Binary: $OPENCODE_BINARY"
echo "Size: $(du -h "$OPENCODE_BINARY" | cut -f1)"
file "$OPENCODE_BINARY"
