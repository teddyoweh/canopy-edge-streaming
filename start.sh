#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

CAMERA="${CAMERA:-0}"
SOURCE="${SOURCE:-}"
RESOLUTION="${RESOLUTION:-640x480}"
FPS="${FPS:-15}"
PORT="${PORT:-8554}"
MODE="${MODE:-dev}"

echo ""
echo "=== Canopy Edge Streaming Setup ==="
echo ""

if [ ! -d ".venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv .venv
fi

source .venv/bin/activate

if [ ! -f ".venv/.installed" ] || [ requirements.txt -nt .venv/.installed ]; then
    echo "Installing dependencies..."
    pip install -q -r requirements.txt
    touch .venv/.installed
fi

# Build server args for direct python mode
SERVER_ARGS="--port $PORT --resolution $RESOLUTION --fps $FPS"
if [ -n "$SOURCE" ]; then
    SERVER_ARGS="$SERVER_ARGS --source $SOURCE"
else
    SERVER_ARGS="$SERVER_ARGS --camera $CAMERA"
fi

if [ "$MODE" = "production" ] || [ "$MODE" = "prod" ]; then
    echo "Starting in PRODUCTION mode (gunicorn)..."
    echo ""
    # Gunicorn with 1 worker + threads (camera capture needs single process)
    exec gunicorn \
        --worker-class gthread \
        --workers 1 \
        --threads 4 \
        --bind "0.0.0.0:$PORT" \
        --timeout 0 \
        --access-logfile - \
        "server:app"
else
    echo "Starting in DEV mode..."
    echo ""
    exec python server.py $SERVER_ARGS
fi
