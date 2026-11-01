#!/usr/bin/env bash
# Create distribution packages for OpenCode Android
#
# Usage: ./scripts/make-packages.sh
#
# Packages the staged $PREFIX layout produced by build-opencode.sh:
#   bin/opencode                    launcher
#   libexec/opencode/opencode.bin   ELF (Bun runtime + module graph)
#   lib/*.so*                       native libraries
#
# Creates three package formats:
# 1. ZIP: opencode-${VERSION}-android-aarch64.zip (unpack over $PREFIX)
# 2. Pacman: opencode-${VERSION}-1-aarch64.pkg.tar.xz (Termux pacman format)
# 3. Deb: opencode_${VERSION}_aarch64.deb (old Termux deb format)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

REPO_ROOT_ABS="$(cd "$REPO_ROOT" && pwd)"

# env.sh defaults these paths relative to REPO_ROOT; the workflow may override
# them with relative values. Accept both forms.
abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s\n' "${REPO_ROOT_ABS}/${1#./}" ;;
    esac
}

DIST_DIR_ABS="$(abspath "$DIST_DIR")"
PKG_DIR_ABS="$(abspath "$WORK_DIR")/packages"

LAUNCHER="$DIST_DIR_ABS/bin/opencode"
BINARY="$DIST_DIR_ABS/libexec/opencode/opencode.bin"
LIB_DIR="$DIST_DIR_ABS/lib"

fail() {
    echo "ERROR: $*" >&2
    echo "       Run scripts/build-opencode.sh first." >&2
    exit 1
}

[ -f "$LAUNCHER" ] || fail "launcher not found at $LAUNCHER"
[ -f "$BINARY" ] || fail "standalone binary not found at $BINARY"
compgen -G "$LIB_DIR/*.so*" >/dev/null || fail "no native libraries in $LIB_DIR"

echo "=== Creating packages for OpenCode v${OPENCODE_VERSION} ==="

BUILD_DATE=$(date +%s)
TERMUX_PREFIX="data/data/com.termux/files/usr"

rm -rf "$PKG_DIR_ABS"
mkdir -p "$PKG_DIR_ABS"

# ==========================================
# 0. Shared staging tree (the $PREFIX layout)
# ==========================================
echo '>>> Staging the $PREFIX layout...'
ZIP_ROOT="$PKG_DIR_ABS/zip-root"
mkdir -p "$ZIP_ROOT"
cp -a "$DIST_DIR_ABS/bin" "$DIST_DIR_ABS/libexec" "$DIST_DIR_ABS/lib" "$ZIP_ROOT/"
find "$ZIP_ROOT" -type f | sort | sed "s|^$ZIP_ROOT/|    |"

# ==========================================
# 1. ZIP package
# ==========================================
echo ">>> Creating ZIP package..."
ZIP_NAME="opencode-${OPENCODE_VERSION}-android-aarch64.zip"
(cd "$ZIP_ROOT" && zip -9 -r "$PKG_DIR_ABS/$ZIP_NAME" bin libexec lib >/dev/null)
echo "    Created $ZIP_NAME"

# ==========================================
# 2. Pacman package (Termux)
# ==========================================
echo ">>> Creating pacman package..."
PACMAN_ROOT="$PKG_DIR_ABS/pacman-root"
PACMAN_PREFIX="$PACMAN_ROOT/$TERMUX_PREFIX"
mkdir -p "$PACMAN_PREFIX"
cp -a "$ZIP_ROOT/bin" "$ZIP_ROOT/libexec" "$ZIP_ROOT/lib" "$PACMAN_PREFIX/"

PACMAN_SIZE=$(du -sb "$PACMAN_PREFIX" | cut -f1)
cat > "$PACMAN_ROOT/.PKGINFO" << EOF
pkgname = opencode
pkgver = ${OPENCODE_VERSION}-1
pkgdesc = AI-powered coding assistant for the terminal
url = https://github.com/anomalyco/opencode
builddate = ${BUILD_DATE}
packager = opencode-termux
size = ${PACMAN_SIZE}
arch = aarch64
license = MIT
depend = ripgrep
EOF

PACMAN_NAME="opencode-${OPENCODE_VERSION}-1-aarch64.pkg.tar.xz"
(cd "$PACMAN_ROOT" && tar cf - .PKGINFO data | xz -9 > "$PKG_DIR_ABS/$PACMAN_NAME")
echo "    Created $PACMAN_NAME"

# ==========================================
# 3. Deb package (old Termux format)
# ==========================================
echo ">>> Creating deb package..."
DEB_ROOT="$PKG_DIR_ABS/deb-root"
DEB_PREFIX="$DEB_ROOT/data/data/data/com.termux/files/usr"
mkdir -p "$DEB_PREFIX" "$DEB_ROOT/DEBIAN"
cp -a "$ZIP_ROOT/bin" "$ZIP_ROOT/libexec" "$ZIP_ROOT/lib" "$DEB_PREFIX/"

INSTALLED_SIZE=$(du -sk "$DEB_ROOT/data" | cut -f1)
cat > "$DEB_ROOT/DEBIAN/control" << EOF
Package: opencode
Version: ${OPENCODE_VERSION}
Architecture: aarch64
Maintainer: Guy Sheffer <guysoft@gmail.com>
Installed-Size: ${INSTALLED_SIZE}
Depends: ripgrep
Section: utils
Priority: optional
Homepage: https://github.com/anomalyco/opencode
Description: AI-powered coding assistant for the terminal
 OpenCode is an AI-powered coding assistant that runs in the terminal.
 This package provides a standalone binary compiled for Android/Termux,
 installed under \$PREFIX/bin, \$PREFIX/libexec/opencode and \$PREFIX/lib.
EOF

DEB_NAME="opencode_${OPENCODE_VERSION}_aarch64.deb"
(cd "$DEB_ROOT/data" && tar czf "$DEB_ROOT/data.tar.gz" data)
(cd "$DEB_ROOT/DEBIAN" && tar czf "$DEB_ROOT/control.tar.gz" control)
printf '2.0\n' > "$DEB_ROOT/debian-binary"
(cd "$DEB_ROOT" && ar rc "$PKG_DIR_ABS/$DEB_NAME" debian-binary control.tar.gz data.tar.gz)
echo "    Created $DEB_NAME"

rm -rf "$ZIP_ROOT" "$PACMAN_ROOT" "$DEB_ROOT"

# ==========================================
# Summary
# ==========================================
# Ship the root-free installer next to the packages and checksum it too, so
# users can verify every release asset with one `sha256sum -c SHA256SUMS`.
install -m 755 "$REPO_ROOT_ABS/scripts/install-termux.sh" "$PKG_DIR_ABS/install-termux.sh"
(cd "$PKG_DIR_ABS" && sha256sum "$ZIP_NAME" "$PACMAN_NAME" "$DEB_NAME" install-termux.sh > SHA256SUMS)

echo ""
echo "=== Packages created ==="
echo ""
ls -lh "$PKG_DIR_ABS/$ZIP_NAME" "$PKG_DIR_ABS/$PACMAN_NAME" "$PKG_DIR_ABS/$DEB_NAME" "$PKG_DIR_ABS/SHA256SUMS" "$PKG_DIR_ABS/install-termux.sh"
echo ""
echo "Install on Termux:"
echo "  pacman -U $PACMAN_NAME"
echo "  dpkg -i $DEB_NAME"
echo "  unzip -o $ZIP_NAME -d \"\$PREFIX\"   # zip mirrors the \$PREFIX layout"
