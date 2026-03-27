#!/bin/bash
# Interactive bare-metal bootstrap for Cyber Eyes.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SCRIPT="$PROJECT_DIR/ops/install.sh"
START_SCRIPT="$PROJECT_DIR/ops/start_all.sh"
STOP_SCRIPT="$PROJECT_DIR/ops/stop_all.sh"
FETCH_SCRIPT="$PROJECT_DIR/ops/scripts/fetch_model.py"
PREPARE_SCRIPT="$PROJECT_DIR/ops/scripts/prepare_runtime.py"
CERT_SCRIPT="$PROJECT_DIR/ops/scripts/ensure_certs.py"
PREFLIGHT_SCRIPT="$PROJECT_DIR/ops/scripts/preflight.py"
CUDA_GUIDE_SCRIPT="$PROJECT_DIR/ops/install_cuda_ubuntu.sh"

PYTHON_BIN="${PYTHON:-python3.10}"
VENV_DIR="${VENV_DIR:-$PROJECT_DIR/.venv/base}"
MODEL_DIR="${MODEL_DIR:-$PROJECT_DIR/models/MiniCPM-o-4_5}"
PORT="${PORT:-8006}"
WORKER_BASE_PORT="${WORKER_BASE_PORT:-22400}"
TLS_CN="${TLS_CN:-$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo localhost)}"
DOWNLOAD_SOURCE="${DOWNLOAD_SOURCE:-auto}"
LOCAL_SOURCE="${LOCAL_SOURCE:-}"
GPU_SELECTION="${CUDA_VISIBLE_DEVICES:-}"
YES=0
SKIP_START=0
SKIP_MODEL_DOWNLOAD=0
USE_HTTP=0
SHOW_CUDA_GUIDE=0
FORCE_CLEAN_MODEL_DIR=0
RECORDING_ENABLED="${RECORDING_ENABLED:-true}"
RECORDING_RETENTION_DAYS="${RECORDING_RETENTION_DAYS:-7}"
RECORDING_MAX_STORAGE_GB="${RECORDING_MAX_STORAGE_GB:-20}"

usage() {
    cat <<'EOF'
Usage: bash ops/bootstrap.sh [options]

Options:
  --yes                          Non-interactive mode; use current env/default values.
  --python PATH                  Python 3.10 executable.
  --venv PATH                    Virtualenv directory.
  --model-dir PATH               Local model directory.
  --port N                       Public gateway port. Default: 8006
  --worker-base-port N           Internal worker base port. Default: 22400
  --tls-cn NAME                  TLS common name / public IP.
  --gpu-list IDS                 Value for CUDA_VISIBLE_DEVICES, e.g. 0 or 0,1.
  --source NAME                  Model source: auto, modelscope, huggingface, local, skip.
  --local-source PATH            Pre-downloaded local model directory.
  --skip-model-download          Skip model download entirely.
  --force-clean-model-dir        Allow cleaning an existing non-ready model dir.
  --recording-enabled BOOL       true | false
  --recording-retention-days N   Recording retention limit.
  --recording-max-storage-gb N   Recording storage limit.
  --skip-start                   Prepare everything but do not start services.
  --http                         Start without TLS.
  --show-cuda-guide              Print the Ubuntu CUDA 12.8 helper commands first.
  --help                         Show this help message.
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

normalize_bool() {
    case "${1,,}" in
        1|true|t|yes|y|on) echo "true" ;;
        0|false|f|no|n|off) echo "false" ;;
        *)
            echo "[bootstrap] invalid boolean value: $1" >&2
            exit 1
            ;;
    esac
}

normalize_path() {
    local value="$1"
    if [[ -z "$value" ]]; then
        printf ''
        return
    fi
    if [[ "$value" == ~/* ]]; then
        printf '%s' "$HOME/${value#~/}"
    elif [[ "$value" = /* ]]; then
        printf '%s' "$value"
    else
        printf '%s' "$PROJECT_DIR/$value"
    fi
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
        --venv)
            VENV_DIR="$2"
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
        --local-source)
            LOCAL_SOURCE="$2"
            shift 2
            ;;
        --skip-model-download)
            SKIP_MODEL_DOWNLOAD=1
            shift
            ;;
        --force-clean-model-dir)
            FORCE_CLEAN_MODEL_DIR=1
            shift
            ;;
        --recording-enabled)
            RECORDING_ENABLED="$2"
            shift 2
            ;;
        --recording-retention-days)
            RECORDING_RETENTION_DAYS="$2"
            shift 2
            ;;
        --recording-max-storage-gb)
            RECORDING_MAX_STORAGE_GB="$2"
            shift 2
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

RECORDING_ENABLED="$(normalize_bool "$RECORDING_ENABLED")"
VENV_DIR="$(normalize_path "$VENV_DIR")"
MODEL_DIR="$(normalize_path "$MODEL_DIR")"
if [[ -n "$LOCAL_SOURCE" ]]; then
    LOCAL_SOURCE="$(normalize_path "$LOCAL_SOURCE")"
fi

case "$DOWNLOAD_SOURCE" in
    auto|modelscope|huggingface|local|skip)
        ;;
    *)
        echo "[bootstrap] invalid --source value: $DOWNLOAD_SOURCE" >&2
        exit 1
        ;;
esac

if [[ -t 0 && $YES -eq 0 ]]; then
    echo "Cyber Eyes bare-metal bootstrap"
    echo "Base packages helper: bash ops/install_system_deps_ubuntu.sh --print-only"
    echo "CUDA helper: bash ops/install_cuda_ubuntu.sh --print-only"
    echo

    PYTHON_BIN="$(prompt_value 'Python 3.10 executable' "$PYTHON_BIN")"
    VENV_DIR="$(normalize_path "$(prompt_value 'Virtualenv directory' "$VENV_DIR")")"
    PORT="$(prompt_value 'Public HTTPS port' "$PORT")"
    WORKER_BASE_PORT="$(prompt_value 'Internal worker base port' "$WORKER_BASE_PORT")"
    TLS_CN="$(prompt_value 'TLS common name or public IP' "$TLS_CN")"
    MODEL_DIR="$(normalize_path "$(prompt_value 'Model directory' "$MODEL_DIR")")"

    if command -v nvidia-smi >/dev/null 2>&1; then
        echo "Visible GPUs:"
        nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader
        echo
    fi
    GPU_SELECTION="$(prompt_value 'CUDA_VISIBLE_DEVICES (blank = all visible GPUs)' "$GPU_SELECTION")"
    DOWNLOAD_SOURCE="$(prompt_value 'Model source (auto/modelscope/huggingface/local/skip)' "$DOWNLOAD_SOURCE")"

    if [[ "$DOWNLOAD_SOURCE" == 'local' ]]; then
        LOCAL_SOURCE="$(normalize_path "$(prompt_value 'Local model source path' "$LOCAL_SOURCE")")"
    elif [[ "$DOWNLOAD_SOURCE" == 'auto' ]]; then
        LOCAL_SOURCE="$(normalize_path "$(prompt_value 'Optional local model source path' "$LOCAL_SOURCE")")"
    fi

    RECORDING_ENABLED="$(normalize_bool "$(prompt_value 'Enable session recording? (true/false)' "$RECORDING_ENABLED")")"
    RECORDING_RETENTION_DAYS="$(prompt_value 'Recording retention days' "$RECORDING_RETENTION_DAYS")"
    RECORDING_MAX_STORAGE_GB="$(prompt_value 'Recording max storage (GB)' "$RECORDING_MAX_STORAGE_GB")"

    if prompt_yes_no 'Print CUDA 12.8 installation guide now' 'n'; then
        SHOW_CUDA_GUIDE=1
    fi
    if prompt_yes_no 'Use plain HTTP instead of HTTPS (debug only)' 'n'; then
        USE_HTTP=1
    fi
    if prompt_yes_no 'Skip downloading model weights' 'n'; then
        SKIP_MODEL_DOWNLOAD=1
    fi
    if prompt_yes_no 'Allow cleaning an existing non-ready model directory' 'n'; then
        FORCE_CLEAN_MODEL_DIR=1
    fi
    if prompt_yes_no 'Prepare only and skip service startup' 'n'; then
        SKIP_START=1
    fi
fi

if [[ "$DOWNLOAD_SOURCE" == 'local' && -z "$LOCAL_SOURCE" ]]; then
    echo "[bootstrap] --local-source is required when --source local" >&2
    exit 1
fi

if [[ $SHOW_CUDA_GUIDE -eq 1 ]]; then
    bash "$CUDA_GUIDE_SCRIPT" --print-only
fi

bash "$INSTALL_SCRIPT" --python "$PYTHON_BIN" --venv "$VENV_DIR"
VENV_PYTHON="$VENV_DIR/bin/python"

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

if [[ $SKIP_MODEL_DOWNLOAD -eq 0 ]]; then
    FETCH_ARGS=(
        --dest "$MODEL_DIR"
        --source "$DOWNLOAD_SOURCE"
    )
    if [[ -n "$LOCAL_SOURCE" ]]; then
        FETCH_ARGS+=(--local-source "$LOCAL_SOURCE")
    fi
    if [[ $FORCE_CLEAN_MODEL_DIR -eq 1 ]]; then
        FETCH_ARGS+=(--force-clean)
    fi
    "$VENV_PYTHON" "$FETCH_SCRIPT" "${FETCH_ARGS[@]}"
fi

"$VENV_PYTHON" "$PREPARE_SCRIPT" \
    --config "$PROJECT_DIR/config.json" \
    --template "$PROJECT_DIR/config.example.json" \
    --model-dir "$MODEL_DIR" \
    --gateway-port "$PORT" \
    --worker-base-port "$WORKER_BASE_PORT" \
    --recording-enabled "$RECORDING_ENABLED" \
    --recording-retention-days "$RECORDING_RETENTION_DAYS" \
    --recording-max-storage-gb "$RECORDING_MAX_STORAGE_GB"

if [[ $USE_HTTP -eq 0 ]]; then
    "$VENV_PYTHON" "$CERT_SCRIPT" \
        --cert "$PROJECT_DIR/certs/cert.pem" \
        --key "$PROJECT_DIR/certs/key.pem" \
        --common-name "$TLS_CN"
fi

if [[ $SKIP_START -eq 1 ]]; then
    echo "[bootstrap] setup complete."
    echo "[bootstrap] start later with:"
    if [[ $USE_HTTP -eq 1 ]]; then
        echo "  VENV_DIR=\"$VENV_DIR\" bash \"$START_SCRIPT\" --http"
    else
        echo "  VENV_DIR=\"$VENV_DIR\" TLS_CN=\"$TLS_CN\" bash \"$START_SCRIPT\""
    fi
    echo "[bootstrap] stop command:"
    echo "  bash \"$STOP_SCRIPT\""
    exit 0
fi

START_ARGS=()
if [[ $USE_HTTP -eq 1 ]]; then
    START_ARGS+=(--http)
fi

export VENV_DIR
export TLS_CN

exec bash "$START_SCRIPT" "${START_ARGS[@]}"
