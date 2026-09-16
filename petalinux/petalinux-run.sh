#!/usr/bin/env bash
# ==============================================================================
# Script: petalinux-run.sh
# Description: Launch command or interactive shell inside PetaLinux Docker container
# ==============================================================================

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./petalinux-run.sh <image-tag> [command ...]

Examples:
  ./petalinux-run.sh petalinux
  ./petalinux-run.sh petalinux bash
  ./petalinux-run.sh petalinux make -C petalinux/qpcie-zu4ev hw-desc
EOF
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "Error: docker is not installed or not in PATH." >&2
    exit 1
fi

IMAGE_TAG="$1"
shift || true

HOST_USER="${USER:-builder}"
HOST_HOME="${HOME:-/home/${HOST_USER}}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
WORK_DIR="$(pwd)"

if [[ ! -d "${HOST_HOME}" ]]; then
    echo "Error: host home directory not found: ${HOST_HOME}" >&2
    exit 1
fi

mkdir -p "${HOST_HOME}/petalinux-cache"

RUN_CMD=(
    docker run --rm
)

if [[ -t 0 && -t 1 ]]; then
    RUN_CMD+=( -it )
else
    RUN_CMD+=( -i )
fi

RUN_CMD+=(
    --user "${HOST_UID}:${HOST_GID}"
    -e "USER=${HOST_USER}"
    -e "HOME=${HOST_HOME}"
    -e "TERM=${TERM:-xterm-256color}"
    -v "${HOST_HOME}:${HOST_HOME}"
    -v /opt:/opt
    -v /etc/timezone:/etc/timezone
    -v /etc/localtime:/etc/localtime
    -v "${HOST_HOME}/petalinux-cache:/docker/cache"
    -w "${WORK_DIR}"
    "${IMAGE_TAG}"
)

if [[ $# -gt 0 ]]; then
    RUN_CMD+=("$@")
else
    RUN_CMD+=(bash)
fi

"${RUN_CMD[@]}"
