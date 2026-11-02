#!/usr/bin/env bash
# install-termux.sh - hardened all-in-one OpenCode installer for Termux/aarch64.
#
# One script handles:
#   * downloading the latest release (or a selected tag/artifact/URL)
#   * installing runtime dependencies (ripgrep) and installer tools
#   * detecting and replacing an existing OpenCode installation
#   * verifying SHA256SUMS, aarch64 ELF headers, and the BUN_SELF_EXE fix
#   * backing up the old install and rolling back if the new one cannot start
#   * installing the launcher, runtime, and native libraries in the right places
#   * adding the install prefix to PATH (and the shell rc files on Termux)
#   * check and uninstall modes
#
# No root is required. The release archives contain the launcher, the Bun
# runtime with the embedded module graph, and the native libraries; this script
# never installs or invokes the system Bun binary.
#
# Usage:
#   ./install-termux.sh                       # interactive menu
#   ./install-termux.sh --latest --yes        # update to the latest release
#   ./install-termux.sh --tag v1.19.4-android.2
#   ./install-termux.sh ./opencode-*.tar.xz
#   ./install-termux.sh https://github.com/.../opencode-*.tar.xz
#   ./install-termux.sh --check
#   ./install-termux.sh --uninstall --yes
#
# Environment:
#   OPENCODE_TERMUX_REPO   GitHub owner/repo (default: techted89/opencode-termux)
#   PREFIX                 install prefix (default: Termux $PREFIX)
#   OPENCODE_NO_DEPS=1     same as --no-deps

set -euo pipefail

DEFAULT_PREFIX="/data/data/com.termux/files/usr"
REPO="${OPENCODE_TERMUX_REPO:-techted89/opencode-termux}"
API_ROOT="https://api.github.com/repos/${REPO}"
RELEASE_ROOT="https://github.com/${REPO}/releases"
INSTALLER_VERSION="2.0.0"

die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
note() { printf '>>> %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
    cat <<'EOF'
OpenCode for Termux - hardened all-in-one installer

Usage: install-termux.sh [options] [artifact|url]

With no arguments in a terminal, an interactive menu is shown. A path or URL
installs that package directly. On Termux, --latest checks GitHub for a newer
release, installs ripgrep, replaces the previous OpenCode files, and keeps a
timestamped backup for rollback.

Options:
  --latest                 install/update to the latest GitHub release
  --tag TAG                install a specific release tag (for example
                           v1.19.4-android.2); --version is an alias
  --artifact PATH|URL      explicit local package or https URL (also positional)
  --prefix DIR             install under DIR (default: $PREFIX or the Termux prefix)
  --yes, -y                non-interactive; accept defaults
  --interactive            show the menu even when stdin is not a terminal
  --no-deps                do not run pkg install for ripgrep/curl/xz/unzip
  --allow-foreign-arch     skip the aarch64 ELF check (inspection only)
  --no-checksum            skip SHA256SUMS verification (development only)
  --keep-backup            keep every backup instead of the newest three
  --force                  reinstall even when the release tag is unchanged
  --check                  report the installed version and file markers
  --uninstall              remove the package files; keep configuration/backups
  -h, --help               show this help

The installer verifies:
  * SHA256SUMS for the selected artifact
  * ELF e_machine == AArch64 (183) for opencode.bin and libopentui.so
  * the launcher exports BUN_SELF_EXE and the runtime contains the override
  * `opencode --version` reports the expected OpenCode version and not Bun
    (on aarch64 devices only)

Exit status is non-zero if verification fails; the previous installation is
restored automatically.
EOF
}

prefix="${PREFIX:-$DEFAULT_PREFIX}"
artifact=""
release_tag=""
mode=""
assume_yes=0
force_interactive=0
no_deps="${OPENCODE_NO_DEPS:-0}"
allow_foreign=0
no_checksum=0
keep_backup=0
force=0
work=""
backup=""
success=0
expected_version=""
release_artifact_url=""
release_sums_url=""

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
        --latest)
            mode="latest"
            shift
            ;;
        --tag|--version)
            [ $# -ge 2 ] || die "$1 needs a release tag"
            release_tag="$2"
            mode="tag"
            shift 2
            ;;
        --artifact|--url)
            [ $# -ge 2 ] || die "$1 needs a path or URL"
            artifact="$2"
            shift 2
            ;;
        --yes|-y)
            assume_yes=1
            shift
            ;;
        --interactive)
            force_interactive=1
            shift
            ;;
        --no-deps)
            no_deps=1
            shift
            ;;
        --allow-foreign-arch)
            allow_foreign=1
            shift
            ;;
        --no-checksum)
            no_checksum=1
            shift
            ;;
        --keep-backup)
            keep_backup=1
            shift
            ;;
        --force)
            force=1
            shift
            ;;
        --check)
            mode="check"
            shift
            ;;
        --uninstall)
            mode="uninstall"
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

host_arch="$(uname -m 2>/dev/null || printf 'unknown')"
is_termux=0
case "$prefix" in
    /data/data/com.termux/files/usr*) is_termux=1 ;;
esac
if [ "$is_termux" -eq 1 ] && [ "$host_arch" != "aarch64" ] && [ "$allow_foreign" -eq 0 ]; then
    die "this installer targets Termux aarch64 (host is $host_arch); use --prefix for inspection or --allow-foreign-arch"
fi

mkdir -p "$prefix" || die "cannot create prefix: $prefix"
work="$(mktemp -d "${TMPDIR:-/tmp}/opencode-install.XXXXXX")" || die "cannot create temporary directory"

cleanup() {
    if [ "$success" -ne 1 ] && [ -n "$backup" ] && [ -d "$backup" ]; then
        restore_previous
    fi
    [ -n "$work" ] && rm -rf "$work"
}
trap cleanup EXIT

ensure_tool() {
    local cmd="$1" pkg_name="$2"
    have "$cmd" && return 0
    if [ "$is_termux" -eq 1 ] && [ "$no_deps" -eq 0 ] && have pkg; then
        note "Installing $pkg_name (needed by the installer)"
        pkg install -y "$pkg_name" || die "pkg install $pkg_name failed"
        have "$cmd" || die "$cmd is still missing after installing $pkg_name"
        return 0
    fi
    die "$cmd is required; install it with: pkg install $pkg_name"
}

install_runtime_deps() {
    [ "$no_deps" -eq 0 ] || { note "Skipping dependency installation (--no-deps)"; return 0; }
    if [ "$is_termux" -ne 1 ]; then
        note "Not running under the Termux prefix; skipping ripgrep installation"
        have rg || warn "ripgrep (rg) is not installed; OpenCode search may be limited"
        return 0
    fi
    if ! have pkg; then
        warn "pkg is not available; install ripgrep manually: pkg install ripgrep"
        return 0
    fi
    if ! have rg; then
        note "Installing required runtime dependency: ripgrep"
        pkg install -y ripgrep || die "pkg install ripgrep failed"
    fi
    have rg || die "ripgrep is required but rg is still missing"
    note "Runtime dependency OK: $(rg --version | head -n 1)"
}

verify_checksum() {
    local file="$1" sums="$2" base
    base="$(basename "$file")"
    if [ "$no_checksum" -eq 1 ]; then
        warn "Skipping SHA256SUMS verification (--no-checksum)"
        return 0
    fi
    ensure_tool sha256sum coreutils
    [ -f "$sums" ] || die "SHA256SUMS not found next to $base; re-download it or pass --no-checksum"
    grep -qF "  $base" "$sums" || die "$base is not listed in $sums"
    ( cd "$(dirname "$sums")" && grep -F "  $base" "$(basename "$sums")" | sha256sum -c - ) \
        || die "SHA256SUMS verification failed for $base"
    note "SHA256SUMS OK: $base"
}

elf_machine() {
    od -An -tu2 -j18 -N2 "$1" 2>/dev/null | tr -d ' \n'
}

check_aarch64() {
    local file="$1" machine
    [ "$allow_foreign" -eq 1 ] && return 0
    [ -f "$file" ] || die "missing file: $file"
    machine="$(elf_machine "$file")"
    [ "$machine" = "183" ] || die "$(basename "$file") is not aarch64 (ELF e_machine=${machine:-unknown}); use --allow-foreign-arch to inspect it"
}

download() {
    local url="$1" dest="$2"
    ensure_tool curl curl
    note "Downloading $(basename "$dest")"
    curl -fL --retry 3 --connect-timeout 20 -o "$dest" "$url" \
        || die "download failed: $url"
    [ -s "$dest" ] || die "download produced an empty file: $url"
}

api_release() {
    local endpoint="$1" json urls
    ensure_tool curl curl
    note "Checking ${REPO} releases"
    json="$(curl -fsSL --connect-timeout 20 -H 'Accept: application/vnd.github+json' "$endpoint")" \
        || die "GitHub API request failed (rate limit or network?); use --artifact URL or --tag"
    release_tag="$(printf '%s\n' "$json" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$release_tag" ] || die "could not parse tag_name from the GitHub release response"
    urls="$(printf '%s\n' "$json" | grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*"\(https[^"]*\)"/\1/')"
    release_artifact_url="$(printf '%s\n' "$urls" | grep -E 'opencode-[0-9][^/]*android-aarch64\.tar\.xz$' | head -1)"
    [ -n "$release_artifact_url" ] || release_artifact_url="$(printf '%s\n' "$urls" | grep -E 'opencode-[0-9][^/]*android-aarch64\.zip$' | head -1)"
    [ -n "$release_artifact_url" ] || die "release $release_tag has no Android aarch64 tar.xz or zip"
    release_sums_url="$(printf '%s\n' "$urls" | grep -E '/SHA256SUMS$' | head -1)"
    [ -n "$release_sums_url" ] || die "release $release_tag has no SHA256SUMS"
    expected_version="$(printf '%s\n' "$release_tag" | sed -E 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
    case "$expected_version" in
        [0-9]*) ;;
        *) expected_version="" ;;
    esac
    note "Latest release: $release_tag"
}

derive_expected_version() {
    local base
    base="$(basename "$1")"
    case "$base" in
        opencode-*-android-aarch64.tar.xz|opencode-*-android-aarch64.zip)
            expected_version="${base#opencode-}"
            expected_version="${expected_version%%-android-*}"
            ;;
        opencode_*_aarch64.deb)
            expected_version="${base#opencode_}"
            expected_version="${expected_version%%_aarch64.deb}"
            ;;
        opencode-*-1-aarch64.pkg.tar.xz)
            expected_version="${base#opencode-}"
            expected_version="${expected_version%%-1-aarch64.pkg.tar.xz}"
            ;;
    esac
}

installed_tag() {
    local tag_file="$prefix/libexec/opencode/.release-tag"
    if [ -f "$tag_file" ]; then
        head -n 1 "$tag_file"
    fi
}

up_to_date() {
    local installed
    [ -n "$release_tag" ] || return 1
    installed="$(installed_tag)"
    [ -n "$installed" ] && [ "$installed" = "$release_tag" ]
}

confirm_reinstall() {
    if [ "$force" -eq 1 ]; then
        return 0
    fi
    if [ "$assume_yes" -eq 1 ]; then
        note "Already at $release_tag; use --force to reinstall"
        return 1
    fi
    if [ -t 0 ]; then
        printf 'OpenCode %s is already installed. Reinstall it? [y/N] ' "$release_tag"
        read -r answer || answer="n"
        case "$answer" in
            y|Y|yes|YES) return 0 ;;
            *) note "Keeping the existing installation"; return 1 ;;
        esac
    fi
    note "Already at $release_tag; use --force to reinstall"
    return 1
}

extract_artifact() {
    local file="$1" base dest="$work/pkg"
    base="$(basename "$file")"
    mkdir -p "$dest"
    note "Extracting $base"
    case "$base" in
        *.zip)
            ensure_tool unzip unzip
            unzip -q "$file" -d "$dest"
            ;;
        *.deb)
            if have dpkg-deb; then
                dpkg-deb -x "$file" "$dest"
            else
                ensure_tool ar binutils
                mkdir -p "$work/deb"
                ( cd "$work/deb" && ar x "$file" )
                local data_file=""
                for candidate in "$work/deb"/data.tar.*; do
                    if [ -f "$candidate" ]; then data_file="$candidate"; break; fi
                done
                [ -n "$data_file" ] || die "deb has no data.tar.* member"
                tar -xf "$data_file" -C "$dest"
            fi
            ;;
        *.pkg.tar.xz|*.tar.xz)
            ensure_tool xz xz-utils
            ensure_tool tar tar
            tar -xJf "$file" -C "$dest"
            ;;
        *)
            die "unsupported artifact type: $base (expected .zip, .tar.xz, .deb or .pkg.tar.xz)"
            ;;
    esac
}

prepare_package() {
    local file="$1" launcher
    extract_artifact "$file"
    launcher="$(find "$work/pkg" -type f -path '*/bin/opencode' -print -quit 2>/dev/null)"
    [ -n "$launcher" ] || die "package does not contain bin/opencode"
    payload="${launcher%/bin/opencode}"
    [ -x "$launcher" ] || die "packaged launcher is not executable"
    [ -f "$payload/libexec/opencode/opencode.bin" ] || die "package is missing libexec/opencode/opencode.bin"
    [ -d "$payload/lib" ] || die "package is missing lib/"
    [ -f "$payload/lib/libopentui.so" ] || die "package is missing lib/libopentui.so"
    [ -f "$payload/lib/libc++_shared.so" ] || die "package is missing lib/libc++_shared.so"
    check_aarch64 "$payload/libexec/opencode/opencode.bin"
    check_aarch64 "$payload/lib/libopentui.so"
    check_aarch64 "$payload/lib/libc++_shared.so"
    sh -n "$launcher" || die "packaged launcher has a shell syntax error"
    grep -qF 'export BUN_SELF_EXE=' "$launcher" \
        || die "launcher does not export BUN_SELF_EXE; refusing to install a Bun-fallback build"
    grep -aqF 'BUN_SELF_EXE' "$payload/libexec/opencode/opencode.bin" \
        || die "runtime lacks the BUN_SELF_EXE override; refusing to install a Bun-fallback build"
    note "Launcher/runtime BUN_SELF_EXE markers OK"
    [ -n "$expected_version" ] || derive_expected_version "$file"
}

backup_existing() {
    local rel backups_root
    backups_root="$prefix/libexec/opencode/backups"
    backup="$backups_root/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup" || die "cannot create backup directory: $backup"
    for rel in bin/opencode libexec/opencode/opencode.bin libexec/opencode/.release-tag \
               lib/libopentui.so lib/libc++_shared.so lib/libtagfix.so; do
        if [ -e "$prefix/$rel" ]; then
            mkdir -p "$backup/$(dirname "$rel")"
            cp -p "$prefix/$rel" "$backup/$rel" || die "backup failed for $rel"
        fi
    done
    note "Previous installation backed up to $backup"
}

restore_previous() {
    local rel
    [ -n "$backup" ] && [ -d "$backup" ] || return 0
    warn "Restoring the previous installation from $backup"
    for rel in bin/opencode libexec/opencode/opencode.bin libexec/opencode/.release-tag \
               lib/libopentui.so lib/libc++_shared.so lib/libtagfix.so; do
        if [ -e "$backup/$rel" ]; then
            mkdir -p "$prefix/$(dirname "$rel")"
            cp -p "$backup/$rel" "$prefix/$rel"
        else
            rm -f "$prefix/$rel"
        fi
    done
    success=1
}

install_files() {
    local lib
    mkdir -p "$prefix/bin" "$prefix/libexec/opencode" "$prefix/lib"
    install -m 755 "$payload/bin/opencode" "$prefix/bin/opencode"
    install -m 755 "$payload/libexec/opencode/opencode.bin" "$prefix/libexec/opencode/opencode.bin"
    for lib in "$payload"/lib/*.so*; do
        [ -f "$lib" ] || continue
        install -m 644 "$lib" "$prefix/lib/$(basename "$lib")"
    done
    if [ -n "$release_tag" ]; then
        printf '%s\n' "$release_tag" > "$prefix/libexec/opencode/.release-tag"
    elif [ -n "$expected_version" ]; then
        printf '%s\n' "$expected_version" > "$prefix/libexec/opencode/.release-tag"
    fi
    [ -s "$prefix/libexec/opencode/opencode.bin" ] || die "installed runtime is empty"
    [ -f "$prefix/lib/libopentui.so" ] || die "installed libopentui.so is missing"
    [ -f "$prefix/lib/libc++_shared.so" ] || die "installed libc++_shared.so is missing"
    chmod 755 "$prefix/bin/opencode" "$prefix/libexec/opencode/opencode.bin"
    chmod 644 "$prefix/lib"/*.so*
}

ensure_path() {
    local rc block
    case ":$PATH:" in
        *":$prefix/bin:"*) ;;
        *) export PATH="$prefix/bin:$PATH" ;;
    esac
    if [ "$is_termux" -eq 1 ]; then
        block="# >>> opencode-termux >>>
case \":\$PATH:\" in
  *\":$prefix/bin:\"*) ;;
  *) export PATH=\"$prefix/bin:\$PATH\" ;;
esac
# <<< opencode-termux >>>"
        local found=0
        for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
            [ -f "$rc" ] || continue
            found=1
            if ! grep -qF '# >>> opencode-termux >>>' "$rc"; then
                printf '\n%s\n' "$block" >> "$rc"
                note "Added $prefix/bin to PATH in $rc"
            fi
        done
        if [ "$found" -eq 0 ]; then
            printf '%s\n' "$block" >> "$HOME/.profile"
            note "Added $prefix/bin to PATH in $HOME/.profile"
        fi
    fi
}

check_version() {
    local out first status
    [ "$host_arch" = "aarch64" ] || {
        note "Cross-install detected ($host_arch); skipping execution test"
        return 0
    }
    [ -x "$prefix/bin/opencode" ] || die "installed launcher is not executable"
    if have timeout; then
        out="$(timeout 30 "$prefix/bin/opencode" --version 2>&1)" && status=0 || status=$?
    else
        out="$("$prefix/bin/opencode" --version 2>&1)" && status=0 || status=$?
    fi
    first="$(printf '%s\n' "$out" | head -n 1)"
    [ "$status" -eq 0 ] || die "opencode --version failed (exit $status): $out"
    case "$out" in
        *1.2.13*|*"Usage: bun"*|*"Bun v"*)
            local direct_out direct_status
            if have timeout; then
                direct_out="$(LD_LIBRARY_PATH="$prefix/lib" BUN_SELF_EXE="$prefix/libexec/opencode/opencode.bin" timeout 30 "$prefix/libexec/opencode/opencode.bin" --version 2>&1)" && direct_status=0 || direct_status=$?
            else
                direct_out="$(LD_LIBRARY_PATH="$prefix/lib" BUN_SELF_EXE="$prefix/libexec/opencode/opencode.bin" "$prefix/libexec/opencode/opencode.bin" --version 2>&1)" && direct_status=0 || direct_status=$?
            fi
            printf '>>> Direct BUN_SELF_EXE test (exit %s): %s\n' "$direct_status" "${direct_out:-<no output>}" >&2
            die "opencode fell back to Bun ($out); BUN_SELF_EXE is not taking effect"
            ;;
    esac
    [ -n "$first" ] || die "opencode --version produced no output"
    if [ -n "$expected_version" ]; then
        case "$first" in
            "$expected_version"*) ;;
            *) die "opencode --version reported '$first', expected $expected_version" ;;
        esac
    fi
    note "opencode --version OK: $first"
}

prune_backups() {
    local backups_root="$prefix/libexec/opencode/backups" d listing count=0
    [ "$keep_backup" -eq 1 ] && return 0
    [ -d "$backups_root" ] || return 0
    if listing="$(ls -1dt "$backups_root"/* 2>/dev/null)"; then
        for d in $listing; do
            count=$((count + 1))
            if [ "$count" -gt 3 ]; then
                rm -rf "$d"
            fi
        done
    fi
}

install_flow() {
    local source="$artifact"
    if [ -z "$source" ]; then
        if [ "$mode" = "tag" ]; then
            [ -n "$release_tag" ] || die "--tag needs a release tag"
            api_release "${API_ROOT}/releases/tags/${release_tag}"
        else
            api_release "${API_ROOT}/releases/latest"
        fi
        if up_to_date && ! confirm_reinstall; then
            return 0
        fi
        source="$work/$(basename "$release_artifact_url")"
        download "$release_artifact_url" "$source"
        download "$release_sums_url" "$work/SHA256SUMS"
        verify_checksum "$source" "$work/SHA256SUMS"
    else
        case "$source" in
            http://*|https://*)
                local name source_url
                source_url="$source"
                name="${source_url##*/}"
                name="${name%%\?*}"
                [ -n "$name" ] || name="opencode-package"
                download "$source_url" "$work/$name"
                source="$work/$name"
                if [ -n "$release_sums_url" ]; then
                    download "$release_sums_url" "$work/SHA256SUMS"
                elif curl -fsSL --connect-timeout 15 -o "$work/SHA256SUMS" "${source_url%/*}/SHA256SUMS" 2>/dev/null; then
                    :
                else
                    rm -f "$work/SHA256SUMS"
                fi
                verify_checksum "$source" "$work/SHA256SUMS"
                ;;
            *)
                [ -f "$source" ] || die "artifact not found: $source (download it first, or pass an https:// URL)"
                if [ -f "$(dirname "$source")/SHA256SUMS" ]; then
                    verify_checksum "$source" "$(dirname "$source")/SHA256SUMS"
                else
                    verify_checksum "$source" ""
                fi
                ;;
        esac
    fi

    [ -f "$source" ] || die "artifact not found: $source"
    prepare_package "$source"
    install_runtime_deps
    backup_existing
    install_files
    check_version
    ensure_path
    success=1
    prune_backups
    note "Installed OpenCode ${expected_version:-$release_tag} into $prefix"
    printf '\nRun it with:\n  opencode\n\n'
    if [ "$is_termux" -eq 1 ]; then
        printf 'A new shell will pick up PATH automatically. For this shell:\n  export PATH="%s/bin:$PATH"\n\n' "$prefix"
    fi
}

check_install() {
    local version="" tag="" rc=0
    if [ ! -x "$prefix/bin/opencode" ]; then
        printf 'OpenCode is not installed in %s\n' "$prefix"
        return 1
    fi
    tag="$(installed_tag)"
    printf 'prefix:       %s\n' "$prefix"
    printf 'launcher:     %s\n' "$prefix/bin/opencode"
    printf 'runtime:      %s\n' "$prefix/libexec/opencode/opencode.bin"
    printf 'release tag:  %s\n' "${tag:-unknown}"
    if [ "$host_arch" = "aarch64" ] && [ -x "$prefix/bin/opencode" ]; then
        version="$("$prefix/bin/opencode" --version 2>&1)" || rc=$?
        printf 'app version:  %s\n' "${version:-<failed>}"
    elif [ "$host_arch" != "aarch64" ]; then
        printf 'app version:  not executed on %s (cross-install)\n' "$host_arch"
    fi
    grep -qF 'export BUN_SELF_EXE=' "$prefix/bin/opencode" \
        && printf 'BUN_SELF_EXE launcher marker: OK\n' \
        || { printf 'BUN_SELF_EXE launcher marker: MISSING\n' >&2; rc=1; }
    grep -aqF 'BUN_SELF_EXE' "$prefix/libexec/opencode/opencode.bin" \
        && printf 'BUN_SELF_EXE runtime marker:   OK\n' \
        || { printf 'BUN_SELF_EXE runtime marker:   MISSING\n' >&2; rc=1; }
    [ -f "$prefix/lib/libopentui.so" ] && printf 'libopentui.so:  OK\n' || { printf 'libopentui.so:  MISSING\n' >&2; rc=1; }
    [ -f "$prefix/lib/libc++_shared.so" ] && printf 'libc++_shared:  OK\n' || { printf 'libc++_shared:  MISSING\n' >&2; rc=1; }
    if have rg; then printf 'ripgrep:        OK (%s)\n' "$(rg --version | head -n 1)"; else printf 'ripgrep:        MISSING (pkg install ripgrep)\n' >&2; rc=1; fi
    case "$version" in
        *1.2.13*|*"Usage: bun"*|*"Bun v"*) printf 'ERROR: opencode is falling back to Bun\n' >&2; rc=1 ;;
    esac
    return "$rc"
}

uninstall_flow() {
    local rel
    if [ ! -e "$prefix/bin/opencode" ] && [ ! -e "$prefix/libexec/opencode/opencode.bin" ]; then
        note "OpenCode is not installed in $prefix"
        return 0
    fi
    if [ "$assume_yes" -ne 1 ]; then
        printf 'Remove OpenCode from %s? Configuration and backups are kept. [y/N] ' "$prefix"
        read -r answer || answer="n"
        case "$answer" in
            y|Y|yes|YES) ;;
            *) note "Uninstall cancelled"; return 0 ;;
        esac
    fi
    for rel in bin/opencode libexec/opencode/opencode.bin libexec/opencode/.release-tag \
               lib/libopentui.so lib/libc++_shared.so lib/libtagfix.so; do
        rm -f "$prefix/$rel"
    done
    note "Removed OpenCode binaries from $prefix"
    note "Configuration and backups were kept under $prefix/libexec/opencode/backups"
}

menu() {
    local choice
    printf '\n=============================================\n'
    printf ' OpenCode for Termux installer %s\n' "$INSTALLER_VERSION"
    printf ' Prefix: %s\n' "$prefix"
    printf '=============================================\n'
    if [ -x "$prefix/bin/opencode" ]; then
        printf ' Installed: %s\n' "$("$prefix/bin/opencode" --version 2>&1 | head -n 1)"
    else
        printf ' Installed: not installed\n'
    fi
    printf '\n'
    printf ' 1) Install or update to the latest release\n'
    printf ' 2) Install a local package or URL\n'
    printf ' 3) Check the current installation\n'
    printf ' 4) Uninstall (keep configuration)\n'
    printf ' 5) Quit\n'
    printf '\nChoice [1]: '
    read -r choice || exit 0
    case "${choice:-1}" in
        1) mode="latest"; artifact=""; install_flow ;;
        2) printf 'Path or https URL: '; read -r artifact || exit 0; [ -n "$artifact" ] || die "no artifact given"; install_flow ;;
        3) check_install ;;
        4) uninstall_flow ;;
        5) exit 0 ;;
        *) warn "invalid choice"; return 0 ;;
    esac
}

case "$mode" in
    check)
        check_install
        exit $?
        ;;
    uninstall)
        uninstall_flow
        exit 0
        ;;
esac

if [ -n "$artifact" ]; then
    install_flow
elif [ "$mode" = "latest" ] || [ "$mode" = "tag" ]; then
    install_flow
elif [ "$assume_yes" -eq 1 ]; then
    mode="latest"
    install_flow
elif [ "$force_interactive" -eq 1 ] || [ -t 0 ]; then
    while :; do
        menu
        break
    done
else
    usage
    exit 1
fi
