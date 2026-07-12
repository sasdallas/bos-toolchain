# Copyright (c) 2023-2026 Christiaan (chris@boreddev.nl)
# This software is released under the GNU General Public License v3.0. See LICENSE file for details.
# This header needs to maintain in any file it is present in, as per the GPL license terms.
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
BINUTILS_VERSION="2.42"
GCC_VERSION="14.2.0"
TARGET_BUILD="x86_64-boredos"
TARGET_NAME="x86_64-boredos"

PREFIX="${1:-/opt/boredos-toolchain}"
JOBS=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)

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

need curl; need "${MAKE}"; need tar; need strip; need meson; need ninja
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
    python3 -c '
import sys

def replace_or_die(filename, search, replace):
    with open(filename, "r") as f:
        content = f.read()
    if search not in content:
        print(f"ERROR: Substring not found in {filename}:", repr(search), file=sys.stderr)
        sys.exit(1)
    with open(filename, "w") as f:
        f.write(content.replace(search, replace))

# patch config.sub
replace_or_die("binutils-2.42/config.sub", "| mlibc* |", "| mlibc* | boredos* |")

# patch bfd/config.bfd
replace_or_die("binutils-2.42/bfd/config.bfd",
               "x86_64-*-elf* | x86_64-*-rtems* | x86_64-*-fuchsia | x86_64-*-genode*)",
               "x86_64-*-elf* | x86_64-*-rtems* | x86_64-*-fuchsia | x86_64-*-genode* | x86_64-*-boredos*)")

# patch gas/configure.tgt
replace_or_die("binutils-2.42/gas/configure.tgt",
               "i386-*-elf*)",
               "i386-*-elf* | i386-*-boredos*)")

# patch ld/configure.tgt
replace_or_die("binutils-2.42/ld/configure.tgt",
               "x86_64-*-elf* | x86_64-*-rtems* | x86_64-*-fuchsia* | x86_64-*-genode*)",
               "x86_64-*-elf* | x86_64-*-rtems* | x86_64-*-fuchsia* | x86_64-*-genode* | x86_64-*-boredos*)")
'
}

patch_gcc() {
    log "Patching gcc..."
    python3 -c '
import sys

def replace_or_die(filename, search, replace):
    with open(filename, "r") as f:
        content = f.read()
    if search not in content:
        print(f"ERROR: Substring not found in {filename}:", repr(search), file=sys.stderr)
        sys.exit(1)
    with open(filename, "w") as f:
        f.write(content.replace(search, replace))

# patch config.sub
replace_or_die("gcc-14.2.0/config.sub", "| fiwix* )", "| fiwix* | boredos* )")

# patch gcc/config.gcc (common parts)
with open("gcc-14.2.0/gcc/config.gcc", "r") as f:
    content = f.read()

common_search = """# Common parts for widely ported systems.
case ${target} in
*-*-linux* | *-*-uclinux*)"""

common_replace = """# Common parts for widely ported systems.
case ${target} in
*-*-boredos*)
  gas=yes
  gnu_ld=yes
  default_use_cxa_atexit=yes
  use_gcc_stdint=wrap
  ;;
*-*-linux* | *-*-uclinux*)"""

if common_search in content:
    content = content.replace(common_search, common_replace)
else:
    search_fallback = "case ${target} in\n*-*-linux*"
    if search_fallback not in content:
         print("ERROR: Could not find target case block in config.gcc", file=sys.stderr)
         sys.exit(1)
    content = content.replace(search_fallback, "case ${target} in\n*-*-boredos*)\n  gas=yes\n  gnu_ld=yes\n  default_use_cxa_atexit=yes\n  use_gcc_stdint=wrap\n  ;;\n*-*-linux*")

# patch gcc/config.gcc (x86_64-*-elf* target)
target_block = """x86_64-*-elf*)
	tm_file="${tm_file} i386/unix.h i386/att.h dbxelf.h elfos.h newlib-stdint.h i386/i386elf.h i386/x86-64.h"
	tmake_file="${tmake_file} i386/t-i386elf"
	;;"""

boredos_target = """x86_64-*-boredos*)
	tm_file="${tm_file} i386/unix.h i386/att.h dbxelf.h elfos.h glibc-stdint.h i386/x86-64.h boredos.h"
	tmake_file="${tmake_file} i386/t-linux64"
	;;"""

if target_block in content:
    content = content.replace(target_block, target_block + "\n" + boredos_target)
else:
    import re
    pattern = r"(x86_64-\*-elf\*\).*?;;)"
    content, count = re.subn(pattern, r"\1\n" + boredos_target, content, flags=re.DOTALL)
    if count == 0:
        print("ERROR: Could not find x86_64-*-elf* block in config.gcc", file=sys.stderr)
        sys.exit(1)

with open("gcc-14.2.0/gcc/config.gcc", "w") as f:
    f.write(content)

# patch libstdc++-v3/configure.host
replace_or_die("gcc-14.2.0/libstdc++-v3/configure.host",
               "\ncase \"${host_os}\" in",
               "\ncase \"${host_os}\" in\n  boredos*)\n    os_include_dir=\"os/generic\"\n    ;;")
'
}

log "Building ${TARGET_NAME} Stage 2 cross-toolchain → ${PREFIX}"
log "  binutils ${BINUTILS_VERSION}, gcc ${GCC_VERSION}"
log "  Using ${JOBS} parallel jobs"

mkdir -p "${PREFIX}"
export PATH="${PREFIX}/bin:${PATH}"

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

# ── Build binutils ────────────────────────────────────────────────────────────
log "Downloading binutils ${BINUTILS_VERSION}..."
curl -fsSL --retry 3 "${BINUTILS_URL}" -o "${BINUTILS_TAR}"

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
        --with-sysroot="${PREFIX}/${TARGET_NAME}" \
        --disable-nls \
        --disable-werror \
        --disable-multilib \
        ${EXTRA_CONFIGURE})

log "Building binutils (${JOBS} jobs)..."
"${MAKE}" -C build-binutils -j"${JOBS}"

log "Installing binutils..."
"${MAKE}" -C build-binutils install

# ── Build GCC Stage 1 (Freestanding / Bootstrap) ─────────────────────────────────
log "Downloading gcc ${GCC_VERSION}..."
curl -fsSL --retry 3 "${GCC_URL}" -o "${GCC_TAR}"

log "Extracting gcc..."
tar -xf "${GCC_TAR}"
rm -f "${GCC_TAR}"

patch_gcc

cat << 'EOF' > "gcc-${GCC_VERSION}/gcc/config/boredos.h"
#undef TARGET_BOREDOS
#define TARGET_BOREDOS 1

#undef TARGET_OS_CPP_BUILTINS
#define TARGET_OS_CPP_BUILTINS()      \
  do {                                \
    builtin_define ("__boredos__");   \
    builtin_define ("__unix__");      \
    builtin_assert ("system=boredos");\
    builtin_assert ("system=unix");   \
  } while (0)

#undef STARTFILE_SPEC
#define STARTFILE_SPEC \
  "%{!shared: %{static:crt0.o%s; :crt1.o%s}} crti.o%s \
   %{static:crtbeginT.o%s; shared|pie:crtbeginS.o%s; :crtbegin.o%s}"

#undef ENDFILE_SPEC
#define ENDFILE_SPEC \
  "%{static:crtend.o%s; shared|pie:crtendS.o%s; :crtend.o%s} crtn.o%s"

#undef LIB_SPEC
#define LIB_SPEC "-lc"

#undef DYNAMIC_LINKER
#define DYNAMIC_LINKER "/lib/ld.so"

#undef LINK_SPEC
#define LINK_SPEC "%{shared:-shared} \
  %{!shared: %{!static: %{rdynamic:-export-dynamic} \
  -dynamic-linker " DYNAMIC_LINKER "} %{static:-static}}"

#define NO_IMPLICIT_EXTERN_C 1
EOF

log "Configuring gcc Stage 1 (Freestanding)..."
mkdir -p build-gcc-stage1
(cd build-gcc-stage1 && \
    "../gcc-${GCC_VERSION}/configure" \
        --target="${TARGET_BUILD}" \
        --prefix="${PREFIX}" \
        --with-sysroot="${PREFIX}/${TARGET_NAME}" \
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

log "Building gcc Stage 1 (${JOBS} jobs)..."
"${MAKE}" -C build-gcc-stage1 -j"${JOBS}" all-gcc all-target-libgcc

log "Installing gcc Stage 1..."
"${MAKE}" -C build-gcc-stage1 install-gcc install-target-libgcc

# ── Build and install mlibc to sysroot ──────────────────────────────────────────
log "Configuring mlibc..."
mkdir -p build-mlibc
(cd build-mlibc && \
    meson setup \
        --cross-file "${CROSS_FILE}" \
        --prefix="${PREFIX}/${TARGET_NAME}/usr" \
        --libdir=lib \
        -Ddefault_library=static \
        -Dheaders_only=false \
        -Dposix_option=enabled \
        -Dlinux_option=disabled \
        -Dglibc_option=disabled \
        -Dbsd_option=disabled \
        "${MLIBC_SRC}")

log "Building and installing mlibc to sysroot..."
ninja -C build-mlibc install

# ── Build GCC Stage 2 (Hosted) ────────────────────────────────────────────────
log "Configuring gcc Stage 2 (Hosted)..."
mkdir -p build-gcc-stage2
(cd build-gcc-stage2 && \
    "../gcc-${GCC_VERSION}/configure" \
        --target="${TARGET_BUILD}" \
        --prefix="${PREFIX}" \
        --with-sysroot="${PREFIX}/${TARGET_NAME}" \
        --enable-languages=c,c++ \
        --enable-shared \
        --disable-nls \
        --disable-multilib \
        --disable-bootstrap \
        --disable-libssp \
        --disable-libquadmath \
        --disable-libgomp \
        --disable-libatomic \
        --enable-threads=posix \
        ${EXTRA_CONFIGURE})

log "Building gcc Stage 2 (Hosted, ${JOBS} jobs)..."
"${MAKE}" -C build-gcc-stage2 -j"${JOBS}"

log "Installing gcc Stage 2..."
"${MAKE}" -C build-gcc-stage2 install

log "Cleaning up build directories..."
rm -rf \
    build-binutils "binutils-${BINUTILS_VERSION}" \
    build-gcc-stage1 build-gcc-stage2 "gcc-${GCC_VERSION}" \
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
