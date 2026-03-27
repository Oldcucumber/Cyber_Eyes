#!/bin/bash
# Create the Python environment and install runtime dependencies.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENV_DIR="${VENV_DIR:-$PROJECT_DIR/.venv/base}"
PYTHON_BIN="${PYTHON:-python3.10}"
TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu128}"
INSTALL_TORCH=1
INSTALL_REQUIREMENTS=1

usage() {
    cat <<'EOF'
Usage: bash ops/install.sh [options]

Options:
  --python PATH         Python executable to use for the virtualenv.
  --venv PATH           Virtualenv directory. Default: .venv/base
  --torch-index-url URL PyTorch wheel index. Default: cu128 official index
  --skip-torch          Skip torch/torchaudio installation.
  --skip-requirements   Skip requirements.txt installation.
  --help                Show this help message.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --python)
            PYTHON_BIN="$2"
            shift 2
            ;;
        --venv)
            VENV_DIR="$2"
            shift 2
            ;;
        --torch-index-url)
            TORCH_INDEX_URL="$2"
            shift 2
            ;;
        --skip-torch)
            INSTALL_TORCH=0
            shift
            ;;
        --skip-requirements)
            INSTALL_REQUIREMENTS=0
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "[install] unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ "$VENV_DIR" == ~/* ]]; then
    VENV_DIR="$HOME/${VENV_DIR#~/}"
elif [[ "$VENV_DIR" != /* ]]; then
    VENV_DIR="$PROJECT_DIR/$VENV_DIR"
fi

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    echo "[install] Python executable not found: $PYTHON_BIN" >&2
    echo "[install] Install Python 3.10 first, or pass --python /path/to/python3.10" >&2
    exit 1
fi

PYTHON_VERSION="$($PYTHON_BIN -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
if ! "$PYTHON_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] == (3, 10) else 1)' >/dev/null 2>&1; then
    echo "[install] warning: upstream MiniCPM-o deployment is validated on Python 3.10; current is $PYTHON_VERSION" >&2
fi

if [[ ! -d "$VENV_DIR" ]]; then
    "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

VENV_PYTHON="$VENV_DIR/bin/python"
PIP="$VENV_DIR/bin/pip"

"$VENV_PYTHON" -m pip install --upgrade pip setuptools wheel

if [[ $INSTALL_TORCH -eq 1 ]]; then
    "$PIP" install --upgrade --index-url "$TORCH_INDEX_URL" torch==2.8.0 torchaudio==2.8.0
fi

if [[ $INSTALL_REQUIREMENTS -eq 1 ]]; then
    "$PIP" install -r "$PROJECT_DIR/requirements.txt"
fi

if [[ ! -f "$PROJECT_DIR/config.json" ]]; then
    cp "$PROJECT_DIR/config.example.json" "$PROJECT_DIR/config.json"
fi

echo "[install] environment ready: $VENV_DIR"
