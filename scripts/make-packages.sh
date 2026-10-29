#!/usr/bin/env bash
# Create distribution packages for OpenCode Android
#
# Usage: ./scripts/make-packages.sh
#
# Creates three package formats:
# 1. ZIP: opencode-${VERSION}-android-aarch64.zip (standalone binary)
# 2. Pacman: opencode-${VERSION}-1-aarch64.pkg.tar.xz (Termux pacman format)
# 3. Deb: opencode_${VERSION}_aarch64.deb (old Termux deb format)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

# Use absolute paths so they remain valid after cd into subdirectories
REPO_ROOT_ABS="$(cd "$REPO_ROOT" && pwd)"
OPENCODE_BINARY_ABS="${REPO_ROOT_ABS}/${DIST_DIR#./}/opencode"
PKG_DIR_ABS="${REPO_ROOT_ABS}/${WORK_DIR#./}/packages"
DIST_DIR_ABS="${REPO_ROOT_ABS}/${DIST_DIR#./}"

if [ ! -f "$OPENCODE_BINARY_ABS" ]; then
    echo "ERROR: OpenCode binary not found at $OPENCODE_BINARY_ABS"
    echo "       Run scripts/build-opencode.sh first."
    exit 1
fi

echo "=== Creating packages for OpenCode v${OPENCODE_VERSION} ==="

BINARY_SIZE=$(stat -c%s "$OPENCODE_BINARY_ABS")
BUILD_DATE=$(date +%s)

# Clean up
rm -rf "$PKG_DIR_ABS"
mkdir -p "$PKG_DIR_ABS"

# ==========================================
# 1. ZIP package
# ==========================================
echo ">>> Creating ZIP package..."
ZIP_NAME="opencode-${OPENCODE_VERSION}-android-aarch64.zip"
cd "$DIST_DIR_ABS"
zip -9 "$PKG_DIR_ABS/$ZIP_NAME" opencode
echo "    Created $ZIP_NAME"

# ==========================================
# 2. Pacman package (Termux)
# ==========================================
echo ">>> Creating pacman package..."
PACMAN_STAGING="$PKG_DIR_ABS/pacman-staging"
mkdir -p "$PACMAN_STAGING/data/data/com.termux/files/usr/bin"

cp "$OPENCODE_BINARY_ABS" "$PACMAN_STAGING/data/data/com.termux/files/usr/bin/opencode"
chmod 755 "$PACMAN_STAGING/data/data/com.termux/files/usr/bin/opencode"

# Create .PKGINFO
cat > "$PACMAN_STAGING/.PKGINFO" << EOF
pkgname = opencode
pkgver = ${OPENCODE_VERSION}-1
pkgdesc = AI-powered coding assistant for the terminal
url = https://github.com/anomalyco/opencode
builddate = ${BUILD_DATE}
packager = opencode-termux
size = ${BINARY_SIZE}
arch = aarch64
license = MIT
depend = ripgrep
EOF

PACMAN_NAME="opencode-${OPENCODE_VERSION}-1-aarch64.pkg.tar.xz"
cd "$PACMAN_STAGING"
tar cf - .PKGINFO data | xz -9 > "$PKG_DIR_ABS/$PACMAN_NAME"
echo "    Created $PACMAN_NAME"

# ==========================================
# 3. Deb package (old Termux format)
# ==========================================
echo ">>> Creating deb package..."
DEB_STAGING="$PKG_DIR_ABS/deb-staging"
mkdir -p "$DEB_STAGING/data/data/data/com.termux/files/usr/bin"
mkdir -p "$DEB_STAGING/DEBIAN"

cp "$OPENCODE_BINARY_ABS" "$DEB_STAGING/data/data/data/com.termux/files/usr/bin/opencode"
chmod 755 "$DEB_STAGING/data/data/data/com.termux/files/usr/bin/opencode"

# Create control file
INSTALLED_SIZE=$((BINARY_SIZE / 1024))
cat > "$DEB_STAGING/DEBIAN/control" << EOF
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
 This package provides a standalone binary compiled for Android/Termux.
EOF

DEB_NAME="opencode_${OPENCODE_VERSION}_aarch64.deb"

# Build deb manually (dpkg-deb may not be available)
cd "$DEB_STAGING/data"
tar czf "$DEB_STAGING/data.tar.gz" data
cd "$DEB_STAGING/DEBIAN"
tar czf "$DEB_STAGING/control.tar.gz" control
echo "2.0" > "$DEB_STAGING/debian-binary"
cd "$DEB_STAGING"
ar rc "$PKG_DIR_ABS/$DEB_NAME" debian-binary control.tar.gz data.tar.gz
echo "    Created $DEB_NAME"

# ==========================================
# Summary
# ==========================================
echo ""
echo "=== Packages created ==="
echo ""
ls -lh "$PKG_DIR_ABS"/*.{zip,xz,deb} 2>/dev/null
echo ""
echo "Install on Termux:"
echo "  pacman -U $PACMAN_NAME"
echo "  dpkg -i $DEB_NAME"
echo "  unzip $ZIP_NAME -d /data/data/com.termux/files/usr/bin/"
