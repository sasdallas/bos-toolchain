#!/usr/bin/env bash
# Copyright (c) 2023-2026 Christiaan (chris@boreddev.nl)
# This software is released under the GNU General Public License v3.0. See LICENSE file for details.
# This header needs to maintain in any file it is present in, as per the GPL license terms.

set -euo pipefail

REPO="BoredOS/toolchain"
PREFIX="${1:-/opt/boredos-toolchain}"
# Detect Host OS and CPU architecture
HOST_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
HOST_ARCH=$(uname -m)

# Standardise BSD variants to freebsd
if [[ "${HOST_OS}" == *bsd* ]]; then
    HOST_OS="freebsd"
fi

ASSET_NAME="boredos-toolchain-${HOST_ARCH}-${HOST_OS}.tar.xz"

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

need() { command -v "$1" &>/dev/null || die "Required tool '$1' not found"; }
need curl; need tar

log "Downloading latest toolchain release from ${REPO}..."
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/latest/${ASSET_NAME}"

log "Installing toolchain to ${PREFIX}..."
log "Streaming from: ${DOWNLOAD_URL}"
mkdir -p "$(dirname "${PREFIX}")"
curl -fsSL --retry 3 "${DOWNLOAD_URL}" | tar -xJ -C "$(dirname "${PREFIX}")"


# Verify installation
TOOLCHAIN_GCC="${PREFIX}/bin/x86_64-boredos-gcc"
if [[ ! -x "${TOOLCHAIN_GCC}" ]]; then
    # Fallback: check if this is an older x86_64-elf toolchain and recreate symlinks
    if [[ -x "${PREFIX}/bin/x86_64-elf-gcc" ]]; then
        log "Old x86_64-elf toolchain detected. Recreating symlinks for compatibility..."
        for bin in "${PREFIX}/bin/x86_64-elf-"*; do
            tool="${bin##*x86_64-elf-}"
            ln -sf "x86_64-elf-${tool}" "${PREFIX}/bin/x86_64-boredos-${tool}"
        done
    fi
fi

[[ -x "${TOOLCHAIN_GCC}" ]] || die "Installation failed: ${TOOLCHAIN_GCC} not found"

log "Toolchain installed successfully."
log "  GCC: $("${TOOLCHAIN_GCC}" --version | head -1)"
log "  Path: ${PREFIX}/bin"
log ""
log "Add to PATH: export PATH=\"${PREFIX}/bin:\$PATH\""
