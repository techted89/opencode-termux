#!/usr/bin/env bash
# install-termux.sh - install an OpenCode Android/aarch64 release package.
#
# Accepts any of the four release artifacts (or an https URL to one):
#   opencode-<version>-android-aarch64.zip
#   opencode-<version>-android-aarch64.tar.xz
#   opencode_<version>_aarch64.deb
#   opencode-<version>-1-aarch64.pkg.tar.xz
#
# Usage: ./install-termux.sh [--prefix DIR] [--allow-foreign-arch] [artifact|url]
#
# No root is required: the package is unpacked into a temporary directory and
# its bin/, libexec/ and lib/ trees are copied into the prefix. An existing
# bin/opencode is saved as bin/opencode.pre-install first. The aarch64 ELF
# headers are checked unless --allow-foreign-arch is given.

set -euo pipefail

DEFAULT_PREFIX="/data/data/com.termux/files/usr"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '>>> %s\n' "$*"; }

usage() {
    cat <<'EOF'
Usage: install-termux.sh [options] [artifact|url]

Installs an OpenCode Android/aarch64 package into the Termux prefix.

Options:
  --prefix DIR          install under DIR (default: $PREFIX or the Termux prefix)
  --allow-foreign-arch  skip the aarch64 ELF check
  -h, --help            show this help

With no artifact, the current directory is searched for
opencode-*-android-aarch64.zip, opencode-*-android-aarch64.tar.xz,
opencode_*_aarch64.deb or opencode-*-aarch64.pkg.tar.xz, in that order. An
https URL is downloaded with curl. If a SHA256SUMS file sits next to the
artifact it is verified.
EOF
}

prefix="${PREFIX:-$DEFAULT_PREFIX}"
allow_foreign=0
artifact=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --prefix)
            [ $# -ge 2 ] || die "--prefix needs a directory"
            prefix="$2"
            shift 2
            ;;
        --allow-foreign-arch)
            allow_foreign=1
            shift
            ;;
        --)
            shift
            [ $# -gt 0 ] && artifact="$1"
            break
            ;;
        -*)
            die "unknown option: $1 (try --help)"
            ;;
        *)
            artifact="$1"
            shift
            ;;
    esac
done

case "$prefix" in
    /*) ;;
    *) die "--prefix must be an absolute path: $prefix" ;;
esac
[ -d "$prefix" ] || die "prefix does not exist: $prefix"

if [ -z "$artifact" ]; then
    for pattern in 'opencode-*-android-aarch64.tar.xz' 'opencode-*-android-aarch64.zip' 'opencode_*_aarch64.deb' 'opencode-*-aarch64.pkg.tar.xz'; do
        for candidate in $pattern; do
            if [ -f "$candidate" ]; then
                artifact="$candidate"
                break 2
            fi
        done
    done
fi
[ -n "$artifact" ] || die "no artifact given and none found in $(pwd)"

work="$(mktemp -d "${TMPDIR:-/tmp}/opencode-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT

if [[ "$artifact" == http://* || "$artifact" == https://* ]]; then
    url="$artifact"
    command -v curl >/dev/null 2>&1 || die "curl is required to download packages (pkg install curl)"
    name="${url##*/}"
    name="${name%%\?*}"
    [ -n "$name" ] || name="opencode-package"
    artifact="$work/$name"
    note "Downloading $name"
    curl -fL --retry 3 --connect-timeout 20 -o "$artifact" "$url"
    # Best effort: fetch the checksum file published beside the artifact.
    if [[ "$url" == */* ]]; then
        curl -fsSL --connect-timeout 10 -o "$work/SHA256SUMS" "${url%/*}/SHA256SUMS" 2>/dev/null \
            || rm -f "$work/SHA256SUMS"
    fi
fi

[ -f "$artifact" ] || die "artifact not found: $artifact (download it first, or pass an https:// URL to the release asset)"

artifact_dir="$(cd "$(dirname "$artifact")" && pwd)"
base="$(basename "$artifact")"
if [ -f "$artifact_dir/SHA256SUMS" ] && command -v sha256sum >/dev/null 2>&1; then
    if grep -qF "  $base" "$artifact_dir/SHA256SUMS"; then
        ( cd "$artifact_dir" && grep -F "  $base" SHA256SUMS | sha256sum -c - ) \
            || die "checksum verification failed for $base"
        note "Checksum OK"
    fi
fi

note "Extracting $base"
mkdir -p "$work/pkg"
case "$base" in
    *.zip)
        command -v unzip >/dev/null 2>&1 || die "unzip is required (pkg install unzip)"
        unzip -q "$artifact" -d "$work/pkg"
        ;;
    *.deb)
        if command -v dpkg-deb >/dev/null 2>&1; then
            dpkg-deb -x "$artifact" "$work/pkg"
        elif command -v ar >/dev/null 2>&1; then
            mkdir -p "$work/deb"
            ( cd "$work/deb" && ar x "$artifact" )
            data_file=""
            for candidate in "$work/deb"/data.tar.*; do
                if [ -f "$candidate" ]; then
                    data_file="$candidate"
                    break
                fi
            done
            [ -n "$data_file" ] || die "deb has no data.tar.* member"
            tar -xf "$data_file" -C "$work/pkg"
        else
            die "installing a .deb needs dpkg-deb or ar (pkg install dpkg)"
        fi
        ;;
    *.pkg.tar.xz|*.tar.xz)
        command -v xz >/dev/null 2>&1 || die "xz is required (pkg install xz-utils)"
        tar -xJf "$artifact" -C "$work/pkg"
        ;;
    *)
        die "unsupported artifact type: $base (expected .zip, .tar.xz, .deb or .pkg.tar.xz)"
        ;;
esac

launcher="$(find "$work/pkg" -type f -path '*/bin/opencode' -print -quit 2>/dev/null || true)"
[ -n "$launcher" ] || die "package does not contain bin/opencode"
payload="${launcher%/bin/opencode}"
[ -f "$payload/libexec/opencode/opencode.bin" ] || die "package is missing libexec/opencode/opencode.bin"
[ -d "$payload/lib" ] || die "package is missing lib/"

elf_machine() {
    od -An -tu2 -j18 -N2 "$1" 2>/dev/null | tr -d ' \n'
}

if [ "$allow_foreign" -eq 0 ]; then
    for binary in "$payload/libexec/opencode/opencode.bin" "$payload/lib/libopentui.so"; do
        [ -f "$binary" ] || continue
        machine="$(elf_machine "$binary")"
        [ "$machine" = "183" ] || die "$(basename "$binary") is not aarch64 (ELF e_machine=$machine); use --allow-foreign-arch to inspect it anyway"
    done
    note "aarch64 ELF check OK"
fi

note "Installing into $prefix"
mkdir -p "$prefix/bin" "$prefix/libexec/opencode" "$prefix/lib"

if [ -f "$prefix/bin/opencode" ]; then
    cp -p "$prefix/bin/opencode" "$prefix/bin/opencode.pre-install"
    note "Backed up the previous launcher to $prefix/bin/opencode.pre-install"
fi

cp "$payload/bin/opencode" "$prefix/bin/opencode"
cp "$payload/libexec/opencode/opencode.bin" "$prefix/libexec/opencode/opencode.bin"

shopt -s nullglob
libs=("$payload"/lib/*.so*)
shopt -u nullglob
[ "${#libs[@]}" -gt 0 ] || die "package contains no shared libraries"
cp "${libs[@]}" "$prefix/lib/"

chmod 755 "$prefix/bin/opencode" "$prefix/libexec/opencode/opencode.bin"
chmod 644 "$prefix"/lib/*.so*

[ -s "$prefix/libexec/opencode/opencode.bin" ] || die "installed binary is empty"
[ -f "$prefix/lib/libopentui.so" ] || die "installed libopentui.so is missing"

note "Installed $(basename "$base")"
ls -lh "$prefix/bin/opencode" "$prefix/libexec/opencode/opencode.bin" "$prefix/lib/libopentui.so"

if [ "$(uname -m 2>/dev/null || true)" = "aarch64" ]; then
    version="$("$prefix/bin/opencode" --version 2>&1 || true)"
    printf '>>> opencode --version: %s\n' "${version:-<no output>}"
    case "$version" in
        1.2.13*|*"Usage: bun"*|*"Bun v"*)
            printf 'WARNING: opencode fell back to Bun; the launcher may not be exporting BUN_SELF_EXE correctly.\n' >&2
            ;;
    esac
    [ -n "$version" ] || printf 'WARNING: opencode --version produced no output.\n' >&2
fi

cat <<EOF

Run it with:
  pkg install ripgrep   # required at runtime
  opencode

Set a provider key before the first run, for example:
  export ANTHROPIC_API_KEY=...
EOF
