#!/bin/bash
# Docker entrypoint for Cyber Eyes.
# Public surface: one HTTPS gateway port.
# Internal workers: localhost only.

set -euo pipefail

APP_DIR="/app"
WORKSPACE="/workspace"
WORKER_HOST="127.0.0.1"
GATEWAY_HOST="0.0.0.0"
TLS_CN="${TLS_CN:-cyber-eyes.local}"
export TORCHINDUCTOR_CACHE_DIR="$APP_DIR/torch_compile_cache"

if [ -d "$WORKSPACE" ]; then
    mkdir -p "$WORKSPACE/models" "$WORKSPACE/data" "$WORKSPACE/torch_compile_cache" "$WORKSPACE/certs"
    rm -rf "$APP_DIR/data" "$APP_DIR/torch_compile_cache"
    ln -sfn "$WORKSPACE/data" "$APP_DIR/data"
    ln -sfn "$WORKSPACE/torch_compile_cache" "$APP_DIR/torch_compile_cache"
    CONFIG_PATH="$WORKSPACE/config.json"
    CERT_DIR="$WORKSPACE/certs"
    MODEL_DIR="${MODEL_DIR:-$WORKSPACE/models/MiniCPM-o-4_5}"
else
    mkdir -p "$APP_DIR/models" "$APP_DIR/data" "$APP_DIR/torch_compile_cache" "$APP_DIR/certs"
    CONFIG_PATH="$APP_DIR/config.json"
    CERT_DIR="$APP_DIR/certs"
    MODEL_DIR="${MODEL_DIR:-$APP_DIR/models/MiniCPM-o-4_5}"
fi

python "$APP_DIR/scripts/fetch_model.py" --dest "$MODEL_DIR"
python "$APP_DIR/scripts/prepare_runtime.py" \
    --config "$CONFIG_PATH" \
    --template "$APP_DIR/config.example.json" \
    --model-dir "$MODEL_DIR" \
    --gateway-port "${GATEWAY_PORT:-8006}" \
    --worker-base-port "${WORKER_BASE_PORT:-22400}"
python "$APP_DIR/scripts/ensure_certs.py" \
    --cert "$CERT_DIR/cert.pem" \
    --key "$CERT_DIR/key.pem" \
    --common-name "$TLS_CN"

if [ "$CONFIG_PATH" != "$APP_DIR/config.json" ]; then
    ln -sfn "$CONFIG_PATH" "$APP_DIR/config.json"
fi
if [ "$CERT_DIR" != "$APP_DIR/certs" ]; then
    ln -sfn "$CERT_DIR" "$APP_DIR/certs"
fi

GATEWAY_PROTO="${GATEWAY_PROTO:-https}"
GATEWAY_EXTRA_ARGS=""
if [ "$GATEWAY_PROTO" = "http" ]; then
    GATEWAY_EXTRA_ARGS="--http"
fi

GATEWAY_PORT="${GATEWAY_PORT:-$(python -c "from config import get_config; print(get_config().gateway_port)" 2>/dev/null || echo 8006)}"
WORKER_BASE_PORT="${WORKER_BASE_PORT:-$(python -c "from config import get_config; print(get_config().worker_base_port)" 2>/dev/null || echo 22400)}"

if [ -n "${NUM_GPUS_OVERRIDE:-}" ]; then
    NUM_GPUS="$NUM_GPUS_OVERRIDE"
elif [ -n "${CUDA_VISIBLE_DEVICES:-}" ]; then
    NUM_GPUS=$(echo "$CUDA_VISIBLE_DEVICES" | tr ',' '\n' | wc -l | tr -d ' ')
else
    NUM_GPUS=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l | tr -d ' ')
fi

if [ "$NUM_GPUS" -lt 1 ]; then
    echo "[entrypoint] No GPU detected. Cyber Eyes requires at least one NVIDIA GPU."
    exit 1
fi

if [ -z "${CUDA_VISIBLE_DEVICES:-}" ]; then
    GPU_LIST=$(seq 0 $((NUM_GPUS - 1)) | tr '\n' ',' | sed 's/,$//')
else
    GPU_LIST="$CUDA_VISIBLE_DEVICES"
fi

mkdir -p "$APP_DIR/tmp"
cd "$APP_DIR"

cleanup() {
    echo "Shutting down..."
    kill $(cat tmp/*.pid 2>/dev/null) 2>/dev/null || true
    wait || true
    exit 0
}
trap cleanup SIGTERM SIGINT

WORKER_ADDRS=""
GPU_IDX=0
for GPU_ID in $(echo "$GPU_LIST" | tr ',' ' '); do
    WORKER_PORT=$((WORKER_BASE_PORT + GPU_IDX))
    echo "[Worker $GPU_IDX] Starting on GPU $GPU_ID, port $WORKER_PORT..."

    CUDA_VISIBLE_DEVICES=$GPU_ID python worker.py \
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

echo "Waiting for workers to load models (~30-90s)..."
sleep 5
for i in $(seq 0 $((NUM_GPUS - 1))); do
    WORKER_PORT=$((WORKER_BASE_PORT + i))
    RETRY=0
    MAX_RETRIES=300
    while [ $RETRY -lt $MAX_RETRIES ]; do
        if curl -sf "http://${WORKER_HOST}:$WORKER_PORT/health" 2>/dev/null | python -c "import sys, json; d = json.load(sys.stdin); raise SystemExit(0 if d.get('model_loaded') else 1)" 2>/dev/null; then
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

python gateway.py \
    --host "$GATEWAY_HOST" \
    --port "$GATEWAY_PORT" \
    --workers "$WORKER_ADDRS" \
    $GATEWAY_EXTRA_ARGS \
    > "tmp/gateway.log" 2>&1 &

echo $! > "tmp/gateway.pid"
sleep 2

CURL_FLAGS=""
if [ "$GATEWAY_PROTO" = "https" ]; then
    CURL_FLAGS="-k"
fi

if curl -sf $CURL_FLAGS "${GATEWAY_PROTO}://localhost:$GATEWAY_PORT/health" >/dev/null 2>&1; then
    echo "Cyber Eyes ready: ${GATEWAY_PROTO}://localhost:$GATEWAY_PORT/cyber-eyes"
else
    echo "Gateway may still be starting. Check tmp/gateway.log"
fi

wait
