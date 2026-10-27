#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ICU_VERSION_UNDERSCORE="${ICU_VERSION//./_}"
ICU_TARBALL="icu4c-${ICU_VERSION_UNDERSCORE}-src.tgz"
ICU_URL="https://github.com/unicode-org/icu/releases/download/release-${ICU_VERSION_UNDERSCORE//_/-}/${ICU_TARBALL}"

# Use absolute paths based on REPO_ROOT to avoid relative path issues with WORK_DIR
ICU_HOST_BUILD="${REPO_ROOT}/${WORK_DIR}/icu-host-build"
ICU_ANDROID_BUILD="${REPO_ROOT}/${WORK_DIR}/icu-android-build"
ICU_SRC_ABS="${REPO_ROOT}/${WORK_DIR}/icu-src"
DEPS_PREFIX_ABS="${REPO_ROOT}/${DEPS_PREFIX}"

echo "=== Building ICU ${ICU_VERSION} for Android aarch64 ==="

if [ ! -d "${ICU_SRC_ABS}/source" ]; then
    echo ">>> Downloading ICU ${ICU_VERSION}..."
    mkdir -p "${ICU_SRC_ABS}"
    curl -L -o "${REPO_ROOT}/${WORK_DIR}/${ICU_TARBALL}" "$ICU_URL"
    tar xf "${REPO_ROOT}/${WORK_DIR}/${ICU_TARBALL}" -C "${ICU_SRC_ABS}" --strip-components=1
    rm -f "${REPO_ROOT}/${WORK_DIR}/${ICU_TARBALL}"
fi

if [ ! -f "${ICU_HOST_BUILD}/bin/icupkg" ]; then
    echo ">>> Building host ICU tools..."
    mkdir -p "${ICU_HOST_BUILD}"
    (cd "${ICU_HOST_BUILD}" && \
        "${ICU_SRC_ABS}/source/configure" --prefix="$(pwd)/install" && \
        make -j"${JOBS}" && \
        make install)
else
    echo ">>> Host ICU tools already built"
fi

if [ ! -f "${DEPS_PREFIX_ABS}/lib/libicuuc.a" ]; then
    echo ">>> Cross-compiling ICU for Android aarch64..."
    mkdir -p "${ICU_ANDROID_BUILD}"
    (cd "${ICU_ANDROID_BUILD}" && \
        "${ICU_SRC_ABS}/source/configure" \
            --host=aarch64-linux-android \
            --with-cross-build="${ICU_HOST_BUILD}" \
            --prefix="${DEPS_PREFIX}" \
            CC="$ANDROID_CC" \
            CXX="$ANDROID_CXX" \
            AR="$ANDROID_AR" \
            RANLIB="$ANDROID_RANLIB" \
            CFLAGS="-fPIC -DU_STATIC_IMPLEMENTATION=1" \
            CXXFLAGS="-fPIC -DU_STATIC_IMPLEMENTATION=1" \
            --enable-static --disable-shared && \
        make -j"${JOBS}" && \
        make install)
else
    echo ">>> ICU already built at ${DEPS_PREFIX}"
fi

echo ""
echo "=== ICU ${ICU_VERSION} build complete ==="
echo "Libraries:"
ls -la "${DEPS_PREFIX_ABS}/lib/libicu"*.a 2>/dev/null || echo "None yet"
echo "Headers: ${DEPS_PREFIX_ABS}/include/unicode/"
