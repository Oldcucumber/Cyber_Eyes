#!/bin/bash
# Stop Cyber Eyes workers and gateway that were started by ops/start_all.sh.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$PROJECT_DIR/tmp"
QUIET=0

if [[ "${1:-}" == '--quiet' ]]; then
    QUIET=1
fi

matches_project() {
    local pid="$1"
    local cmdline=""

    if [[ -r "/proc/$pid/cmdline" ]]; then
        cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    elif command -v ps >/dev/null 2>&1; then
        cmdline="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    fi

    [[ -n "$cmdline" && "$cmdline" == *"$PROJECT_DIR"* ]]
}

stop_pid_file() {
    local pid_file="$1"
    [[ -f "$pid_file" ]] || return 0

    local pid
    pid="$(tr -d '[:space:]' < "$pid_file")"
    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        rm -f "$pid_file"
        return 0
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$pid_file"
        return 0
    fi

    if ! matches_project "$pid"; then
        [[ $QUIET -eq 1 ]] || echo "[stop_all] skip PID $pid from $(basename "$pid_file"): process no longer matches $PROJECT_DIR"
        rm -f "$pid_file"
        return 0
    fi

    [[ $QUIET -eq 1 ]] || echo "[stop_all] stopping PID $pid from $(basename "$pid_file")"
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$pid_file"
            return 0
        fi
        sleep 1
    done

    [[ $QUIET -eq 1 ]] || echo "[stop_all] force-killing PID $pid"
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$pid_file"
}

mkdir -p "$TMP_DIR"
stop_pid_file "$TMP_DIR/gateway.pid"
for pid_file in "$TMP_DIR"/worker_*.pid; do
    [[ -e "$pid_file" ]] || continue
    stop_pid_file "$pid_file"
done
