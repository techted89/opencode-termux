#!/usr/bin/env bash
# Clone upstream repos and apply Android patches.
#
# Usage: ./scripts/apply-patches.sh [all|bun|webkit]
#
# Splitting the modes lets the workflow clone only the component whose cache
# missed; the other component's source tree is not needed when its build is
# restored from cache.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

MODE="${1:-all}"
case "$MODE" in
    all)    WANT_BUN=1; WANT_WEBKIT=1 ;;
    bun)    WANT_BUN=1; WANT_WEBKIT=0 ;;
    webkit) WANT_BUN=0; WANT_WEBKIT=1 ;;
    *)
        echo "usage: $0 [all|bun|webkit]" >&2
        exit 2
        ;;
esac

echo "=== Applying Patches (${MODE}) ==="

if [ "$WANT_BUN" -eq 1 ]; then
    # --- Clone Bun ---
    if [ ! -d "$BUN_SRC/.git" ]; then
        echo ">>> Cloning Bun v${BUN_VERSION}..."
        git clone --depth 1 --branch "${BUN_TAG}" https://github.com/oven-sh/bun.git "$BUN_SRC"
    else
        echo ">>> Bun source already exists at $BUN_SRC"
    fi

    # Apply Bun patch
    echo ">>> Applying Bun Android patches..."
    cd "$BUN_SRC"
    git checkout -- . 2>/dev/null || true  # Reset any previous patches
    git apply --stat "$REPO_ROOT/patches/bun/android-support.patch"
    git apply "$REPO_ROOT/patches/bun/android-support.patch"
    grep -qF "pub const isAndroid" "src/env.zig" || {
        echo "ERROR: Bun patch marker missing in src/env.zig" >&2
        exit 1
    }
    git apply "$REPO_ROOT/patches/bun/standalone-self-exe.patch"
    echo "    Bun patches applied successfully"
    grep -qF "BUN_SELF_EXE" "src/StandaloneModuleGraph.zig" || {
        echo "ERROR: Bun self-exe patch marker missing in src/StandaloneModuleGraph.zig" >&2
        exit 1
    }
    # $BUN_SRC is relative; continue from the repo root for the summary paths.
    cd "$REPO_ROOT"
fi

if [ "$WANT_WEBKIT" -eq 1 ]; then
    # --- Clone WebKit ---
    if [ ! -d "$WEBKIT_SRC/.git" ]; then
        echo ">>> Cloning WebKit at commit ${WEBKIT_COMMIT}..."
        mkdir -p "$WEBKIT_SRC"
        echo "WEBKIT_SRC absolute: $(cd "$WEBKIT_SRC" && pwd)"
        (cd "$WEBKIT_SRC" && \
            git init && \
            git remote add origin https://github.com/oven-sh/WebKit.git && \
            git fetch --depth=1 origin "${WEBKIT_COMMIT}" && \
            git checkout FETCH_HEAD)
    else
        echo ">>> WebKit source already exists at $WEBKIT_SRC"
    fi

    # Apply WebKit patch
    echo ">>> Applying WebKit Android patches..."
    (cd "$WEBKIT_SRC" && \
        git checkout -- . 2>/dev/null || true && \
        git apply --stat "$REPO_ROOT/patches/webkit/android-support.patch" && \
        git apply "$REPO_ROOT/patches/webkit/android-support.patch")
    echo "    WebKit patches applied successfully"
    grep -qF "usePollingTraps() = true" "$WEBKIT_SRC/Source/JavaScriptCore/runtime/InitializeThreading.cpp" || {
        echo "ERROR: WebKit patch marker missing in InitializeThreading.cpp" >&2
        exit 1
    }
fi

echo ""
echo "=== Patches Applied (${MODE}) ==="
if [ "$WANT_BUN" -eq 1 ]; then
    echo "Bun source:    $BUN_SRC"
fi
if [ "$WANT_WEBKIT" -eq 1 ]; then
    echo "WebKit source: $WEBKIT_SRC"
fi
echo ""
if [ "$WANT_BUN" -eq 1 ]; then
    echo "NOTE: The Zig vendor patch (patches/zig/posix-android-sigaction.patch)"
    echo "      will be applied by build-bun.sh after Zig is downloaded by the"
    echo "      Bun build system."
fi
