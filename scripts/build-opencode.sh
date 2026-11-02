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

# env.sh defaults some paths relative to REPO_ROOT and the workflow overrides them
# with relative values, so accept both absolute and relative inputs.
abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s\n' "${REPO_ROOT_ABS}/${1#./}" ;;
    esac
}

OPENCODE_SRC_ABS="$(abspath "$OPENCODE_SRC")"
OPENTUI_SRC_ABS="$(abspath "$OPENTUI_SRC")"
BUN_BUILD_ABS="$(abspath "$BUN_BUILD")"
WORK_DIR_ABS="$(abspath "$WORK_DIR")"
WEBKIT_OUTPUT_ABS="$(abspath "$WEBKIT_OUTPUT")"
DIST_DIR_ABS="$(abspath "$DIST_DIR")"

HOST_BUN="${HOST_BUN:-bun}"
HOST_BUN_VERSION="$("$HOST_BUN" --version 2>/dev/null || echo unknown)"

echo "=== Building OpenCode v${OPENCODE_VERSION} for Android aarch64 ==="
echo ">>> Host Bun: $HOST_BUN_VERSION; target Bun: $BUN_VERSION (module stride ${MODULE_GRAPH_STRIDE:-unset})"

# Clone OpenCode if needed
if [ ! -d "$OPENCODE_SRC_ABS/.git" ]; then
    echo ">>> Cloning OpenCode..."
    git clone --depth 1 --branch "v${OPENCODE_VERSION}" https://github.com/anomalyco/opencode.git "$OPENCODE_SRC_ABS"
else
    echo ">>> OpenCode source exists at $OPENCODE_SRC_ABS"
fi

# Patch package.json: replace "catalog:" references with actual versions
# from the catalog field so the host bundler can resolve them without
# relying on catalog support.
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

# OpenCode's committed lockfile can contain `catalog:` entries that older Bun
# releases treat as a Git spec. The host bundler is pinned to 1.3.2, but discard
# the lockfile so the install does not depend on catalog support; let Bun resolve
# the rewritten manifests.
for lockfile in bun.lock bun.lockb bun.lock.json; do
    if [ -f "$lockfile" ]; then
        echo ">>> Removing $lockfile (removing catalog: lockfile)"
        rm -f "$lockfile"
    fi
done

"$HOST_BUN" install

# One resolution pass for all OpenTUI variants. The workflow caches Bun's
# install cache; --no-cache forced a fresh network fetch on every run.
# Non-host @opentui/core-* imports are redirected by a Bun build plugin in
# build-opencode-android.ts (Bun 1.3.x installs workspace dependencies in an
# isolated layout, so node_modules stubs would not be resolvable anyway).

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

# The ARM64 library is not embedded through @opentui/core-linux-x64: the arm64
# platform stub resolves $OPENTUI_LIB_PATH at runtime, and the launcher exports
# it from the packaged lib/ directory. Nothing to swap here.

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

if [ ! -s "$DIST_DIR_ABS/opencode-host" ]; then
    echo "ERROR: $HOST_BUN did not produce a standalone host binary." >&2
    echo "       Bun.build({ compile }) requires host Bun 1.3.2; 1.2.13 ignores it." >&2
    exit 1
fi

# Clean up copied script
rm -f "$BUILD_SCRIPT_LOCAL"


# ---------------------------------------------------------------------------
# Stage the Termux $PREFIX layout:
#   bin/opencode                     launcher
#   libexec/opencode/opencode.bin    actual ELF (Bun runtime + module graph)
#   lib/*.so*                        libopentui.so, libc++_shared.so, libtagfix.so
# ---------------------------------------------------------------------------
# Host Bun 1.3.2 emits 32-byte Offsets + 36-byte modules. The Android
# 1.2.13 runtime is patched by android-support.patch to the same 32-byte
# Offsets, so transplant-bun-graph.py preserves them. The graph is source-only
# (no --bytecode); upstream does not promise portability between arbitrary Bun
# binaries (oven-sh/bun#43638).
echo ">>> Transplanting module graph onto the Android Bun runtime..."
BIN_DIR="$DIST_DIR_ABS/bin"
LIBEXEC_DIR="$DIST_DIR_ABS/libexec/opencode"
LIB_DIR="$DIST_DIR_ABS/lib"
mkdir -p "$BIN_DIR" "$LIBEXEC_DIR" "$LIB_DIR"

TRANSPLANT_ARGS=(transplant
    --host "$DIST_DIR_ABS/opencode-host"
    --bun "$ANDROID_BUN"
    --output "$LIBEXEC_DIR/opencode.bin")
if [ -n "${MODULE_GRAPH_STRIDE:-}" ]; then
    TRANSPLANT_ARGS+=(--expect-stride "$MODULE_GRAPH_STRIDE")
fi
python3 "$REPO_ROOT/scripts/transplant-bun-graph.py" "${TRANSPLANT_ARGS[@]}"

# Launcher placed in $PREFIX/bin; it locates the real binary and the native libs
# both for an installed package and for an extracted zip.
cat > "$BIN_DIR/opencode" <<'WRAPPER'
#!/data/data/com.termux/files/usr/bin/sh
# opencode - launcher for the OpenCode CLI on Android/Termux
#
# Layout this script understands:
#   installed:  $PREFIX/bin/opencode, $PREFIX/libexec/opencode/opencode.bin,
#               $PREFIX/lib/libopentui.so
#   zip:        bin/opencode, libexec/opencode/opencode.bin, lib/libopentui.so
set -eu

SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
DIR="$(CDPATH= cd -- "$(dirname "$SELF")" && pwd)"
PREFIX="${PREFIX:-$(CDPATH= cd -- "$DIR/.." && pwd)}"
export PREFIX

# Android has no writable /tmp. OpenCode's global scratch directory is
# os.tmpdir()/opencode, so give it the writable Termux temp directory before
# the app starts; otherwise startup fails with mkdir '/tmp/opencode' EACCES.
if [ -z "${TMPDIR:-}" ] || [ ! -d "$TMPDIR" ] || [ ! -w "$TMPDIR" ]; then
    TMPDIR="$PREFIX/tmp"
fi
mkdir -p "$TMPDIR" || {
    echo "opencode: error: cannot create temp directory $TMPDIR" >&2
    exit 1
}
export TMPDIR="$TMPDIR"

# Native renderer library. OPENTUI_LIB_PATH is what @opentui/core consults;
# LD_LIBRARY_PATH covers DT_NEEDED lookups such as libc++_shared.so.
for candidate in "$PREFIX/lib" "$PREFIX/libexec/opencode" "$DIR/lib"; do
    if [ -f "$candidate/libopentui.so" ]; then
        export OPENTUI_LIB_PATH="$candidate/libopentui.so"
        export LD_LIBRARY_PATH="$candidate${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        break
    fi
done

for candidate in "$PREFIX/libexec/opencode/opencode.bin" "$DIR/../libexec/opencode/opencode.bin" "$DIR/opencode.bin"; do
    if [ -x "$candidate" ]; then
        # Termux may enter the binary through the dynamic linker, where
        # /proc/self/exe points at linker64 rather than the file holding the
        # module graph. Bun reads BUN_SELF_EXE before falling back to it.
        export BUN_SELF_EXE="$candidate"
        exec "$candidate" "$@"
    fi
done

echo "opencode: error: could not find opencode.bin (reinstall the package)" >&2
exit 127
WRAPPER
chmod 755 "$BIN_DIR/opencode"

# Fail the build if the Termux self-exe fix is not actually in the artifact.
sh -n "$BIN_DIR/opencode"
grep -qF 'export BUN_SELF_EXE=' "$BIN_DIR/opencode" || {
    echo "ERROR: launcher does not export BUN_SELF_EXE" >&2
    exit 1
}
grep -qF 'export TMPDIR=' "$BIN_DIR/opencode" || {
    echo "ERROR: launcher does not export TMPDIR" >&2
    exit 1
}
grep -aqF 'BUN_SELF_EXE' "$LIBEXEC_DIR/opencode.bin" || {
    echo "ERROR: Bun runtime lacks the BUN_SELF_EXE override" >&2
    exit 1
}

# Native libraries
OPENTUI_LIB_SRC="$WEBKIT_OUTPUT_ABS/lib/libopentui.so"
if [ ! -f "$OPENTUI_LIB_SRC" ]; then
    echo "ERROR: libopentui.so not found at $OPENTUI_LIB_SRC"
    echo "       Run scripts/build-opentui.sh first."
    exit 1
fi
cp "$OPENTUI_LIB_SRC" "$LIB_DIR/libopentui.so"

CXX_SHARED=""
for candidate in \
    "$NDK_SYSROOT/usr/lib/$ANDROID_TRIPLE/libc++_shared.so" \
    "$NDK_SYSROOT/usr/lib/$ANDROID_TRIPLE_API/libc++_shared.so"
do
    if [ -f "$candidate" ]; then
        CXX_SHARED="$candidate"
        cp "$CXX_SHARED" "$LIB_DIR/libc++_shared.so"
        break
    fi
done
if [ -z "$CXX_SHARED" ]; then
    echo "WARNING: libc++_shared.so not found in the NDK sysroot; not packaged"
fi

# libtagfix.so is supplied out-of-band; it is only packaged when present.
if [ -f "$WORK_DIR_ABS/libtagfix.so" ]; then
    cp "$WORK_DIR_ABS/libtagfix.so" "$LIB_DIR/libtagfix.so"
else
    echo "NOTE: no libtagfix.so in $WORK_DIR_ABS; nothing to package"
fi

chmod 755 "$LIBEXEC_DIR/opencode.bin"
chmod 644 "$LIB_DIR"/*.so*

# ---------------------------------------------------------------------------
# Verify the finished artifact
# ---------------------------------------------------------------------------
echo ">>> Verifying standalone binary..."
VERIFY_ARGS=(verify "$LIBEXEC_DIR/opencode.bin")
if [ -n "${MODULE_GRAPH_STRIDE:-}" ]; then
    VERIFY_ARGS+=(--expect-stride "$MODULE_GRAPH_STRIDE")
fi
python3 "$REPO_ROOT/scripts/transplant-bun-graph.py" "${VERIFY_ARGS[@]}"

if command -v file >/dev/null 2>&1; then
    file "$LIBEXEC_DIR/opencode.bin"
    file "$LIB_DIR/libopentui.so"
fi

echo ""
echo "=== OpenCode build complete ==="
echo "Launcher: $BIN_DIR/opencode"
echo "Binary:   $LIBEXEC_DIR/opencode.bin ($(du -h "$LIBEXEC_DIR/opencode.bin" | cut -f1))"
echo "Libraries:"
ls -lh "$LIB_DIR"
echo ""
echo "Install into a Termux prefix with:"
echo "  cp -a $DIST_DIR_ABS/bin/. \"\$PREFIX/bin/\""
echo "  cp -a $DIST_DIR_ABS/libexec/. \"\$PREFIX/libexec/\""
echo "  cp -a $DIST_DIR_ABS/lib/. \"\$PREFIX/lib/\""
