#!/bin/bash
# Interactive bare-metal bootstrap for Cyber Eyes.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SCRIPT="$PROJECT_DIR/ops/install.sh"
START_SCRIPT="$PROJECT_DIR/ops/start_all.sh"
FETCH_SCRIPT="$PROJECT_DIR/ops/scripts/fetch_model.py"
PREPARE_SCRIPT="$PROJECT_DIR/ops/scripts/prepare_runtime.py"
CERT_SCRIPT="$PROJECT_DIR/ops/scripts/ensure_certs.py"
PREFLIGHT_SCRIPT="$PROJECT_DIR/ops/scripts/preflight.py"
CUDA_GUIDE_SCRIPT="$PROJECT_DIR/ops/install_cuda_ubuntu.sh"

PYTHON_BIN="${PYTHON:-python3.10}"
MODEL_DIR="${MODEL_DIR:-$PROJECT_DIR/models/MiniCPM-o-4_5}"
PORT="${PORT:-8006}"
WORKER_BASE_PORT="${WORKER_BASE_PORT:-22400}"
TLS_CN="${TLS_CN:-$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo localhost)}"
DOWNLOAD_SOURCE="${DOWNLOAD_SOURCE:-auto}"
GPU_SELECTION="${CUDA_VISIBLE_DEVICES:-}"
YES=0
SKIP_START=0
SKIP_MODEL_DOWNLOAD=0
USE_HTTP=0
SHOW_CUDA_GUIDE=0

usage() {
    cat <<'EOF'
Usage: bash ops/bootstrap.sh [options]

Options:
  --yes                 Non-interactive mode; use current env/default values.
  --python PATH         Python 3.10 executable.
  --model-dir PATH      Local model directory.
  --port N              Public gateway port. Default: 8006
  --worker-base-port N  Internal worker base port. Default: 22400
  --tls-cn NAME         TLS common name / public IP.
  --gpu-list IDS        Value for CUDA_VISIBLE_DEVICES, e.g. 0 or 0,1.
  --source NAME         Model source: auto, modelscope, huggingface, skip.
  --skip-model-download Skip model download entirely.
  --skip-start          Prepare everything but do not start services.
  --http                Generate config only; do not create TLS certs.
  --show-cuda-guide     Print the Ubuntu CUDA 12.8 helper commands first.
  --help                Show this help message.
EOF
}

prompt_value() {
    local label="$1"
    local current="$2"
    local answer=""
    read -r -p "$label [$current]: " answer
    if [[ -n "$answer" ]]; then
        printf '%s' "$answer"
    else
        printf '%s' "$current"
    fi
}

prompt_yes_no() {
    local label="$1"
    local default="$2"
    local prompt='[y/N]'
    if [[ "$default" == 'y' ]]; then
        prompt='[Y/n]'
    fi
    local answer=''
    read -r -p "$label $prompt: " answer
    answer="${answer,,}"
    if [[ -z "$answer" ]]; then
        answer="$default"
    fi
    [[ "$answer" == 'y' ]]
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)
            YES=1
            shift
            ;;
        --python)
            PYTHON_BIN="$2"
            shift 2
            ;;
        --model-dir)
            MODEL_DIR="$2"
            shift 2
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --worker-base-port)
            WORKER_BASE_PORT="$2"
            shift 2
            ;;
        --tls-cn)
            TLS_CN="$2"
            shift 2
            ;;
        --gpu-list)
            GPU_SELECTION="$2"
            shift 2
            ;;
        --source)
            DOWNLOAD_SOURCE="$2"
            shift 2
            ;;
        --skip-model-download)
            SKIP_MODEL_DOWNLOAD=1
            shift
            ;;
        --skip-start)
            SKIP_START=1
            shift
            ;;
        --http)
            USE_HTTP=1
            shift
            ;;
        --show-cuda-guide)
            SHOW_CUDA_GUIDE=1
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "[bootstrap] unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -t 0 && $YES -eq 0 ]]; then
    echo "Cyber Eyes bare-metal bootstrap"
    echo "Base packages helper: bash ops/install_system_deps_ubuntu.sh --print-only"
    echo "CUDA helper: bash ops/install_cuda_ubuntu.sh --print-only"
    echo

    PORT="$(prompt_value 'Public HTTPS port' "$PORT")"
    WORKER_BASE_PORT="$(prompt_value 'Internal worker base port' "$WORKER_BASE_PORT")"
    TLS_CN="$(prompt_value 'TLS common name or public IP' "$TLS_CN")"
    MODEL_DIR="$(prompt_value 'Model directory' "$MODEL_DIR")"

    if command -v nvidia-smi >/dev/null 2>&1; then
        echo "Visible GPUs:"
        nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader
        echo
    fi
    GPU_SELECTION="$(prompt_value 'CUDA_VISIBLE_DEVICES (blank = all visible GPUs)' "$GPU_SELECTION")"
    DOWNLOAD_SOURCE="$(prompt_value 'Model source (auto/modelscope/huggingface/skip)' "$DOWNLOAD_SOURCE")"

    if prompt_yes_no 'Print CUDA 12.8 installation guide now' 'n'; then
        SHOW_CUDA_GUIDE=1
    fi
    if prompt_yes_no 'Use plain HTTP instead of HTTPS (debug only)' 'n'; then
        USE_HTTP=1
    fi
    if prompt_yes_no 'Skip downloading model weights' 'n'; then
        SKIP_MODEL_DOWNLOAD=1
    fi
    if prompt_yes_no 'Prepare only and skip service startup' 'n'; then
        SKIP_START=1
    fi
fi

if [[ $SHOW_CUDA_GUIDE -eq 1 ]]; then
    bash "$CUDA_GUIDE_SCRIPT" --print-only
fi

bash "$INSTALL_SCRIPT" --python "$PYTHON_BIN"
VENV_PYTHON="$PROJECT_DIR/.venv/base/bin/python"

if [[ -n "$GPU_SELECTION" ]]; then
    export CUDA_VISIBLE_DEVICES="$GPU_SELECTION"
fi

set +e
"$VENV_PYTHON" "$PREFLIGHT_SCRIPT"
PREFLIGHT_RC=$?
set -e
if [[ $PREFLIGHT_RC -ne 0 ]]; then
    echo "[bootstrap] host preflight failed." >&2
    echo "[bootstrap] Review the blockers above, then use:" >&2
    echo "[bootstrap]   bash ops/install_system_deps_ubuntu.sh --print-only" >&2
    echo "[bootstrap]   bash ops/install_cuda_ubuntu.sh --print-only" >&2
    exit $PREFLIGHT_RC
fi

if [[ $SKIP_MODEL_DOWNLOAD -eq 0 && "$DOWNLOAD_SOURCE" != 'skip' ]]; then
    "$VENV_PYTHON" "$FETCH_SCRIPT" --dest "$MODEL_DIR" --source "$DOWNLOAD_SOURCE"
fi

"$VENV_PYTHON" "$PREPARE_SCRIPT"             --config "$PROJECT_DIR/config.json"             --template "$PROJECT_DIR/config.example.json"             --model-dir "$MODEL_DIR"             --gateway-port "$PORT"             --worker-base-port "$WORKER_BASE_PORT"

if [[ $USE_HTTP -eq 0 ]]; then
    "$VENV_PYTHON" "$CERT_SCRIPT"                 --cert "$PROJECT_DIR/certs/cert.pem"                 --key "$PROJECT_DIR/certs/key.pem"                 --common-name "$TLS_CN"
fi

if [[ $SKIP_START -eq 1 ]]; then
    echo "[bootstrap] setup complete. Start later with: bash ops/start_all.sh"
    exit 0
fi

if [[ $USE_HTTP -eq 1 ]]; then
    exec bash "$START_SCRIPT" --http
else
    exec bash "$START_SCRIPT"
fi
