#!/bin/bash
# Product launcher for Cyber Eyes.
# Public surface: one HTTPS gateway port.
# Internal workers: localhost only.

set -euo pipefail

export TORCHINDUCTOR_CACHE_DIR=./torch_compile_cache

GATEWAY_PROTO="https"
GATEWAY_EXTRA_ARGS=""
for arg in "$@"; do
    case "$arg" in
        --http)
            GATEWAY_PROTO="http"
            GATEWAY_EXTRA_ARGS="--http"
            ;;
    esac
done

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_PYTHON="$PROJECT_DIR/.venv/base/bin/python"
CONFIG_SCRIPT="$PROJECT_DIR/scripts/prepare_runtime.py"
CERT_SCRIPT="$PROJECT_DIR/scripts/ensure_certs.py"
DEFAULT_MODEL_DIR="$PROJECT_DIR/models/MiniCPM-o-4_5"
WORKER_HOST="127.0.0.1"
GATEWAY_HOST="0.0.0.0"
TLS_CN="${TLS_CN:-$(hostname 2>/dev/null || echo localhost)}"

if [ ! -x "$VENV_PYTHON" ]; then
    echo "[start_all] Virtual environment not found. Run: bash install.sh"
    exit 1
fi

if [ ! -f "$PROJECT_DIR/config.json" ] && [ -d "$DEFAULT_MODEL_DIR" ]; then
    "$VENV_PYTHON" "$CONFIG_SCRIPT" \
        --config "$PROJECT_DIR/config.json" \
        --template "$PROJECT_DIR/config.example.json" \
        --model-dir "$DEFAULT_MODEL_DIR" \
        --gateway-port 8006 \
        --worker-base-port 22400
fi

if [ ! -f "$PROJECT_DIR/config.json" ]; then
    echo "[start_all] config.json is missing. Run: bash bootstrap.sh"
    exit 1
fi

GATEWAY_PORT=$($VENV_PYTHON -c "import sys; sys.path.insert(0,'$PROJECT_DIR'); from config import get_config; print(get_config().gateway_port)" 2>/dev/null || echo "8006")
WORKER_BASE_PORT=$($VENV_PYTHON -c "import sys; sys.path.insert(0,'$PROJECT_DIR'); from config import get_config; print(get_config().worker_base_port)" 2>/dev/null || echo "22400")

if [ "$GATEWAY_PROTO" = "https" ]; then
    "$VENV_PYTHON" "$CERT_SCRIPT" \
        --cert "$PROJECT_DIR/certs/cert.pem" \
        --key "$PROJECT_DIR/certs/key.pem" \
        --common-name "$TLS_CN"
fi

if [ -z "${CUDA_VISIBLE_DEVICES:-}" ]; then
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        echo "[start_all] nvidia-smi not found and CUDA_VISIBLE_DEVICES is empty."
        exit 1
    fi
    NUM_GPUS=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l | tr -d ' ')
    GPU_LIST=$(seq 0 $((NUM_GPUS - 1)) | tr '\n' ',' | sed 's/,$//')
else
    GPU_LIST="$CUDA_VISIBLE_DEVICES"
    NUM_GPUS=$(echo "$GPU_LIST" | tr ',' '\n' | wc -l | tr -d ' ')
fi

if [ "$NUM_GPUS" -lt 1 ]; then
    echo "[start_all] No GPU detected. Cyber Eyes requires at least one NVIDIA GPU."
    exit 1
fi

echo "=================================================="
echo "  Cyber Eyes Launcher"
echo "=================================================="
echo "  GPUs: $GPU_LIST ($NUM_GPUS)"
echo "  Gateway: ${GATEWAY_PROTO}://${GATEWAY_HOST}:$GATEWAY_PORT"
echo "  Workers: ${WORKER_HOST}:$WORKER_BASE_PORT ~ ${WORKER_HOST}:$((WORKER_BASE_PORT + NUM_GPUS - 1))"
echo "=================================================="

cd "$PROJECT_DIR"
mkdir -p tmp certs torch_compile_cache

WORKER_ADDRS=""
GPU_IDX=0

for GPU_ID in $(echo "$GPU_LIST" | tr ',' ' '); do
    WORKER_PORT=$((WORKER_BASE_PORT + GPU_IDX))
    echo "[Worker $GPU_IDX] Starting on GPU $GPU_ID, port $WORKER_PORT..."

    nohup env CUDA_VISIBLE_DEVICES=$GPU_ID PYTHONPATH=. "$VENV_PYTHON" worker.py \
        --host "$WORKER_HOST" \
        --port $WORKER_PORT \
        --gpu-id $GPU_ID \
        --worker-index $GPU_IDX \
        > "tmp/worker_${GPU_IDX}.log" 2>&1 &

    echo $! > "tmp/worker_${GPU_IDX}.pid"

    if [ -z "$WORKER_ADDRS" ]; then
        WORKER_ADDRS="${WORKER_HOST}:$WORKER_PORT"
    else
        WORKER_ADDRS="$WORKER_ADDRS,${WORKER_HOST}:$WORKER_PORT"
    fi

    GPU_IDX=$((GPU_IDX + 1))
done

echo
echo "Waiting for workers to load models (~30-90s)..."
sleep 5

for i in $(seq 0 $((NUM_GPUS - 1))); do
    WORKER_PORT=$((WORKER_BASE_PORT + i))
    RETRY=0
    MAX_RETRIES=300

    while [ $RETRY -lt $MAX_RETRIES ]; do
        if curl -sf "http://${WORKER_HOST}:$WORKER_PORT/health" 2>/dev/null | "$VENV_PYTHON" -c "import sys, json; d = json.load(sys.stdin); raise SystemExit(0 if d.get('model_loaded') else 1)" 2>/dev/null; then
            echo "[Worker $i] Ready (port $WORKER_PORT)"
            break
        fi
        RETRY=$((RETRY + 1))
        sleep 2
    done

    if [ $RETRY -eq $MAX_RETRIES ]; then
        echo "[Worker $i] FAILED to start. Check tmp/worker_${i}.log"
        exit 1
    fi
done

echo
echo "[Gateway] Starting on port $GATEWAY_PORT..."
nohup env PYTHONPATH=. "$VENV_PYTHON" gateway.py \
    --host "$GATEWAY_HOST" \
    --port $GATEWAY_PORT \
    --workers "$WORKER_ADDRS" \
    $GATEWAY_EXTRA_ARGS \
    > "tmp/gateway.log" 2>&1 &

echo $! > "tmp/gateway.pid"
sleep 2

CURL_FLAGS=""
if [ "$GATEWAY_PROTO" = "https" ]; then
    CURL_FLAGS="-k"
fi

if curl -sf $CURL_FLAGS "${GATEWAY_PROTO}://localhost:$GATEWAY_PORT/health" 2>/dev/null | "$VENV_PYTHON" -c "import sys, json; json.load(sys.stdin)" 2>/dev/null; then
    echo "[Gateway] Ready"
else
    echo "[Gateway] May still be starting. Check tmp/gateway.log"
fi

echo
echo "=================================================="
echo "  Cyber Eyes is running"
echo "  Product:   ${GATEWAY_PROTO}://localhost:$GATEWAY_PORT/cyber-eyes"
echo "  Root URL:  ${GATEWAY_PROTO}://localhost:$GATEWAY_PORT/"
echo "  Admin:     ${GATEWAY_PROTO}://localhost:$GATEWAY_PORT/admin"
echo "  API Docs:  ${GATEWAY_PROTO}://localhost:$GATEWAY_PORT/docs"
echo
echo "  Logs:"
echo "    Gateway: tmp/gateway.log"
echo "    Workers: tmp/worker_*.log"
echo
echo "  Stop command:"
echo "    kill \$(cat tmp/*.pid 2>/dev/null) 2>/dev/null"
echo "=================================================="
