#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
#  Canopy Edge Streamer — Zero-Config Production Launcher
#
#  This is the ONLY file someone needs to run. It handles EVERYTHING:
#    - Installs Python if missing (via Homebrew on macOS, apt on Linux)
#    - Installs cloudflared if missing
#    - Creates a Python venv and installs deps
#    - Starts the camera streamer
#    - Creates a Cloudflare Tunnel for a public HTTPS URL
#    - Auto-restarts everything on crash (watchdog every 30s)
#    - Runs for days straight without intervention
#
#  Usage on a FRESH Mac Mini (or any Linux box):
#    bash run.sh
#
#  One-liner (avoids WhatsApp/iMessage quarantine — downloads from GitHub):
#    curl -fsSL https://raw.githubusercontent.com/teddyoweh/canopyads/main/edge_streaming/bootstrap.sh | bash
#
#  wget (Linux):
#    wget -qO- https://raw.githubusercontent.com/teddyoweh/canopyads/main/edge_streaming/bootstrap.sh | bash
#
#  Custom install folder:
#    CANOPY_EDGE_DIR=~/Desktop/canopy-edge curl -fsSL .../bootstrap.sh | bash
#
#  That's it. No other setup needed. No accounts, no config files.
#  NOTE: If you did save run.sh from chat, use "bash run.sh" (not "./run.sh")
#  and/or: xattr -cr "$(dirname "$0")"
# ─────────────────────────────────────────────────────────────────────────

# Don't exit on errors in the long-running phase
set -uo pipefail

# Self-fix execute permission for next invocation
chmod +x "$0" 2>/dev/null || true

# Remove macOS quarantine flags (files downloaded via browser/AirDrop/WhatsApp get blocked)
if [ "$(uname -s)" = "Darwin" ]; then
    xattr -r -d com.apple.quarantine "$(dirname "$0")" 2>/dev/null || true
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PORT="${PORT:-8554}"
# Track whether CAMERA was explicitly set by the user
CAMERA_EXPLICIT=false
if [ -n "${CAMERA+set}" ]; then
    CAMERA_EXPLICIT=true
fi
CAMERA="${CAMERA:-0}"
SOURCE="${SOURCE:-}"
RESOLUTION="${RESOLUTION:-640x480}"
FPS="${FPS:-15}"

# Canopy backend connection
CANOPY_API="https://api.trysayless.com/api/v1"
CANOPY_ADMIN_EMAIL="admin2@canopyads.io"
CANOPY_ADMIN_PASS="Admin123!"
SCREEN_ID="${SCREEN_ID:-}"
API_TOKEN=""

LOG_DIR="$SCRIPT_DIR/logs"
TUNNEL_LOG="$LOG_DIR/tunnel.log"
STREAMER_LOG="$LOG_DIR/streamer.log"
MAIN_LOG="$LOG_DIR/main.log"
URL_FILE="$SCRIPT_DIR/.public_url"
PID_FILE="$SCRIPT_DIR/.pids"
TUNNEL_PID_FILE="$SCRIPT_DIR/.tunnel_pid"
LOCK_FILE="$SCRIPT_DIR/.lock"
HAVE_LSOF=true

export SOURCE CAMERA RESOLUTION FPS PORT

mkdir -p "$LOG_DIR"

# ── Colors ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log()  { echo -e "${DIM}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$MAIN_LOG"; }
ok()   { echo -e "${DIM}[$(date '+%H:%M:%S')]${NC} ${GREEN}✓${NC} $*" | tee -a "$MAIN_LOG"; }
warn() { echo -e "${DIM}[$(date '+%H:%M:%S')]${NC} ${YELLOW}⚠${NC} $*" | tee -a "$MAIN_LOG"; }
err()  { echo -e "${DIM}[$(date '+%H:%M:%S')]${NC} ${RED}✗${NC} $*" | tee -a "$MAIN_LOG"; }

# ── Preflight checks ───────────────────────────────────────────────────
preflight_checks() {
    # curl is required for everything (downloads, health checks, API calls)
    if ! command -v curl &>/dev/null; then
        err "curl is required but not found."
        err "  macOS:  curl is usually pre-installed. Try: xcode-select --install"
        err "  Linux:  sudo apt-get install curl  (or dnf/pacman equivalent)"
        exit 1
    fi

    # lsof is used for port conflict detection — optional
    if ! command -v lsof &>/dev/null; then
        HAVE_LSOF=false
        warn "lsof not found — port conflict detection disabled"
    fi

    # Validate RESOLUTION format
    if ! echo "$RESOLUTION" | grep -qE '^[0-9]+x[0-9]+$'; then
        warn "Invalid RESOLUTION='$RESOLUTION' (expected WxH, e.g. 640x480). Using 640x480."
        RESOLUTION="640x480"
        export RESOLUTION
    fi

    # Validate FPS is numeric
    if ! echo "$FPS" | grep -qE '^[0-9]+$'; then
        warn "Invalid FPS='$FPS' (expected number). Using 15."
        FPS="15"
        export FPS
    fi

    # Validate PORT is numeric
    if ! echo "$PORT" | grep -qE '^[0-9]+$'; then
        warn "Invalid PORT='$PORT' (expected number). Using 8554."
        PORT="8554"
        export PORT
    fi

    ok "Preflight checks passed"
}

# ── Safe sudo wrapper ──────────────────────────────────────────────────
safe_sudo() {
    # Try non-interactive sudo first
    if sudo -n true 2>/dev/null; then
        sudo "$@"
    else
        log "Root access needed: $1"
        sudo "$@"
    fi
}

# ── Instance lock — prevent double-run ─────────────────────────────────
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local old_pid
        old_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            err "Another instance is already running (PID $old_pid)."
            err "If this is wrong, delete $LOCK_FILE and try again."
            exit 1
        fi
        warn "Stale lock file found (PID $old_pid no longer running). Cleaning up."
        rm -f "$LOCK_FILE"
    fi
    echo "$$" > "$LOCK_FILE"
}

# ── Clean up stale PIDs from a previous crashed run ────────────────────
cleanup_stale_pids() {
    if [ -f "$PID_FILE" ]; then
        local stale_count=0
        while read -r pid; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                warn "Killing stale process from previous run (PID $pid)"
                kill "$pid" 2>/dev/null || true
                stale_count=$((stale_count + 1))
            fi
        done < "$PID_FILE"
        rm -f "$PID_FILE"
        if [ "$stale_count" -gt 0 ]; then
            ok "Cleaned up $stale_count stale process(es)"
            sleep 1
        fi
    fi
    if [ -f "$TUNNEL_PID_FILE" ]; then
        local t_pid
        t_pid=$(cat "$TUNNEL_PID_FILE" 2>/dev/null || echo "")
        if [ -n "$t_pid" ] && kill -0 "$t_pid" 2>/dev/null; then
            warn "Killing stale tunnel (PID $t_pid)"
            kill "$t_pid" 2>/dev/null || true
        fi
        rm -f "$TUNNEL_PID_FILE"
    fi
}

# ── Ensure camera access (permissions) ─────────────────────────────────
ensure_camera_access() {
    local OS
    OS=$(uname -s)
    if [ "$OS" = "Linux" ]; then
        # Check if any video devices exist
        if ! ls /dev/video* &>/dev/null; then
            warn "No camera devices found at /dev/video*"
            warn "  - Check that a USB camera is connected"
            warn "  - Try: ls /dev/video*"
            if [ -z "$SOURCE" ]; then
                warn "Continuing anyway — you can set SOURCE=<file_or_url> to use a video file"
            fi
            return
        fi
        # Check if user can read video devices
        local first_dev
        first_dev=$(ls /dev/video* 2>/dev/null | head -1)
        if [ -n "$first_dev" ] && ! [ -r "$first_dev" ]; then
            warn "Cannot read $first_dev — camera permission issue"
            if ! id -nG | grep -qw video; then
                warn "Your user is not in the 'video' group."
                echo -ne "  ${BOLD}Add yourself to the video group? ${NC}${DIM}(Y/n):${NC} "
                read -r ADD_VIDEO
                if [[ "$ADD_VIDEO" != "n" && "$ADD_VIDEO" != "N" ]]; then
                    safe_sudo usermod -aG video "$USER"
                    ok "Added $USER to video group. You may need to log out and back in."
                fi
            fi
        fi
    elif [ "$OS" = "Darwin" ]; then
        log "Camera access: macOS will prompt for permission on first use."
        log "  If the stream shows black frames, grant camera access in:"
        log "  System Settings > Privacy & Security > Camera"
    fi
}

# ── Download with retry ────────────────────────────────────────────────
download_with_retry() {
    local url="$1"
    local output="$2"
    local attempt=0
    local max_attempts=3
    local wait_secs=2

    while [ $attempt -lt $max_attempts ]; do
        if curl -fsSL --connect-timeout 15 --max-time 60 "$url" -o "$output" 2>/dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            warn "Download failed (attempt $attempt/$max_attempts). Retrying in ${wait_secs}s..."
            sleep $wait_secs
            wait_secs=$((wait_secs * 2))
        fi
    done
    err "Download failed after $max_attempts attempts: $url"
    return 1
}

# ── Login to Canopy API and get a fresh token ──────────────────────────
_login() {
    local LOGIN_RESP
    LOGIN_RESP=$(curl -s --max-time 10 -X POST "${CANOPY_API}/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"${CANOPY_ADMIN_EMAIL}\",\"password\":\"${CANOPY_ADMIN_PASS}\"}" 2>/dev/null || echo "{}")
    API_TOKEN=$(echo "$LOGIN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
}

# ── Ensure we have a valid token (re-login if expired) ─────────────────
_refresh_api_token() {
    if [ -z "$API_TOKEN" ]; then
        _login
        return
    fi

    local token_status
    token_status=$(curl -s -o /dev/null -w "%{http_code}" \
        "${CANOPY_API}/auth/me" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        --connect-timeout 5 --max-time 10 2>/dev/null || echo "000")

    if [ "$token_status" != "200" ]; then
        _login
    fi
}

# ── Auto-update screen URL in Canopy backend ───────────────────────────
update_canopy_screen() {
    local new_url="$1"
    if [ -z "$SCREEN_ID" ]; then
        return
    fi

    # Re-authenticate if token expired (script runs for days)
    _refresh_api_token

    if [ -z "$API_TOKEN" ]; then
        warn "No API token — cannot update screen URL"
        return
    fi

    log "Updating screen $SCREEN_ID with new stream URL..."
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" \
        -X PATCH "${CANOPY_API}/admin/screens/${SCREEN_ID}" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -d "{\"stream_url\": \"${new_url}/stream\"}" \
        --connect-timeout 10 --max-time 15) || true
    if [ "$status" = "200" ]; then
        ok "Screen URL updated in Canopy backend"
    elif [ "$status" = "404" ]; then
        warn "Screen $SCREEN_ID not found — it may have been deleted"
    else
        warn "Failed to update screen URL (HTTP $status)"
    fi
}

# ── Cleanup on exit ─────────────────────────────────────────────────────
SHUTTING_DOWN=false
cleanup() {
    # Prevent running twice (EXIT fires after INT/TERM)
    if [ "$SHUTTING_DOWN" = "true" ]; then return; fi
    SHUTTING_DOWN=true

    echo "" | tee -a "$MAIN_LOG"
    log "Shutting down all processes..."
    if [ -f "$PID_FILE" ]; then
        while read -r pid; do
            kill "$pid" 2>/dev/null || true
        done < "$PID_FILE"
        rm -f "$PID_FILE"
    fi
    # Kill any remaining children
    pkill -P $$ 2>/dev/null || true
    rm -f "$URL_FILE" "$LOCK_FILE"
    log "Stopped. Goodbye."
    exit 0
}
trap cleanup EXIT INT TERM

# ── Step 1: Ensure Python 3 exists (any version >= 3.8) ──────────────
ensure_python() {
    # Accept any Python 3.8+ — don't force a specific minor version
    if command -v python3 &>/dev/null; then
        PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "0.0")
        PY_MAJOR=$(echo "$PY_VER" | cut -d. -f1)
        PY_MINOR=$(echo "$PY_VER" | cut -d. -f2)
        if [ "$PY_MAJOR" -ge 3 ] && [ "$PY_MINOR" -ge 8 ]; then
            ok "Python $PY_VER found"
            return
        fi
        warn "Python $PY_VER is too old (need 3.8+)"
    fi

    log "Installing Python..."
    OS=$(uname -s)
    if [ "$OS" = "Darwin" ]; then
        # macOS: install via Homebrew
        if ! command -v brew &>/dev/null; then
            log "Installing Homebrew first..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/null
            # Add brew to PATH for Apple Silicon
            if [ -f "/opt/homebrew/bin/brew" ]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
                echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
            fi
        fi
        # Try the latest stable, then fall back to whatever is available
        brew install python@3.13 2>/dev/null || brew install python@3.12 2>/dev/null || brew install python3
        # macOS: also install libturbojpeg for fast JPEG encoding (optional)
        brew install jpeg-turbo 2>/dev/null || true
    elif [ "$OS" = "Linux" ]; then
        if command -v apt-get &>/dev/null; then
            safe_sudo apt-get update -qq
            safe_sudo apt-get install -y -qq python3 python3-venv python3-pip python3-dev
            # libturbojpeg for fast JPEG (optional)
            safe_sudo apt-get install -y -qq libturbojpeg0-dev 2>/dev/null || true
        elif command -v dnf &>/dev/null; then
            safe_sudo dnf install -y python3 python3-pip python3-devel
            safe_sudo dnf install -y turbojpeg-devel 2>/dev/null || true
        elif command -v pacman &>/dev/null; then
            safe_sudo pacman -Sy --noconfirm python python-pip
        fi
    fi

    if command -v python3 &>/dev/null; then
        ok "Python installed: $(python3 --version)"
    else
        err "Failed to install Python. Please install Python 3.8+ manually."
        exit 1
    fi
}

# ── Step 2: Ensure cloudflared exists ───────────────────────────────────
ensure_cloudflared() {
    if command -v cloudflared &>/dev/null; then
        ok "cloudflared found"
        return
    fi

    log "Installing cloudflared..."
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)

    if [ "$OS" = "darwin" ]; then
        if command -v brew &>/dev/null; then
            brew install cloudflared 2>/dev/null && { ok "cloudflared installed via Homebrew"; return; }
        fi
        # Manual install — detect Apple Silicon vs Intel
        local CF_ARCH="amd64"
        if [ "$ARCH" = "arm64" ]; then
            CF_ARCH="arm64"
        fi
        mkdir -p "$SCRIPT_DIR/bin"
        if download_with_retry \
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${CF_ARCH}.tgz" \
            /tmp/cf.tgz; then
            tar xzf /tmp/cf.tgz -C "$SCRIPT_DIR/bin/" 2>/dev/null
            chmod +x "$SCRIPT_DIR/bin/cloudflared" 2>/dev/null || true
            export PATH="$SCRIPT_DIR/bin:$PATH"
            rm -f /tmp/cf.tgz
        fi
    elif [ "$OS" = "linux" ]; then
        case "$ARCH" in
            x86_64)  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
            aarch64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
            armv7l)  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
            *)       CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
        esac
        mkdir -p "$SCRIPT_DIR/bin"
        if download_with_retry "$CF_URL" "$SCRIPT_DIR/bin/cloudflared"; then
            chmod +x "$SCRIPT_DIR/bin/cloudflared"
            export PATH="$SCRIPT_DIR/bin:$PATH"
        fi
    fi

    if command -v cloudflared &>/dev/null; then
        ok "cloudflared installed"
    else
        err "Failed to install cloudflared."
        exit 1
    fi
}

# ── Step 3: Setup Python venv + deps ────────────────────────────────────
_bootstrap_pip() {
    # Get pip into the venv by any means necessary
    local py="$1"
    if $py -m pip --version &>/dev/null; then
        return 0
    fi
    log "Bootstrapping pip..."
    # Method 1: ensurepip (works on most Python installs)
    $py -m ensurepip --upgrade 2>/dev/null && return 0
    # Method 2: get-pip.py via curl
    curl -fsSL https://bootstrap.pypa.io/get-pip.py -o /tmp/_get_pip.py 2>/dev/null \
        && $py /tmp/_get_pip.py 2>/dev/null && rm -f /tmp/_get_pip.py && return 0
    # Method 3: get-pip.py via python urllib
    $py -c "import urllib.request; urllib.request.urlretrieve('https://bootstrap.pypa.io/get-pip.py', '/tmp/_get_pip.py')" 2>/dev/null \
        && $py /tmp/_get_pip.py 2>/dev/null && rm -f /tmp/_get_pip.py && return 0
    return 1
}

_install_pkg() {
    # Install a single package with verbose error on failure
    local pip_cmd="$1"
    local pkg="$2"
    local required="$3"  # "required" or "optional"

    if $pip_cmd install -q "$pkg" 2>/dev/null; then
        return 0
    fi
    # Retry without version constraint
    local base_pkg
    base_pkg=$(echo "$pkg" | sed 's/[><=!].*//')
    if [ "$base_pkg" != "$pkg" ]; then
        if $pip_cmd install -q "$base_pkg" 2>/dev/null; then
            return 0
        fi
    fi
    if [ "$required" = "required" ]; then
        err "Failed to install $pkg"
    else
        warn "$pkg not available (optional — skipping)"
    fi
    return 1
}

setup_venv() {
    local VENV_PY=".venv/bin/python"

    # ── 1. Check if existing venv works ──
    if [ -d ".venv" ]; then
        if ! $VENV_PY -c "import sys" 2>/dev/null; then
            warn "Existing venv is broken (wrong Python version?). Rebuilding..."
            rm -rf .venv
        fi
    fi

    # ── 2. Create venv if needed ──
    if [ ! -f ".venv/bin/activate" ]; then
        rm -rf .venv 2>/dev/null || true
        log "Creating Python virtual environment..."

        # Try standard venv
        if python3 -m venv .venv 2>&1 | tee -a "$MAIN_LOG" && [ -f ".venv/bin/activate" ]; then
            ok "venv created"
        else
            rm -rf .venv 2>/dev/null || true
            # Fallback: --without-pip (works when ensurepip is missing)
            if python3 -m venv --without-pip .venv 2>/dev/null && [ -f ".venv/bin/activate" ]; then
                ok "venv created (without pip — will bootstrap)"
            else
                rm -rf .venv 2>/dev/null || true
                # Last resort on Linux: install python3-venv package and retry
                if [ "$(uname -s)" = "Linux" ] && command -v apt-get &>/dev/null; then
                    warn "venv module missing — installing python3-venv..."
                    safe_sudo apt-get install -y -qq python3-venv 2>/dev/null
                    python3 -m venv .venv 2>/dev/null || python3 -m venv --without-pip .venv 2>/dev/null
                fi
            fi
        fi

        if [ ! -f ".venv/bin/activate" ]; then
            err "Cannot create virtual environment."
            err "  macOS:  brew install python3"
            err "  Ubuntu: sudo apt install python3-venv"
            err "  Fedora: sudo dnf install python3"
            exit 1
        fi
    fi

    # ── 3. Activate and ensure pip ──
    source .venv/bin/activate

    if ! _bootstrap_pip "$VENV_PY"; then
        err "Cannot install pip in venv."
        err "  Try manually: curl https://bootstrap.pypa.io/get-pip.py | $VENV_PY"
        exit 1
    fi

    # ── 4. Install dependencies ──
    local PIP="$VENV_PY -m pip"

    if [ ! -f ".venv/.installed" ] || [ requirements.txt -nt .venv/.installed ]; then
        log "Installing Python dependencies..."
        $PIP install -q --upgrade pip setuptools wheel 2>/dev/null || true

        # Try batch install first (fastest path)
        if $PIP install -q -r requirements.txt 2>/dev/null; then
            ok "All dependencies installed"
        else
            warn "Batch install failed — installing individually..."

            # Core: must succeed or we can't run
            _install_pkg "$PIP" "flask" "required"
            _install_pkg "$PIP" "numpy" "required"
            _install_pkg "$PIP" "requests" "required"
            _install_pkg "$PIP" "gunicorn" "required"

            # OpenCV: try multiple package names (binary compat varies by platform/Python)
            if ! $VENV_PY -c "import cv2" 2>/dev/null; then
                log "Installing OpenCV..."
                $PIP install -q "opencv-python-headless" 2>/dev/null \
                    || $PIP install -q "opencv-python" 2>/dev/null \
                    || $PIP install -q "opencv-contrib-python-headless" 2>/dev/null \
                    || $PIP install -q "opencv-contrib-python" 2>/dev/null \
                    || err "Failed to install OpenCV"
            fi

            # Optional: TurboJPEG (3-5x faster encoding, needs libturbojpeg)
            _install_pkg "$PIP" "PyTurboJPEG" "optional"
        fi

        # ── 5. Verify critical imports ──
        if ! $VENV_PY -c "import cv2" 2>/dev/null; then
            err "OpenCV (cv2) not importable. Camera will not work."
            err "  Try: $PIP install opencv-python-headless"
            exit 1
        fi
        if ! $VENV_PY -c "import flask" 2>/dev/null; then
            err "Flask not importable. Server will not start."
            err "  Try: $PIP install flask"
            exit 1
        fi

        touch .venv/.installed
    fi

    ok "Python environment ready ($($VENV_PY --version 2>&1))"
}

# ── Camera picker — interactive camera selection ───────────────────────
pick_camera() {
    # Skip if SOURCE is set (user wants a file/RTSP URL)
    if [ -n "$SOURCE" ]; then
        ok "Using source: $SOURCE"
        return
    fi

    # Skip if user explicitly set CAMERA via env var
    if [ "$CAMERA_EXPLICIT" = "true" ]; then
        ok "Using camera index $CAMERA (set via environment)"
        return
    fi

    # Check for saved camera in .config
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        if [ -n "${SAVED_CAMERA:-}" ]; then
            CAMERA="$SAVED_CAMERA"
            export CAMERA
            ok "Using saved camera: ${SAVED_CAMERA_NAME:-Camera $CAMERA}"
            return
        fi
    fi

    # Enumerate cameras using Python
    log "Detecting cameras..."
    local CAMERA_LIST
    CAMERA_LIST=$(.venv/bin/python -c "
import sys, json, platform

cameras = []
os_name = platform.system()

# Platform-specific enumeration for names
names = {}
if os_name == 'Darwin':
    import subprocess
    try:
        raw = subprocess.check_output(
            ['system_profiler', 'SPCameraDataType', '-json'],
            stderr=subprocess.DEVNULL, timeout=5
        )
        data = json.loads(raw)
        for i, cam in enumerate(data.get('SPCameraDataType', [])):
            names[i] = cam.get('_name', f'Camera {i}')
    except Exception:
        pass
elif os_name == 'Linux':
    import subprocess, glob
    devs = sorted(glob.glob('/dev/video*'))
    for dev in devs:
        idx = int(dev.replace('/dev/video', ''))
        try:
            out = subprocess.check_output(
                ['v4l2-ctl', '--device', dev, '--info'],
                stderr=subprocess.DEVNULL, timeout=3
            ).decode()
            for line in out.splitlines():
                if 'Card type' in line:
                    names[idx] = line.split(':', 1)[1].strip()
                    break
        except Exception:
            names[idx] = f'Camera {idx} ({dev})'

# Probe indices 0-9 with OpenCV
import cv2
for i in range(10):
    cap = cv2.VideoCapture(i)
    if cap.isOpened():
        w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        name = names.get(i, f'Camera {i}')
        cameras.append({'index': i, 'name': name, 'resolution': f'{w}x{h}'})
        cap.release()

print(json.dumps(cameras))
" 2>/dev/null || echo "[]")

    local CAM_COUNT
    CAM_COUNT=$(echo "$CAMERA_LIST" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

    if [ "$CAM_COUNT" -eq 0 ]; then
        warn "No cameras detected!"
        warn "  - Check that a USB camera is plugged in"
        warn "  - On Linux, ensure you're in the 'video' group"
        warn "  - On macOS, check System Settings > Privacy > Camera"
        echo ""
        echo -ne "  ${BOLD}Enter a video file path or RTSP URL${NC} ${DIM}(or Enter to use Camera 0):${NC} "
        read -r MANUAL_SOURCE
        if [ -n "$MANUAL_SOURCE" ]; then
            SOURCE="$MANUAL_SOURCE"
            export SOURCE
            ok "Using source: $SOURCE"
        else
            ok "Defaulting to Camera 0"
        fi
        return
    fi

    if [ "$CAM_COUNT" -eq 1 ]; then
        # Auto-select the only camera
        CAMERA=$(echo "$CAMERA_LIST" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['index'])")
        local CAM_NAME
        CAM_NAME=$(echo "$CAMERA_LIST" | python3 -c "import sys,json; c=json.load(sys.stdin)[0]; print(f\"{c['name']} ({c['resolution']})\")")
        export CAMERA
        ok "Auto-selected: $CAM_NAME"
        # Save to config
        _save_camera_choice "$CAMERA" "$CAM_NAME"
        return
    fi

    # Multiple cameras — show picker
    echo ""
    echo -e "  ${CYAN}${BOLD}  ┌──────────────────────────────────────────┐${NC}"
    echo -e "  ${CYAN}${BOLD}  │   SELECT A CAMERA                       │${NC}"
    echo -e "  ${CYAN}${BOLD}  └──────────────────────────────────────────┘${NC}"
    echo ""
    echo "$CAMERA_LIST" | python3 -c "
import sys, json
cams = json.load(sys.stdin)
for i, c in enumerate(cams):
    print(f'    {i+1}. {c[\"name\"]}  ({c[\"resolution\"]})')
print(f'    {len(cams)+1}. Enter video file or RTSP URL')
"
    echo ""
    echo -ne "  ${BOLD}Select camera #${NC} ${DIM}(1-$((CAM_COUNT+1))):${NC} "
    read -r CAM_CHOICE

    # Default to first camera if empty
    if [ -z "$CAM_CHOICE" ]; then
        CAM_CHOICE=1
    fi

    # Check if they picked the "manual source" option
    if [ "$CAM_CHOICE" -eq "$((CAM_COUNT+1))" ] 2>/dev/null; then
        echo -ne "  ${BOLD}Enter path or URL:${NC} "
        read -r MANUAL_SOURCE
        if [ -n "$MANUAL_SOURCE" ]; then
            SOURCE="$MANUAL_SOURCE"
            export SOURCE
            ok "Using source: $SOURCE"
        fi
        return
    fi

    # Parse selection
    local SELECTED
    SELECTED=$(echo "$CAMERA_LIST" | python3 -c "
import sys, json
cams = json.load(sys.stdin)
idx = int(sys.argv[1]) - 1
if 0 <= idx < len(cams):
    c = cams[idx]
    print(f\"{c['index']}|{c['name']} ({c['resolution']})\")
else:
    print('0|Camera 0')
" "$CAM_CHOICE" 2>/dev/null || echo "0|Camera 0")

    CAMERA=$(echo "$SELECTED" | cut -d'|' -f1)
    local CAM_NAME
    CAM_NAME=$(echo "$SELECTED" | cut -d'|' -f2)
    export CAMERA
    ok "Selected: $CAM_NAME"
    _save_camera_choice "$CAMERA" "$CAM_NAME"
}

_save_camera_choice() {
    local cam_idx="$1"
    local cam_name="$2"
    # Append to .config (or create it) — preserve existing keys
    if [ -f "$CONFIG_FILE" ]; then
        # Remove old camera lines if present
        grep -v '^SAVED_CAMERA' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" 2>/dev/null || true
        mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    fi
    echo "SAVED_CAMERA=\"${cam_idx}\"" >> "$CONFIG_FILE"
    echo "SAVED_CAMERA_NAME=\"${cam_name}\"" >> "$CONFIG_FILE"
}

# ── Step 4: Start the edge streamer ─────────────────────────────────────
start_streamer() {
    # Kill existing on same port (only if lsof is available)
    if [ "$HAVE_LSOF" = "true" ]; then
        local port_pids
        port_pids=$(lsof -ti ":$PORT" 2>/dev/null || true)
        if [ -n "$port_pids" ]; then
            # Check if they're our processes from a previous run
            local our_pids=""
            if [ -f "$PID_FILE" ]; then
                our_pids=$(cat "$PID_FILE" 2>/dev/null || true)
            fi
            for ppid in $port_pids; do
                if echo "$our_pids" | grep -qw "$ppid" 2>/dev/null; then
                    kill -9 "$ppid" 2>/dev/null || true
                else
                    warn "Port $PORT is in use by foreign process (PID $ppid). Attempting to proceed..."
                    kill "$ppid" 2>/dev/null || true
                fi
            done
            sleep 1
        fi
    fi

    if [ -f ".venv/bin/activate" ]; then
        source .venv/bin/activate
    fi

    log "Starting camera streamer on port $PORT..."

    if .venv/bin/python -c "import gunicorn" 2>/dev/null; then
        .venv/bin/gunicorn \
            --worker-class gthread \
            --workers 1 \
            --threads 4 \
            --bind "0.0.0.0:$PORT" \
            --timeout 0 \
            --access-logfile "$STREAMER_LOG" \
            --error-logfile "$STREAMER_LOG" \
            "server:app" >> "$STREAMER_LOG" 2>&1 &
    else
        SERVER_ARGS="--port $PORT --resolution $RESOLUTION --fps $FPS"
        [ -n "$SOURCE" ] && SERVER_ARGS="$SERVER_ARGS --source $SOURCE" || SERVER_ARGS="$SERVER_ARGS --camera $CAMERA"
        .venv/bin/python server.py $SERVER_ARGS >> "$STREAMER_LOG" 2>&1 &
    fi
    STREAMER_PID=$!
    echo "$STREAMER_PID" >> "$PID_FILE"

    # Wait for streamer to be ready
    for i in $(seq 1 60); do
        if curl -s --max-time 2 "http://localhost:$PORT/status" >/dev/null 2>&1; then
            ok "Streamer running (PID $STREAMER_PID)"
            return 0
        fi
        sleep 1
    done

    err "Streamer failed to start. Check: $STREAMER_LOG"
    cat "$STREAMER_LOG" | tail -20
    return 1
}

# ── Step 5: Start Cloudflare Tunnel ─────────────────────────────────────
start_tunnel() {
    log "Creating public tunnel..."

    # Kill any old tunnel
    pkill -f "cloudflared.*tunnel.*$PORT" 2>/dev/null || true
    sleep 1
    > "$TUNNEL_LOG"

    cloudflared tunnel \
        --url "http://localhost:$PORT" \
        --no-autoupdate \
        --config /dev/null \
        >> "$TUNNEL_LOG" 2>&1 &
    TUNNEL_PID=$!
    echo "$TUNNEL_PID" >> "$PID_FILE"

    # Wait for the public URL
    PUBLIC_URL=""
    for i in $(seq 1 60); do
        PUBLIC_URL=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1 || true)
        if [ -n "$PUBLIC_URL" ]; then
            break
        fi
        if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
            err "Tunnel process died."
            cat "$TUNNEL_LOG" | tail -10
            return 1
        fi
        sleep 1
    done

    if [ -z "$PUBLIC_URL" ]; then
        err "Tunnel failed to provide URL after 60s."
        return 1
    fi

    echo "$PUBLIC_URL" > "$URL_FILE"
    echo "$TUNNEL_PID" > "$TUNNEL_PID_FILE"
    ok "Tunnel active (PID $TUNNEL_PID)"

    # Auto-update Canopy backend with new URL
    update_canopy_screen "$PUBLIC_URL"

    return 0
}

# ── Log rotation ───────────────────────────────────────────────────────
rotate_logs() {
    local max_size=$((50 * 1024 * 1024))  # 50MB
    for logfile in "$STREAMER_LOG" "$TUNNEL_LOG" "$MAIN_LOG"; do
        if [ -f "$logfile" ]; then
            local size
            size=$(stat -f%z "$logfile" 2>/dev/null || stat -c%s "$logfile" 2>/dev/null || echo "0")
            if [ "$size" -gt "$max_size" ] 2>/dev/null; then
                mv "$logfile" "${logfile}.old"
                > "$logfile"
                log "Rotated $(basename "$logfile") (was ${size} bytes)"
                # Signal gunicorn to reopen log files
                if [ -f "$PID_FILE" ]; then
                    local first_pid
                    first_pid=$(head -1 "$PID_FILE" 2>/dev/null || true)
                    if [ -n "$first_pid" ]; then
                        kill -USR1 "$first_pid" 2>/dev/null || true
                    fi
                fi
            fi
        fi
    done
}

# ── Step 6: Watchdog ────────────────────────────────────────────────────
watchdog() {
    local streamer_failures=0
    local watchdog_cycles=0
    while true; do
        sleep 30
        watchdog_cycles=$((watchdog_cycles + 1))

        # Check streamer health
        if ! curl -s --max-time 3 "http://localhost:$PORT/status" >/dev/null 2>&1; then
            streamer_failures=$((streamer_failures + 1))
            warn "Streamer health check failed ($streamer_failures)"
            if [ $streamer_failures -ge 3 ]; then
                warn "Restarting streamer..."
                start_streamer && streamer_failures=0
            fi
        else
            streamer_failures=0
        fi

        # Check tunnel process (NOT the URL — just is the process alive?)
        if [ -f "$TUNNEL_PID_FILE" ]; then
            T_PID=$(cat "$TUNNEL_PID_FILE")
            if ! kill -0 "$T_PID" 2>/dev/null; then
                warn "Tunnel process died (PID $T_PID). Restarting..."
                sleep 3
                if start_tunnel; then
                    print_banner
                    ok "Tunnel recovered with new URL"
                fi
            fi
        fi

        # Rotate logs every cycle
        rotate_logs

        # Memory watchdog — check streamer RSS every 10 cycles (~5 min)
        if [ $((watchdog_cycles % 10)) -eq 0 ]; then
            if [ -f "$PID_FILE" ]; then
                local s_pid
                s_pid=$(head -1 "$PID_FILE" 2>/dev/null || true)
                if [ -n "$s_pid" ] && kill -0 "$s_pid" 2>/dev/null; then
                    local rss_kb
                    rss_kb=$(ps -o rss= -p "$s_pid" 2>/dev/null | tr -d ' ' || echo "0")
                    if [ "${rss_kb:-0}" -gt 1048576 ] 2>/dev/null; then
                        warn "Streamer using ${rss_kb}KB RAM (>1GB). Restarting..."
                        start_streamer
                    fi
                fi
            fi
        fi
    done
}

# ── Banner ──────────────────────────────────────────────────────────────
print_banner() {
    PUBLIC_URL=$(cat "$URL_FILE" 2>/dev/null || echo "PENDING")
    LOCAL_IP=$(python3 -c "
import socket
try:
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(2)
    s.connect(('8.8.8.8',80));ip=s.getsockname()[0];s.close();print(ip)
except:print('localhost')
" 2>/dev/null || echo "localhost")

    CAMERA_INFO=$(curl -s --max-time 2 "http://localhost:$PORT/status" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('camera','Starting...'))" 2>/dev/null || echo "Starting...")
    CURRENT_FPS=$(curl -s --max-time 2 "http://localhost:$PORT/status" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('fps',0))" 2>/dev/null || echo "0")

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║${NC}              ${CYAN}${BOLD}🟢 CANOPY EDGE STREAMER${NC}                            ${BOLD}║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║${NC}                                                                  ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  ${GREEN}${BOLD}▶ COPY THIS URL:${NC}                                              ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}                                                                  ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}    ${YELLOW}${BOLD}${PUBLIC_URL}/stream${NC}"
    echo -e "${BOLD}║${NC}                                                                  ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  ${DIM}Paste it as the screen's Stream URL in Canopy admin.${NC}          ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  ${DIM}Anyone with the URL can watch the stream from anywhere.${NC}       ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}                                                                  ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  ${DIM}─────────────────────────────────────────────────────${NC}         ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  ${DIM}Dashboard:${NC} ${PUBLIC_URL}/"
    echo -e "${BOLD}║${NC}  ${DIM}Snapshot:${NC}  ${PUBLIC_URL}/frame"
    echo -e "${BOLD}║${NC}  ${DIM}Local:${NC}     http://${LOCAL_IP}:${PORT}"
    echo -e "${BOLD}║${NC}  ${DIM}Camera:${NC}    ${CAMERA_INFO}"
    echo -e "${BOLD}║${NC}  ${DIM}FPS:${NC}       ${CURRENT_FPS}"
    echo -e "${BOLD}║${NC}                                                                  ${BOLD}║${NC}"
    if [ -n "$SCREEN_ID" ]; then
    echo -e "${BOLD}║${NC}  ${DIM}Screen ID:${NC} ${SCREEN_ID}"
    echo -e "${BOLD}║${NC}  ${DIM}Auto-sync:${NC} ${GREEN}URL auto-updates in Canopy when tunnel restarts${NC}"
    echo -e "${BOLD}║${NC}                                                                  ${BOLD}║${NC}"
    fi
    echo -e "${BOLD}║${NC}  ${GREEN}Auto-restarts on failure. Press Ctrl+C to stop.${NC}                ${BOLD}║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Copy to clipboard
    if command -v pbcopy &>/dev/null; then
        echo -n "${PUBLIC_URL}/stream" | pbcopy
        ok "Stream URL copied to clipboard!"
    elif command -v xclip &>/dev/null; then
        echo -n "${PUBLIC_URL}/stream" | xclip -selection clipboard 2>/dev/null
        ok "Stream URL copied to clipboard!"
    fi

    # Save URL to a visible file
    cat > "$SCRIPT_DIR/STREAM_URL.txt" << URLEOF
Canopy Edge Streamer — Public URL
==================================

Stream URL (paste this in Canopy admin):
${PUBLIC_URL}/stream

Dashboard: ${PUBLIC_URL}/
Snapshot:  ${PUBLIC_URL}/frame
Status:    ${PUBLIC_URL}/status

Local: http://${LOCAL_IP}:${PORT}
Started: $(date)
URLEOF
    ok "URL also saved to STREAM_URL.txt"
}

# ── Prevent sleep (macOS) ───────────────────────────────────────────────
prevent_sleep() {
    if [ "$(uname -s)" = "Darwin" ]; then
        caffeinate -s &
        echo $! >> "$PID_FILE"
        ok "Sleep prevention active (caffeinate)"
    fi
}

# ── Interactive setup: create screen + assign to campaign ───────────────
CONFIG_FILE="$SCRIPT_DIR/.config"

_ensure_api_token() {
    _refresh_api_token
    if [ -n "$API_TOKEN" ]; then
        ok "Authenticated as ${CANOPY_ADMIN_EMAIL}"
    else
        warn "Authentication failed — check credentials or API URL"
    fi
}

interactive_setup() {
    # If already configured from a previous run, load it
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        if [ -n "${SAVED_SCREEN_ID:-}" ]; then
            SCREEN_ID="$SAVED_SCREEN_ID"
            API_TOKEN="${SAVED_API_TOKEN:-$API_TOKEN}"

            # Ensure we have a valid token
            _ensure_api_token

            # Verify the saved screen still exists in the backend
            if [ -n "$API_TOKEN" ]; then
                local screen_status
                screen_status=$(curl -s -o /dev/null -w "%{http_code}" \
                    "${CANOPY_API}/admin/screens/${SCREEN_ID}" \
                    -H "Authorization: Bearer ${API_TOKEN}" \
                    --connect-timeout 5 --max-time 10 2>/dev/null || echo "000")
                if [ "$screen_status" = "404" ]; then
                    warn "Saved screen '${SAVED_SCREEN_NAME:-$SCREEN_ID}' no longer exists. Re-registering..."
                    SCREEN_ID=""
                    AUTO_REGISTER=true
                    # Fall through to full registration below
                else
                    ok "Using saved config: screen ${SAVED_SCREEN_NAME:-$SCREEN_ID}"
                    return
                fi
            else
                ok "Using saved config: screen ${SAVED_SCREEN_NAME:-$SCREEN_ID} (offline mode)"
                return
            fi
        fi
    fi

    PUBLIC_URL=$(cat "$URL_FILE" 2>/dev/null || echo "")
    if [ -z "$PUBLIC_URL" ]; then
        warn "No public URL yet, skipping auto-registration."
        return
    fi

    echo ""
    echo -e "${CYAN}${BOLD}  ┌──────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}${BOLD}  │   REGISTER THIS SCREEN                  │${NC}"
    echo -e "${CYAN}${BOLD}  └──────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  ${DIM}Register this camera as a screen in Canopy and${NC}"
    echo -e "  ${DIM}assign it to a campaign so customers can see it.${NC}"
    echo ""

    # Ask: do you want to register? (skip prompt if re-registering a deleted screen)
    if [ "${AUTO_REGISTER:-false}" != "true" ]; then
        echo -ne "  ${BOLD}Register this screen in Canopy? ${NC}${DIM}(Y/n):${NC} "
        read -r DO_REGISTER
        if [[ "$DO_REGISTER" == "n" || "$DO_REGISTER" == "N" ]]; then
            log "Skipping registration. You can set the stream URL manually."
            return
        fi
    fi

    # Authenticate with admin credentials
    _ensure_api_token
    if [ -z "$API_TOKEN" ]; then
        err "Auto-login failed. Skipping registration."
        return
    fi

    # Get screen name (use saved values as defaults for re-registration)
    local default_name="${SAVED_SCREEN_NAME:-}"
    local default_city="${SAVED_SCREEN_CITY:-}"
    local default_zone="${SAVED_SCREEN_ZONE:-}"

    if [ "${AUTO_REGISTER:-false}" = "true" ] && [ -n "$default_name" ]; then
        SCREEN_NAME="$default_name"
        SCREEN_CITY="$default_city"
        SCREEN_ZONE="$default_zone"
        ok "Re-using screen name: $SCREEN_NAME"
    else
        echo ""
        echo -ne "  ${BOLD}Screen name${NC} ${DIM}(e.g. \"Dubai Mall Entrance\"):${NC} "
        read -r SCREEN_NAME
        SCREEN_NAME="${SCREEN_NAME:-Screen $(date +%s)}"
        echo -ne "  ${BOLD}City${NC} ${DIM}(e.g. \"Dubai\"):${NC} "
        read -r SCREEN_CITY
        echo -ne "  ${BOLD}Zone${NC} ${DIM}(e.g. \"Mall Entrance\"):${NC} "
        read -r SCREEN_ZONE
    fi

    # List campaigns and auto-select default
    echo ""
    log "Fetching campaigns..."
    CAMPAIGNS=$(curl -s --max-time 10 "${CANOPY_API}/engagement/campaigns-list" \
        -H "Authorization: Bearer ${API_TOKEN}")

    CAMPAIGN_COUNT=$(echo "$CAMPAIGNS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

    SELECTED_CAMPAIGN=""
    SELECTED_CAMPAIGN_NAME=""
    if [ "$CAMPAIGN_COUNT" -gt 0 ]; then
        echo ""
        echo -e "  ${BOLD}Available campaigns:${NC}"
        echo "$CAMPAIGNS" | python3 -c "
import sys, json
camps = json.load(sys.stdin)
for i, c in enumerate(camps):
    print(f'    {i+1}. {c[\"name\"]} ({c[\"status\"]})')
" 2>/dev/null

        # Try to auto-select: saved campaign > "Dubai" match > single campaign
        AUTO_SELECTED=false

        # Check saved campaign from config
        if [ -n "${SAVED_CAMPAIGN_ID:-}" ]; then
            MATCH=$(echo "$CAMPAIGNS" | python3 -c "
import sys, json
camps = json.load(sys.stdin)
saved = sys.argv[1]
for c in camps:
    if c['id'] == saved:
        print(c['id'] + '|' + c['name'])
        break
" "$SAVED_CAMPAIGN_ID" 2>/dev/null || echo "")
            if [ -n "$MATCH" ]; then
                SELECTED_CAMPAIGN=$(echo "$MATCH" | cut -d'|' -f1)
                SELECTED_CAMPAIGN_NAME=$(echo "$MATCH" | cut -d'|' -f2)
                AUTO_SELECTED=true
                ok "Auto-selected saved campaign: $SELECTED_CAMPAIGN_NAME"
            fi
        fi

        # Try matching "Dubai" by name
        if [ "$AUTO_SELECTED" = "false" ]; then
            MATCH=$(echo "$CAMPAIGNS" | python3 -c "
import sys, json
camps = json.load(sys.stdin)
for c in camps:
    if 'dubai' in c['name'].lower():
        print(c['id'] + '|' + c['name'])
        break
" 2>/dev/null || echo "")
            if [ -n "$MATCH" ]; then
                SELECTED_CAMPAIGN=$(echo "$MATCH" | cut -d'|' -f1)
                SELECTED_CAMPAIGN_NAME=$(echo "$MATCH" | cut -d'|' -f2)
                AUTO_SELECTED=true
                ok "Auto-selected default campaign: $SELECTED_CAMPAIGN_NAME"
            fi
        fi

        # Single campaign — auto-select
        if [ "$AUTO_SELECTED" = "false" ] && [ "$CAMPAIGN_COUNT" -eq 1 ]; then
            MATCH=$(echo "$CAMPAIGNS" | python3 -c "
import sys, json
c = json.load(sys.stdin)[0]
print(c['id'] + '|' + c['name'])
" 2>/dev/null || echo "")
            if [ -n "$MATCH" ]; then
                SELECTED_CAMPAIGN=$(echo "$MATCH" | cut -d'|' -f1)
                SELECTED_CAMPAIGN_NAME=$(echo "$MATCH" | cut -d'|' -f2)
                AUTO_SELECTED=true
                ok "Auto-selected only campaign: $SELECTED_CAMPAIGN_NAME"
            fi
        fi

        # If not auto-selected, let user pick
        if [ "$AUTO_SELECTED" = "false" ]; then
            echo ""
            echo -ne "  ${BOLD}Assign to campaign #${NC} ${DIM}(number, or Enter to skip):${NC} "
            read -r CAMP_NUM
            if [ -n "$CAMP_NUM" ]; then
                MATCH=$(echo "$CAMPAIGNS" | python3 -c "
import sys, json
camps = json.load(sys.stdin)
idx = int(sys.argv[1]) - 1
if 0 <= idx < len(camps):
    print(camps[idx]['id'] + '|' + camps[idx]['name'])
" "$CAMP_NUM" 2>/dev/null || echo "")
                SELECTED_CAMPAIGN=$(echo "$MATCH" | cut -d'|' -f1)
                SELECTED_CAMPAIGN_NAME=$(echo "$MATCH" | cut -d'|' -f2)
            fi
        fi
    else
        warn "No campaigns found."
    fi

    # Provision the screen
    echo ""
    log "Creating screen '${SCREEN_NAME}'..."
    PROVISION_BODY="{\"screen_name\":\"${SCREEN_NAME}\",\"stream_url\":\"${PUBLIC_URL}/stream\",\"city\":\"${SCREEN_CITY}\",\"zone\":\"${SCREEN_ZONE}\""
    if [ -n "$SELECTED_CAMPAIGN" ]; then
        PROVISION_BODY="${PROVISION_BODY},\"campaign_id\":\"${SELECTED_CAMPAIGN}\""
    fi
    PROVISION_BODY="${PROVISION_BODY}}"

    PROV_RESP=$(curl -s --max-time 15 -X POST "${CANOPY_API}/engagement/provision" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -d "$PROVISION_BODY")

    PROV_SCREEN_ID=$(echo "$PROV_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('screen_id',''))" 2>/dev/null || echo "")
    PROV_MESSAGE=$(echo "$PROV_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message',''))" 2>/dev/null || echo "")

    if [ -n "$PROV_SCREEN_ID" ]; then
        SCREEN_ID="$PROV_SCREEN_ID"
        ok "$PROV_MESSAGE"

        # Save config for next restart (preserve camera settings)
        local saved_cam="${SAVED_CAMERA:-$CAMERA}"
        local saved_cam_name="${SAVED_CAMERA_NAME:-Camera $CAMERA}"
        cat > "$CONFIG_FILE" << CFGEOF
SAVED_SCREEN_ID="${SCREEN_ID}"
SAVED_SCREEN_NAME="${SCREEN_NAME}"
SAVED_SCREEN_CITY="${SCREEN_CITY}"
SAVED_SCREEN_ZONE="${SCREEN_ZONE}"
SAVED_API_TOKEN="${API_TOKEN}"
SAVED_CAMPAIGN_ID="${SELECTED_CAMPAIGN}"
SAVED_CAMPAIGN_NAME="${SELECTED_CAMPAIGN_NAME}"
SAVED_CAMERA="${saved_cam}"
SAVED_CAMERA_NAME="${saved_cam_name}"
CFGEOF
        ok "Config saved — next restart will auto-reconnect this screen"
    else
        err "Failed to create screen"
        echo "$PROV_RESP" | head -5
    fi
}


# ── Main ────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${CYAN}${BOLD}  ┌──────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}${BOLD}  │   CANOPY EDGE STREAMER                  │${NC}"
    echo -e "${CYAN}${BOLD}  │   Stream your camera to the world       │${NC}"
    echo -e "${CYAN}${BOLD}  └──────────────────────────────────────────┘${NC}"
    echo ""

    # Instance lock — prevent double-run
    acquire_lock

    # Clean runtime state (keep .config)
    cleanup_stale_pids
    rm -f "$URL_FILE"
    > "$TUNNEL_LOG" 2>/dev/null || true
    > "$STREAMER_LOG" 2>/dev/null || true
    > "$MAIN_LOG" 2>/dev/null || true

    # Step 0: Preflight checks
    preflight_checks

    # Step 1-3: Install everything
    ensure_python
    ensure_cloudflared
    setup_venv

    # Step 3.5: Login to Canopy API (get token early so everything works)
    log "Connecting to Canopy API..."
    _login
    if [ -n "$API_TOKEN" ]; then
        ok "Logged in to Canopy API"
    else
        warn "Could not reach Canopy API — screen sync will be skipped"
    fi

    # Step 3.6: Camera access + selection
    ensure_camera_access
    pick_camera

    # Step 4: Start streamer
    if ! start_streamer; then
        err "Cannot start streamer. Exiting."
        exit 1
    fi

    # Step 5: Start tunnel
    if ! start_tunnel; then
        err "Cannot create tunnel. The streamer is still running locally at http://localhost:$PORT"
        err "You can try again or use the local URL."
    fi

    # Step 6: Interactive setup — create screen + assign to campaign
    interactive_setup

    # Now that SCREEN_ID is known (from .config or provisioning),
    # update the screen's stream_url in the backend with the current tunnel URL
    if [ -f "$URL_FILE" ]; then
        PUBLIC_URL=$(cat "$URL_FILE")
        update_canopy_screen "$PUBLIC_URL"
    fi

    # Show the banner
    if [ -f "$URL_FILE" ]; then
        print_banner
    fi

    # Prevent macOS from sleeping
    prevent_sleep

    # Step 7: Watchdog
    watchdog &
    WATCHDOG_PID=$!
    echo "$WATCHDOG_PID" >> "$PID_FILE"

    ok "All systems go. Watchdog active."
    echo ""
    echo -e "  ${DIM}Streaming 24/7. Press ${BOLD}Ctrl+C${NC}${DIM} to stop.${NC}"
    echo -e "  ${DIM}Logs: ${LOG_DIR}/${NC}"
    echo ""

    # Keep alive
    while true; do
        sleep 3600
    done
}

main "$@"
