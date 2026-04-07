#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
#  One-liner installer — downloads the edge streamer from GitHub and runs it.
#
#  macOS / Linux (curl — recommended on Mac, no wget by default):
#    curl -fsSL https://raw.githubusercontent.com/teddyoweh/canopy-edge-streaming/main/bootstrap.sh | bash
#
#  Linux (wget):
#    wget -qO- https://raw.githubusercontent.com/teddyoweh/canopy-edge-streaming/main/bootstrap.sh | bash
#
#  Override install directory:
#    CANOPY_EDGE_DIR=~/Desktop/canopy-edge curl -fsSL ... | bash
#
#  Why: Sending run.sh via WhatsApp/iMessage marks it quarantined; fetching with
#  curl in Terminal does not, and this pulls a fresh copy from GitHub every time.
# ─────────────────────────────────────────────────────────────────────────
set -euo pipefail

CANOPY_EDGE_RAW_BASE="${CANOPY_EDGE_RAW_BASE:-https://raw.githubusercontent.com/teddyoweh/canopy-edge-streaming/main}"
INSTALL_DIR="${CANOPY_EDGE_DIR:-$HOME/canopy-edge-streaming}"

need_cmd() {
    command -v "$1" &>/dev/null
}

if ! need_cmd curl; then
    echo "curl is required. On macOS it is pre-installed; on Linux: sudo apt install curl" >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "→ Installing Canopy Edge Streamer into $INSTALL_DIR"

for f in run.sh requirements.txt server.py; do
    echo "  Downloading $f ..."
    curl -fsSL "$CANOPY_EDGE_RAW_BASE/$f" -o "$f"
done

chmod +x run.sh

if [ "$(uname -s)" = "Darwin" ]; then
    xattr -cr "$INSTALL_DIR" 2>/dev/null || true
fi

echo "→ Starting run.sh ..."
# Re-attach stdin to the terminal so interactive prompts work
# (curl ... | bash consumes stdin — run.sh needs the real keyboard)
exec bash ./run.sh "$@" </dev/tty
