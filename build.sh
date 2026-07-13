#!/usr/bin/env bash
# Copyright (c) 2023-2026 Christiaan (chris@boreddev.nl)
# This software is released under the GNU General Public License v3.0. See LICENSE file for details.
# This header needs to maintain in any file it is present in, as per the GPL license terms.
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
BINUTILS_VERSION="2.42"
GCC_VERSION="12.2.0"
TARGET_BUILD="x86_64-boredos"
TARGET_NAME="x86_64-boredos"

SYSROOT="${1:-/opt/boredos-toolchain}"
PREFIX="/usr/"
JOBS=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)

AUTOCONF="${SYSROOT}${PREFIX}/bin/autoconf"
AUTOMAKE="${SYSROOT}${PREFIX}/bin/automake"
AUTOM4TE="${SYSROOT}${PREFIX}/bin/autom4te"

BINUTILS_TAR="binutils-${BINUTILS_VERSION}.tar.xz"
GCC_TAR="gcc-${GCC_VERSION}.tar.xz"
BINUTILS_URL="https://ftp.gnu.org/gnu/binutils/${BINUTILS_TAR}"
GCC_URL="https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/${GCC_TAR}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo "==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" &>/dev/null || die "Required tool '$1' not found"; }

MAKE="make"
if command -v gmake &>/dev/null; then
    MAKE="gmake"
fi

need curl; need "${MAKE}"; need tar; need strip; need meson; need ninja; need patch
MLIBC_SRC=""
CLEANUP_MLIBC=false
if [[ -d "${REPO_ROOT}/usr/mlibc" ]]; then
    log "Found local mlibc at ${REPO_ROOT}/usr/mlibc"
    MLIBC_SRC="${REPO_ROOT}/usr/mlibc"
else
    MLIBC_SRC="${SCRIPT_DIR}/mlibc-src"
    if [[ ! -d "${MLIBC_SRC}" ]]; then
        log "Local mlibc not found. Cloning from https://github.com/BoredOS/mlibc..."
        need git
        git clone --depth 1 https://github.com/BoredOS/mlibc.git "${MLIBC_SRC}"
        CLEANUP_MLIBC=true
    else
        log "Using previously cloned mlibc at ${MLIBC_SRC}"
    fi
fi

CROSS_FILE=""
CLEANUP_CROSS_FILE=false
if [[ -f "${REPO_ROOT}/tools/cross_file.txt" ]]; then
    log "Using local cross_file.txt from ${REPO_ROOT}/tools/cross_file.txt"
    CROSS_FILE="${REPO_ROOT}/tools/cross_file.txt"
else
    CROSS_FILE="${SCRIPT_DIR}/cross_file_dynamic.txt"
    log "Generating dynamic cross file at ${CROSS_FILE}..."
    cat << 'EOF' > "${CROSS_FILE}"
[binaries]
c = 'x86_64-boredos-gcc'
cpp = 'x86_64-boredos-g++'
ar = 'x86_64-boredos-ar'
strip = 'x86_64-boredos-strip'

[host_machine]
system = 'boredos'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[properties]
c_args = ['-D_GNU_SOURCE', '-D_DEFAULT_SOURCE']
cpp_args = ['-D_GNU_SOURCE', '-D_DEFAULT_SOURCE']
EOF
    CLEANUP_CROSS_FILE=true
fi

patch_binutils() {
    log "Patching binutils..."
    patch -d "binutils-${BINUTILS_VERSION}" -p1 < "${SCRIPT_DIR}/patches/binutils-${BINUTILS_VERSION}.patch"
    log "Regenerating ld Makefile..."
    pushd "binutils-${BINUTILS_VERSION}/ld"
    echo ${AUTOMAKE}
    /opt/boredos-toolchain/usr/bin/automake
    popd
}

patch_gcc() {
    log "Patching gcc..."
    patch -d "gcc-${GCC_VERSION}" -p1 < "${SCRIPT_DIR}/patches/gcc-${GCC_VERSION}.patch"
    patch -d "gcc-${GCC_VERSION}" -p1 < "${SCRIPT_DIR}/patches/gcc-16.patch"
    log "Regenerating libstdc++ configure script..."
    (cd "gcc-${GCC_VERSION}/libstdc++-v3" && ${AUTOCONF})
}

log "Building ${TARGET_NAME} Stage 2 cross-toolchain → ${PREFIX}"
log "  binutils ${BINUTILS_VERSION}, gcc ${GCC_VERSION}"
log "  Using ${JOBS} parallel jobs"

mkdir -p "${SYSROOT}${PREFIX}"
mkdir -p "${SYSROOT}${PREFIX}/bin/"
mkdir -p "${SYSROOT}${PREFIX}/include/"
mkdir -p "${SYSROOT}${PREFIX}/lib/"
export PATH="${SYSROOT}${PREFIX}/bin/:${PATH}"

# ── Detect host GMP/MPFR/MPC ────────────────────────────────────────────────
EXTRA_CONFIGURE=""
if command -v brew &>/dev/null; then
    BREW_PREFIX=$(brew --prefix)
    log "Using Homebrew GMP/MPFR/MPC at ${BREW_PREFIX}"
    EXTRA_CONFIGURE="--with-gmp=${BREW_PREFIX} --with-mpfr=${BREW_PREFIX} --with-mpc=${BREW_PREFIX}"
    export CPPFLAGS="-I${BREW_PREFIX}/include"
    export LDFLAGS="-L${BREW_PREFIX}/lib"
elif pkg-config --exists gmp mpfr mpc 2>/dev/null; then
    log "Using system GMP/MPFR/MPC via pkg-config"
elif [[ -d /usr/local/lib ]]; then
    log "Using /usr/local GMP/MPFR/MPC"
    EXTRA_CONFIGURE="--with-gmp=/usr/local --with-mpfr=/usr/local --with-mpc=/usr/local"
fi

# First build the pre-requisite versions of autoconf and automake
curl -fsSL --retry 3 "https://ftpmirror.gnu.org/gnu/autoconf/autoconf-2.69.tar.gz" -o "autoconf-2.69.tar.gz"
tar -xf autoconf-2.69.tar.gz
rm autoconf-2.69.tar.gz

pushd autoconf-2.69
./configure --prefix=$PREFIX
make -j${JOBS}
make DESTDIR=$SYSROOT install
popd

curl -fsSL --retry 3 "https://ftpmirror.gnu.org/gnu/automake/automake-1.15.1.tar.gz" -o "automake-1.15.1.tar.gz"
tar -xf automake-1.15.1.tar.gz
rm automake-1.15.1.tar.gz

pushd automake-1.15.1
./configure --prefix=$PREFIX
make -j${JOBS}
make DESTDIR=$SYSROOT install
popd

which autoconf
which automake

# ── Build binutils ────────────────────────────────────────────────────────────
log "Downloading binutils ${BINUTILS_VERSION}..."
curl -fsSL --retry 3 "${BINUTILS_URL}" -o "${BINUTILS_TAR}"

rm -rf binutils-${BINUTILS_VERSION} || true

log "Extracting binutils..."
tar -xf "${BINUTILS_TAR}"
rm -f "${BINUTILS_TAR}"

patch_binutils

log "Configuring binutils..."
mkdir -p build-binutils
(cd build-binutils && \
    "../binutils-${BINUTILS_VERSION}/configure" \
        --target="${TARGET_BUILD}" \
        --prefix="${PREFIX}" \
        --with-sysroot="${SYSROOT}" \
        --disable-nls \
        --disable-werror \
        --disable-multilib \
        --with-system-zlib \
	--disable-bootstrap \
        ${EXTRA_CONFIGURE})

log "Building binutils (${JOBS} jobs)..."
"${MAKE}" -C build-binutils -j"${JOBS}" MAKEINFO=true

log "Installing binutils..."
"${MAKE}" -C build-binutils DESTDIR=${SYSROOT} install MAKEINFO=true

# ── Install mlibc Headers (Breaks Bootstrap Cycle) ───────────────────────────
log "Installing mlibc headers to sysroot..."
mkdir -p build-mlibc-headers
(cd build-mlibc-headers && \
   meson setup \
       --cross-file "${CROSS_FILE}" \
       --prefix="${PREFIX}" \
       -Ddefault_library=static \
       -Dheaders_only=true \
       -Dposix_option=enabled \
       -Dlinux_option=disabled \
       -Dglibc_option=disabled \
       -Dbsd_option=disabled \
       "${MLIBC_SRC}")

log "Running header installation..."
DESTDIR="${SYSROOT}" ninja -C build-mlibc-headers install

# ── Build GCC Stage 1 (Freestanding / Bootstrap) ─────────────────────────────────
log "Downloading gcc ${GCC_VERSION}..."
curl -fsSL --retry 3 "${GCC_URL}" -o "${GCC_TAR}"

log "Extracting gcc..."
tar -xf "${GCC_TAR}"
rm -f "${GCC_TAR}"

patch_gcc

log "Configuring gcc Stage 1 (Freestanding)..."
mkdir -p build-gcc
(cd build-gcc && \
    "../gcc-${GCC_VERSION}/configure" \
        --target="${TARGET_BUILD}" \
        --prefix="${PREFIX}" \
        --with-sysroot="${SYSROOT}" \
        --enable-languages=c,c++ \
        --disable-multilib \
        --disable-werror \
        --with-system-zlib \
        ${EXTRA_CONFIGURE})

log "Building gcc Stage 1 (${JOBS} jobs)..."
"${MAKE}" -C build-gcc -j"${JOBS}" all-gcc all-target-libgcc MAKEINFO=true

log "Installing gcc Stage 1..."
"${MAKE}" -C build-gcc DESTDIR=${SYSROOT} install-strip-gcc install-target-libgcc MAKEINFO=true

log "Configuring full mlibc..."
mkdir -p build-mlibc
(cd build-mlibc && \
    meson setup \
        --cross-file "${CROSS_FILE}" \
        --prefix="${PREFIX}" \
        -Ddefault_library=static \
        -Dheaders_only=false \
        -Dposix_option=enabled \
        -Dlinux_option=disabled \
        -Dglibc_option=disabled \
        -Dbsd_option=disabled \
        "${MLIBC_SRC}")

log "Building and installing mlibc binaries to sysroot..."
DESTDIR="${SYSROOT}" ninja -C build-mlibc install

# ── Build GCC Stage 2 (Hosted) ────────────────────────────────────────────────
log "Building gcc Stage 2 (Hosted, ${JOBS} jobs)..."
"${MAKE}" -C build-gcc -j"${JOBS}" all-target-libstdc++-v3 MAKEINFO=true

log "Installing gcc Stage 2..."
"${MAKE}" -C build-gcc -j"${JOBS}" install-target-libstdc++-v3 MAKEINFO=true

log "Cleaning up build directories..."
rm -rf \
    build-binutils "binutils-${BINUTILS_VERSION}" \
    build-mlibc-headers \
    build-gcc "gcc-${GCC_VERSION}" \
    build-mlibc
if [[ "${CLEANUP_MLIBC}" == "true" ]]; then
    log "Removing cloned mlibc..."
    rm -rf "${MLIBC_SRC}"
fi
if [[ "${CLEANUP_CROSS_FILE}" == "true" ]]; then
    log "Removing dynamic cross file..."
    rm -f "${CROSS_FILE}"
fi

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

HOST_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
HOST_ARCH=$(uname -m)
TARBALL="boredos-toolchain-${HOST_ARCH}-${HOST_OS}.tar.xz"

log "Packaging ${TARBALL}..."
tar -cJf "${TARBALL}" -C "$(dirname "${PREFIX}")" "$(basename "${PREFIX}")"

TARBALL_SIZE=$(du -sh "${TARBALL}" | cut -f1)
log "Done! ${TARBALL} (${TARBALL_SIZE})"
log "Install with: bash install.sh"
