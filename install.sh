#!/bin/sh
# rFabric CLI installer.
#
# Usage:
#   curl -fsSL https://get.rfabric.io | sh
#
# Environment variables:
#   RFABRIC_VERSION      Specific version to install (e.g. v1.4.0). Default: latest stable.
#   RFABRIC_CHANNEL      "stable" (default) or "rc" — selects a channel when no version is pinned.
#   RFABRIC_INSTALL_DIR  Directory to install into. Default: /usr/local/bin.

set -eu

RFABRIC_REPO="rfabric/cli"
RFABRIC_CHANNEL="${RFABRIC_CHANNEL:-stable}"
RFABRIC_INSTALL_DIR="${RFABRIC_INSTALL_DIR:-/usr/local/bin}"

log()   { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err()   { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require() {
    command -v "$1" >/dev/null 2>&1 || err "missing required tool: $1"
}

require curl
require tar
require uname
require grep
require sed

detect_os() {
    case "$(uname -s)" in
        Linux)  echo linux ;;
        Darwin) echo darwin ;;
        *)      err "unsupported OS: $(uname -s) — see https://github.com/${RFABRIC_REPO}/releases for manual install" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo amd64 ;;
        arm64|aarch64)  echo arm64 ;;
        *)              err "unsupported architecture: $(uname -m)" ;;
    esac
}

resolve_version() {
    if [ -n "${RFABRIC_VERSION:-}" ]; then
        echo "${RFABRIC_VERSION}"
        return
    fi

    api="https://api.github.com/repos/${RFABRIC_REPO}/releases"
    case "${RFABRIC_CHANNEL}" in
        stable) api="${api}/latest" ;;
        rc)     api="${api}?per_page=20" ;;
        *)      err "unknown channel: ${RFABRIC_CHANNEL} (expected stable|rc)" ;;
    esac

    response=$(curl -fsSL "${api}") || err "could not query GitHub releases API"

    if [ "${RFABRIC_CHANNEL}" = "rc" ]; then
        tag=$(printf '%s' "${response}" | grep -E '"tag_name":' | grep -E -- '-rc\.' | head -n1 | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    else
        tag=$(printf '%s' "${response}" | grep -E '"tag_name":' | head -n1 | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    fi

    [ -n "${tag}" ] || err "no release found for channel ${RFABRIC_CHANNEL}"
    echo "${tag}"
}

install_to_dir() {
    src_binary="$1"
    target="${RFABRIC_INSTALL_DIR}/rfabric"

    if [ -w "${RFABRIC_INSTALL_DIR}" ]; then
        install_cmd=""
    elif command -v sudo >/dev/null 2>&1; then
        install_cmd="sudo"
    else
        err "${RFABRIC_INSTALL_DIR} is not writable and sudo is unavailable"
    fi

    ${install_cmd} mkdir -p "${RFABRIC_INSTALL_DIR}"
    ${install_cmd} install -m 0755 "${src_binary}" "${target}"
    log "installed to ${target}"
}

main() {
    os=$(detect_os)
    arch=$(detect_arch)
    tag=$(resolve_version)
    version="${tag#v}"

    log "rFabric CLI installer"
    log "  channel:  ${RFABRIC_CHANNEL}"
    log "  version:  ${tag}"
    log "  platform: ${os}/${arch}"
    log "  target:   ${RFABRIC_INSTALL_DIR}/rfabric"

    archive="rfabric_${version}_${os}_${arch}.tar.gz"
    base_url="https://github.com/${RFABRIC_REPO}/releases/download/${tag}"

    tmp=$(mktemp -d)
    trap 'rm -rf "${tmp}"' EXIT

    log "downloading ${archive}"
    curl -fsSL -o "${tmp}/${archive}" "${base_url}/${archive}" \
        || err "failed to download ${base_url}/${archive}"

    log "verifying checksum"
    curl -fsSL -o "${tmp}/checksums.txt" "${base_url}/checksums.txt" \
        || err "failed to download checksums.txt"

    expected=$(grep -E " ${archive}$" "${tmp}/checksums.txt" | awk '{print $1}')
    [ -n "${expected}" ] || err "no checksum entry for ${archive}"

    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "${tmp}/${archive}" | awk '{print $1}')
    else
        actual=$(shasum -a 256 "${tmp}/${archive}" | awk '{print $1}')
    fi
    [ "${actual}" = "${expected}" ] || err "checksum mismatch (expected ${expected}, got ${actual})"

    log "extracting"
    tar -xzf "${tmp}/${archive}" -C "${tmp}"

    install_to_dir "${tmp}/rfabric"

    log "verifying installation"
    "${RFABRIC_INSTALL_DIR}/rfabric" version || err "installed binary failed to run"

    log "done — run 'rfabric config init' to get started"
}

main "$@"
