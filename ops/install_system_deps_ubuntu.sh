#!/bin/bash
# Print or run the recommended Ubuntu package installation commands.

set -euo pipefail

MODE='print'
if [[ "${1:-}" == '--apply' ]]; then
    MODE='apply'
fi

if [[ ! -f /etc/os-release ]]; then
    echo '[system-deps] /etc/os-release not found; this helper targets Ubuntu only.' >&2
    exit 1
fi

source /etc/os-release
if [[ "$ID" != 'ubuntu' ]]; then
    echo "[system-deps] unsupported distribution: $ID" >&2
    exit 1
fi

COMMANDS=(
    'sudo apt-get update'
    'sudo apt-get install -y build-essential curl ffmpeg git libsndfile1 pkg-config wget python3-venv python3-pip'
)

if [[ "$MODE" == 'apply' ]]; then
    for cmd in "${COMMANDS[@]}"; do
        echo "+ $cmd"
        eval "$cmd"
    done
    echo '[system-deps] base packages installed. Provision Python 3.10 separately if your distro default is newer.'
else
    echo '[system-deps] Recommended Ubuntu base packages:'
    for cmd in "${COMMANDS[@]}"; do
        echo "$cmd"
    done
    echo '[system-deps] Note: Cyber Eyes still expects Python 3.10. On Ubuntu 24.04, install Python 3.10 separately before running ops/bootstrap.sh.'
fi
