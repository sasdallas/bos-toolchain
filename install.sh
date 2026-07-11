#!/usr/bin/env bash
# Copyright (c) 2026 BoredOS contributors
# install.sh — Downloads and installs the pre-built x86_64-boredos toolchain.
# Streams the tarball directly into tar to avoid writing a temp file to disk.
#
# Usage: bash install.sh [--prefix /opt/boredos-toolchain]

set -euo pipefail

REPO="BoredOS/toolchain"
PREFIX="${1:-/opt/boredos-toolchain}"
ASSET_NAME="boredos-toolchain.tar.xz"

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

need() { command -v "$1" &>/dev/null || die "Required tool '$1' not found"; }
need curl; need tar

# Resolve the download URL for the latest release asset
log "Resolving latest toolchain release from ${REPO}..."
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
DOWNLOAD_URL=$(curl -fsSL "${API_URL}" \
    | grep -o "\"browser_download_url\":\"[^\"]*${ASSET_NAME}\"" \
    | head -1 \
    | cut -d'"' -f4)

[[ -z "${DOWNLOAD_URL}" ]] && die "Could not find ${ASSET_NAME} in latest release of ${REPO}"

log "Installing toolchain to ${PREFIX}..."
log "Streaming from: ${DOWNLOAD_URL}"

# Stream directly — no intermediate .tar.xz written to disk
mkdir -p "$(dirname "${PREFIX}")"
curl -fsSL --retry 3 "${DOWNLOAD_URL}" | tar -xJ -C "$(dirname "${PREFIX}")"

# Verify installation
TOOLCHAIN_GCC="${PREFIX}/bin/x86_64-boredos-gcc"
[[ -x "${TOOLCHAIN_GCC}" ]] || die "Installation failed: ${TOOLCHAIN_GCC} not found"

log "Toolchain installed successfully."
log "  GCC: $("${TOOLCHAIN_GCC}" --version | head -1)"
log "  Path: ${PREFIX}/bin"
log ""
log "Add to PATH: export PATH=\"${PREFIX}/bin:\$PATH\""
