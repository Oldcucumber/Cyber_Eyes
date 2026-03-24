        #!/bin/bash
        # Start Cyber Eyes workers and gateway on bare metal.

        set -euo pipefail

        PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
        VENV_PYTHON="$PROJECT_DIR/.venv/base/bin/python"
        STOP_SCRIPT="$PROJECT_DIR/ops/stop_all.sh"
        CERT_SCRIPT="$PROJECT_DIR/ops/scripts/ensure_certs.py"
        WORKER_HOST="127.0.0.1"
        GATEWAY_HOST="0.0.0.0"
        TLS_CN="${TLS_CN:-$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo localhost)}"
        export TORCHINDUCTOR_CACHE_DIR="$PROJECT_DIR/torch_compile_cache"

        GATEWAY_PROTO="https"
        GATEWAY_ARGS=()
        for arg in "$@"; do
            case "$arg" in
                --http)
                    GATEWAY_PROTO="http"
                    GATEWAY_ARGS+=(--http)
                    ;;
            esac
        done

        if [[ ! -x "$VENV_PYTHON" ]]; then
            echo "[start_all] virtualenv missing. Run: bash ops/install.sh" >&2
            exit 1
        fi

        if [[ ! -f "$PROJECT_DIR/config.json" ]]; then
            echo "[start_all] config.json is missing. Run: bash ops/bootstrap.sh" >&2
            exit 1
        fi

        bash "$STOP_SCRIPT" --quiet || true
        mkdir -p "$PROJECT_DIR/tmp" "$PROJECT_DIR/certs" "$PROJECT_DIR/torch_compile_cache"
        cd "$PROJECT_DIR"

        MODEL_DIR="$($VENV_PYTHON -c "import os, sys; sys.path.insert(0, r'$PROJECT_DIR'); from backend.config import get_config; cfg = get_config(); path = cfg.model.model_path; print(path if os.path.isabs(path) else os.path.abspath(path))")"
        GATEWAY_PORT="$($VENV_PYTHON -c "import sys; sys.path.insert(0, r'$PROJECT_DIR'); from backend.config import get_config; print(get_config().gateway_port)")"
        WORKER_BASE_PORT="$($VENV_PYTHON -c "import sys; sys.path.insert(0, r'$PROJECT_DIR'); from backend.config import get_config; print(get_config().worker_base_port)")"

        if [[ ! -d "$MODEL_DIR" ]]; then
            echo "[start_all] model directory not found: $MODEL_DIR" >&2
            echo "[start_all] Run: bash ops/bootstrap.sh" >&2
            exit 1
        fi

        if [[ "$GATEWAY_PROTO" == "https" ]]; then
            "$VENV_PYTHON" "$CERT_SCRIPT"                 --cert "$PROJECT_DIR/certs/cert.pem"                 --key "$PROJECT_DIR/certs/key.pem"                 --common-name "$TLS_CN"
        fi

        GPU_LIST="${CUDA_VISIBLE_DEVICES:-}"
        if [[ -z "$GPU_LIST" ]]; then
            if ! command -v nvidia-smi >/dev/null 2>&1; then
                echo "[start_all] nvidia-smi not found. Install the NVIDIA driver first." >&2
                exit 1
            fi
            GPU_LIST="$(nvidia-smi --query-gpu=index --format=csv,noheader | tr '
' ',' | sed 's/,$//')"
        fi

        if [[ -z "$GPU_LIST" ]]; then
            echo "[start_all] no visible GPU detected" >&2
            exit 1
        fi

        WORKER_ADDRS=""
        WORKER_INDEX=0
        IFS=',' read -r -a GPU_ARRAY <<< "$GPU_LIST"
        for GPU_ID in "${GPU_ARRAY[@]}"; do
            GPU_ID="${GPU_ID// /}"
            [[ -n "$GPU_ID" ]] || continue
            WORKER_PORT=$((WORKER_BASE_PORT + WORKER_INDEX))
            LOG_PATH="$PROJECT_DIR/tmp/worker_${WORKER_INDEX}.log"
            PID_PATH="$PROJECT_DIR/tmp/worker_${WORKER_INDEX}.pid"

            nohup env CUDA_VISIBLE_DEVICES="$GPU_ID" PYTHONPATH="$PROJECT_DIR" "$VENV_PYTHON" -m backend.worker                 --host "$WORKER_HOST"                 --port "$WORKER_PORT"                 --gpu-id "$GPU_ID"                 --worker-index "$WORKER_INDEX"                 > "$LOG_PATH" 2>&1 &
            echo $! > "$PID_PATH"

            if [[ -z "$WORKER_ADDRS" ]]; then
                WORKER_ADDRS="${WORKER_HOST}:$WORKER_PORT"
            else
                WORKER_ADDRS="$WORKER_ADDRS,${WORKER_HOST}:$WORKER_PORT"
            fi

            WORKER_INDEX=$((WORKER_INDEX + 1))
        done

        if [[ $WORKER_INDEX -eq 0 ]]; then
            echo "[start_all] no worker was started; check CUDA_VISIBLE_DEVICES" >&2
            exit 1
        fi

        for ((i = 0; i < WORKER_INDEX; i++)); do
            WORKER_PORT=$((WORKER_BASE_PORT + i))
            RETRY=0
            until curl -sf "http://${WORKER_HOST}:$WORKER_PORT/health" 2>/dev/null | "$VENV_PYTHON" -c "import json, sys; data = json.load(sys.stdin); raise SystemExit(0 if data.get('model_loaded') else 1)" >/dev/null 2>&1; do
                RETRY=$((RETRY + 1))
                if [[ $RETRY -ge 300 ]]; then
                    echo "[start_all] worker $i failed to report ready. Check tmp/worker_${i}.log" >&2
                    exit 1
                fi
                sleep 2
            done
        done

        nohup env PYTHONPATH="$PROJECT_DIR" "$VENV_PYTHON" -m backend.gateway             --host "$GATEWAY_HOST"             --port "$GATEWAY_PORT"             --workers "$WORKER_ADDRS"             "${GATEWAY_ARGS[@]}"             > "$PROJECT_DIR/tmp/gateway.log" 2>&1 &
        echo $! > "$PROJECT_DIR/tmp/gateway.pid"

        sleep 2
        CURL_FLAGS=()
        if [[ "$GATEWAY_PROTO" == "https" ]]; then
            CURL_FLAGS+=(-k)
        fi

        if curl -sf "${CURL_FLAGS[@]}" "${GATEWAY_PROTO}://127.0.0.1:${GATEWAY_PORT}/health" >/dev/null 2>&1; then
            echo "Cyber Eyes ready: ${GATEWAY_PROTO}://127.0.0.1:${GATEWAY_PORT}/cyber-eyes"
            echo "Gateway log: $PROJECT_DIR/tmp/gateway.log"
        else
            echo "[start_all] gateway may still be starting. Check tmp/gateway.log" >&2
            exit 1
        fi
