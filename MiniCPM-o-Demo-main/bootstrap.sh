#!/bin/bash
# One-command setup + launch for Cyber Eyes.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_PYTHON="$PROJECT_DIR/.venv/base/bin/python"
MODEL_DIR="${MODEL_DIR:-$PROJECT_DIR/models/MiniCPM-o-4_5}"
PORT="${PORT:-8006}"
WORKER_BASE_PORT="${WORKER_BASE_PORT:-22400}"
TLS_CN="${TLS_CN:-$(hostname 2>/dev/null || echo localhost)}"

bash "$PROJECT_DIR/install.sh"

"$VENV_PYTHON" "$PROJECT_DIR/scripts/fetch_model.py" --dest "$MODEL_DIR"
"$VENV_PYTHON" "$PROJECT_DIR/scripts/prepare_runtime.py" \
    --config "$PROJECT_DIR/config.json" \
    --template "$PROJECT_DIR/config.example.json" \
    --model-dir "$MODEL_DIR" \
    --gateway-port "$PORT" \
    --worker-base-port "$WORKER_BASE_PORT"
"$VENV_PYTHON" "$PROJECT_DIR/scripts/ensure_certs.py" \
    --cert "$PROJECT_DIR/certs/cert.pem" \
    --key "$PROJECT_DIR/certs/key.pem" \
    --common-name "$TLS_CN"

exec bash "$PROJECT_DIR/start_all.sh" "$@"
