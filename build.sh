#!/usr/bin/env bash
# Copyright (c) 2026 BoredOS contributors
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
BINUTILS_VERSION="2.42"
GCC_VERSION="14.2.0"
TARGET_BUILD="x86_64-elf"
TARGET_NAME="x86_64-boredos"

PREFIX="${1:-/opt/boredos-toolchain}"
JOBS=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)

BINUTILS_TAR="binutils-${BINUTILS_VERSION}.tar.xz"
GCC_TAR="gcc-${GCC_VERSION}.tar.xz"
BINUTILS_URL="https://ftp.gnu.org/gnu/binutils/${BINUTILS_TAR}"
GCC_URL="https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/${GCC_TAR}"

# ── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo "==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" &>/dev/null || die "Required tool '$1' not found"; }

MAKE="make"
if command -v gmake &>/dev/null; then
    MAKE="gmake"
fi

need curl; need "${MAKE}"; need tar; need strip

log "Building ${TARGET_NAME} cross-toolchain → ${PREFIX}"
log "  binutils ${BINUTILS_VERSION}, gcc ${GCC_VERSION}"
log "  Using ${JOBS} parallel jobs"

mkdir -p "${PREFIX}"
export PATH="${PREFIX}/bin:${PATH}"

# ── Detect host GMP/MPFR/MPC ────────────────────────────────────────────────
EXTRA_CONFIGURE=""
if command -v brew &>/dev/null; then
    # macOS: use brew --prefix to get the correct path on both Intel and arm64
    BREW_PREFIX=$(brew --prefix)
    log "Using Homebrew GMP/MPFR/MPC at ${BREW_PREFIX}"
    EXTRA_CONFIGURE="--with-gmp=${BREW_PREFIX} --with-mpfr=${BREW_PREFIX} --with-mpc=${BREW_PREFIX}"
    # GCC configure needs headers on CPPFLAGS and libs on LDFLAGS
    export CPPFLAGS="-I${BREW_PREFIX}/include"
    export LDFLAGS="-L${BREW_PREFIX}/lib"
elif pkg-config --exists gmp mpfr mpc 2>/dev/null; then
    log "Using system GMP/MPFR/MPC via pkg-config"
elif [[ -d /usr/local/lib ]]; then
    log "Using /usr/local GMP/MPFR/MPC"
    EXTRA_CONFIGURE="--with-gmp=/usr/local --with-mpfr=/usr/local --with-mpc=/usr/local"
fi

# ── Build binutils ────────────────────────────────────────────────────────────
log "Downloading binutils ${BINUTILS_VERSION}..."
curl -fsSL --retry 3 "${BINUTILS_URL}" -o "${BINUTILS_TAR}"

log "Extracting binutils..."
tar -xf "${BINUTILS_TAR}"
rm -f "${BINUTILS_TAR}"                  # free tarball immediately

log "Configuring binutils..."
mkdir -p build-binutils
(cd build-binutils && \
    "../binutils-${BINUTILS_VERSION}/configure" \
        --target="${TARGET_BUILD}" \
        --prefix="${PREFIX}" \
        --with-sysroot \
        --disable-nls \
        --disable-werror \
        --disable-multilib \
        ${EXTRA_CONFIGURE})

log "Building binutils (${JOBS} jobs)..."
"${MAKE}" -C build-binutils -j"${JOBS}"

log "Installing binutils..."
"${MAKE}" -C build-binutils install

log "Cleaning binutils build artifacts..."
rm -rf build-binutils "binutils-${BINUTILS_VERSION}"

# ── Build GCC ─────────────────────────────────────────────────────────────────
log "Downloading gcc ${GCC_VERSION}..."
curl -fsSL --retry 3 "${GCC_URL}" -o "${GCC_TAR}"

log "Extracting gcc..."
tar -xf "${GCC_TAR}"
rm -f "${GCC_TAR}"

log "Configuring gcc..."
mkdir -p build-gcc
(cd build-gcc && \
    "../gcc-${GCC_VERSION}/configure" \
        --target="${TARGET_BUILD}" \
        --prefix="${PREFIX}" \
        --enable-languages=c,c++ \
        --without-headers \
        --disable-nls \
        --disable-multilib \
        --disable-bootstrap \
        --disable-libssp \
        --disable-libquadmath \
        --disable-libgomp \
        --disable-libatomic \
        --disable-libstdcxx \
        ${EXTRA_CONFIGURE})

log "Building gcc (${JOBS} jobs)..."
"${MAKE}" -C build-gcc -j"${JOBS}" all-gcc all-target-libgcc

log "Installing gcc..."
"${MAKE}" -C build-gcc install-gcc install-target-libgcc

log "Cleaning gcc build artifacts..."
rm -rf build-gcc "gcc-${GCC_VERSION}"

log "Stripping executables..."
find "${PREFIX}/bin" -type f -executable \
    -exec strip --strip-unneeded {} + 2>/dev/null || true

log "Stripping static libraries..."
find "${PREFIX}/lib" -name "*.a" -type f \
    -exec strip --strip-debug {} + 2>/dev/null || true

log "Removing docs, locales, and unused files..."
rm -rf \
    "${PREFIX}/share/man" \
    "${PREFIX}/share/info" \
    "${PREFIX}/share/locale" \
    "${PREFIX}/share/gcc-"*/python \
    "${PREFIX}/share/gcc-"*/python3
find "${PREFIX}" -name "*.la" -delete   

# ── Symlinks for the x86_64-boredos-* names ──────────────────────────────────
log "Installing x86_64-boredos-* symlinks..."
for bin in "${PREFIX}/bin/${TARGET_BUILD}-"*; do
    tool="${bin##*${TARGET_BUILD}-}"
    ln -sf "${PREFIX}/bin/${TARGET_BUILD}-${tool}" \
           "${PREFIX}/bin/${TARGET_NAME}-${tool}"
done

# ── Package ───────────────────────────────────────────────────────────────────
HOST_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
HOST_ARCH=$(uname -m)
TARBALL="boredos-toolchain-${HOST_ARCH}-${HOST_OS}.tar.xz"

log "Packaging ${TARBALL}..."
tar -cJf "${TARBALL}" -C "$(dirname "${PREFIX}")" "$(basename "${PREFIX}")"

TARBALL_SIZE=$(du -sh "${TARBALL}" | cut -f1)
log "Done! ${TARBALL} (${TARBALL_SIZE})"
log "Install with: bash install.sh"
