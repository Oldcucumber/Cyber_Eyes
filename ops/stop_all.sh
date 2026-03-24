#!/bin/bash
# Stop Cyber Eyes workers and gateway that were started by ops/start_all.sh.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$PROJECT_DIR/tmp"
QUIET=0

if [[ "${1:-}" == '--quiet' ]]; then
    QUIET=1
fi

mkdir -p "$TMP_DIR"
shopt -s nullglob
PID_FILES=("$TMP_DIR"/gateway.pid "$TMP_DIR"/worker_*.pid)
PIDS=()

for pid_file in "${PID_FILES[@]}"; do
    [[ -f "$pid_file" ]] || continue
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
        PIDS+=("$pid")
        if kill -0 "$pid" 2>/dev/null; then
            [[ $QUIET -eq 1 ]] || echo "[stop_all] stopping PID $pid from $(basename "$pid_file")"
            kill "$pid" 2>/dev/null || true
        fi
    fi
    rm -f "$pid_file"
done

for _ in 1 2 3 4 5; do
    alive=0
    for pid in "${PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            alive=1
            break
        fi
    done
    [[ $alive -eq 0 ]] && break
    sleep 1
done

for pid in "${PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
        [[ $QUIET -eq 1 ]] || echo "[stop_all] force-killing PID $pid"
        kill -9 "$pid" 2>/dev/null || true
    fi
done
