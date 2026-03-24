#!/bin/bash
# Print or run the recommended CUDA 12.8 installation commands for Ubuntu.

set -euo pipefail

MODE='print'
if [[ "${1:-}" == '--apply' ]]; then
    MODE='apply'
fi

if [[ ! -f /etc/os-release ]]; then
    echo '[cuda] /etc/os-release not found; this helper targets Ubuntu only.' >&2
    exit 1
fi

source /etc/os-release
case "$ID:$VERSION_ID" in
    ubuntu:22.04)
        CUDA_REPO='ubuntu2204'
        ;;
    ubuntu:24.04)
        CUDA_REPO='ubuntu2404'
        ;;
    *)
        echo "[cuda] unsupported distribution: $ID $VERSION_ID" >&2
        exit 1
        ;;
esac

CUDA_KEYRING_VERSION="${CUDA_KEYRING_VERSION:-1.1-1}"
CUDA_TOOLKIT_PACKAGE="${CUDA_TOOLKIT_PACKAGE:-cuda-toolkit-12-8}"
CUDA_KEYRING_PACKAGE="cuda-keyring_${CUDA_KEYRING_VERSION}_all.deb"
CUDA_KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_REPO}/x86_64/${CUDA_KEYRING_PACKAGE}"

COMMANDS=(
    'sudo apt-get update'
    'sudo apt-get install -y gnupg ubuntu-drivers-common wget'
    'sudo ubuntu-drivers install --gpgpu'
    "wget -O /tmp/${CUDA_KEYRING_PACKAGE} ${CUDA_KEYRING_URL}"
    "sudo dpkg -i /tmp/${CUDA_KEYRING_PACKAGE}"
    'sudo apt-get update'
    "sudo apt-get install -y ${CUDA_TOOLKIT_PACKAGE}"
)

if [[ "$MODE" == 'apply' ]]; then
    echo '[cuda] Installing NVIDIA driver and CUDA toolkit 12.8. Reboot is required after the driver step.'
    for cmd in "${COMMANDS[@]}"; do
        echo "+ $cmd"
        eval "$cmd"
    done
    echo '[cuda] Installation commands completed. Reboot the host, then verify:'
else
    echo '[cuda] Recommended Ubuntu driver + CUDA 12.8 commands:'
    for cmd in "${COMMANDS[@]}"; do
        echo "$cmd"
    done
    echo
    echo '[cuda] After the driver install, reboot and verify:'
fi

echo 'nvidia-smi'
echo 'nvcc --version'
echo '[cuda] Target baseline: NVIDIA driver >= 570.26 and CUDA toolkit 12.8.'
