"""Canopy Edge Streaming Server — production-grade.

Captures from a USB camera (or video file) and serves:
  - MJPEG live stream at http://<ip>:8554/stream
  - Single JPEG snapshot at http://<ip>:8554/frame
  - Status page at http://<ip>:8554/
  - JSON status at http://<ip>:8554/status

Run via start.sh or directly:
  python server.py
  python server.py --camera 1
  python server.py --source video.mp4
  python server.py --resolution 1280x720 --fps 15
"""

import argparse
import logging
import os
import signal
import sys
import threading
import time
from datetime import datetime, timezone
from functools import wraps

import cv2
from flask import Flask, Response, jsonify, render_template_string, request, abort

logger = logging.getLogger("edge_streaming")

app = Flask(__name__)

_lock = threading.Lock()
_latest_frame: bytes | None = None
_frame_count: int = 0
_fps: float = 0.0
_running: bool = True
_started_at: datetime = datetime.now(timezone.utc)
_camera_info: str = ""


# ── CORS ────────────────────────────────────────────────────────────────

@app.after_request
def add_cors_headers(response):
    origin = os.environ.get("CORS_ORIGIN", "*")
    response.headers["Access-Control-Allow-Origin"] = origin
    response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
    return response


# ── Auth ────────────────────────────────────────────────────────────────

def check_stream_token(f):
    """Optional token auth: if STREAM_TOKEN env var is set, require ?token= match."""
    @wraps(f)
    def wrapper(*args, **kwargs):
        expected = os.environ.get("STREAM_TOKEN", "")
        if expected:
            provided = request.args.get("token", "")
            if provided != expected:
                abort(401, description="Invalid or missing stream token")
        return f(*args, **kwargs)
    return wrapper


# ── Status page ─────────────────────────────────────────────────────────

STATUS_PAGE = """
<!DOCTYPE html>
<html lang="en">
<head>
  <title>Canopy Edge Streamer</title>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
           background: #111; color: #fff; min-height: 100vh; }
    .container { max-width: 960px; margin: 0 auto; padding: 24px; }
    h1 { font-size: 20px; font-weight: 700; color: #FF5F0F; margin-bottom: 4px; }
    .sub { font-size: 13px; color: #888; margin-bottom: 24px; }
    .stream-box { background: #000; border-radius: 12px; overflow: hidden;
                  border: 1px solid #333; margin-bottom: 20px; position: relative; }
    .stream-box img { width: 100%; display: block; }
    .live-badge { position: absolute; top: 12px; left: 12px; background: #dc2626;
                  padding: 2px 10px; border-radius: 20px; font-size: 11px;
                  font-weight: 700; display: flex; align-items: center; gap: 6px; }
    .live-dot { width: 6px; height: 6px; border-radius: 50%; background: #fff;
                animation: pulse 1.5s infinite; }
    @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: 0.3; } }
    .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
             gap: 12px; margin-bottom: 20px; }
    .stat { background: #1a1a1a; border-radius: 10px; padding: 16px; border: 1px solid #333; }
    .stat-label { font-size: 10px; text-transform: uppercase; letter-spacing: 1px;
                  color: #666; margin-bottom: 6px; }
    .stat-value { font-size: 22px; font-weight: 700; }
    .urls { background: #1a1a1a; border-radius: 10px; padding: 16px; border: 1px solid #333; }
    .urls h3 { font-size: 12px; color: #888; text-transform: uppercase;
               letter-spacing: 1px; margin-bottom: 10px; }
    .url-row { display: flex; justify-content: space-between; align-items: center;
               padding: 8px 0; border-bottom: 1px solid #222; }
    .url-row:last-child { border: none; }
    .url-label { font-size: 13px; color: #aaa; }
    .url-value { font-size: 13px; font-family: monospace; color: #FF5F0F; }
  </style>
</head>
<body>
  <div class="container">
    <h1>Canopy Edge Streamer</h1>
    <p class="sub">{{ camera_info }}</p>
    <div class="stream-box">
      <img src="/stream" alt="Live camera stream">
      <div class="live-badge"><span class="live-dot"></span>LIVE</div>
    </div>
    <div class="stats">
      <div class="stat"><div class="stat-label">FPS</div><div class="stat-value">{{ fps }}</div></div>
      <div class="stat"><div class="stat-label">Frames</div><div class="stat-value">{{ frames }}</div></div>
      <div class="stat"><div class="stat-label">Uptime</div><div class="stat-value">{{ uptime }}</div></div>
      <div class="stat"><div class="stat-label">Status</div><div class="stat-value" style="color:#22c55e;">Online</div></div>
    </div>
    <div class="urls">
      <h3>Stream URLs</h3>
      <div class="url-row"><span class="url-label">MJPEG Stream</span><span class="url-value">http://{{ host }}:{{ port }}/stream</span></div>
      <div class="url-row"><span class="url-label">Snapshot</span><span class="url-value">http://{{ host }}:{{ port }}/frame</span></div>
      <div class="url-row"><span class="url-label">Status JSON</span><span class="url-value">http://{{ host }}:{{ port }}/status</span></div>
    </div>
  </div>
</body>
</html>
"""


def _get_local_ip() -> str:
    import socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(2)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "localhost"


def _safe_stats() -> tuple[float, int]:
    """Read fps and frame_count under lock."""
    with _lock:
        return _fps, _frame_count


# ── Capture thread ──────────────────────────────────────────────────────

def capture_loop(source, resolution: tuple[int, int] | None, target_fps: int):
    global _latest_frame, _frame_count, _fps, _running, _camera_info

    if isinstance(source, int):
        cap = cv2.VideoCapture(source)
        _camera_info = f"Camera index {source}"
    else:
        cap = cv2.VideoCapture(source)
        _camera_info = f"Source: {source}"

    if not cap.isOpened():
        logger.error("Cannot open camera/source: %s", source)
        _running = False
        return

    if resolution:
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, resolution[0])
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, resolution[1])

    actual_w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    actual_h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    _camera_info += f" @ {actual_w}x{actual_h}"
    logger.info("Camera opened: %s", _camera_info)

    interval = 1.0 / target_fps if target_fps > 0 else 0
    fps_start = time.monotonic()
    fps_count = 0
    consecutive_failures = 0
    consecutive_black = 0

    while _running:
        ret, frame = cap.read()
        if not ret:
            consecutive_failures += 1
            if isinstance(source, int):
                if consecutive_failures > 15:
                    # Try reconnecting the camera before giving up
                    logger.warning("Camera read failed %d times, attempting reconnect...", consecutive_failures)
                    cap.release()
                    time.sleep(1)
                    cap = cv2.VideoCapture(source)
                    if not cap.isOpened():
                        logger.error("Camera reconnect failed, giving up")
                        break
                    if resolution:
                        cap.set(cv2.CAP_PROP_FRAME_WIDTH, resolution[0])
                        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, resolution[1])
                    logger.info("Camera reconnected successfully")
                    consecutive_failures = 0
                    continue
                if consecutive_failures > 30:
                    logger.error("Camera read failed %d times after reconnect, giving up", consecutive_failures)
                    break
                time.sleep(0.5)
                continue
            else:
                cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
                continue

        consecutive_failures = 0

        # Detect black frames (camera open but not authorized, e.g. macOS privacy)
        try:
            if frame.mean() < 1.0:
                consecutive_black += 1
                if consecutive_black == 30:
                    logger.warning(
                        "Camera is returning black frames — check camera permissions. "
                        "On macOS: System Settings > Privacy & Security > Camera"
                    )
            else:
                consecutive_black = 0
        except Exception:
            pass

        # Encode frame to JPEG — handle failure gracefully
        try:
            ok_enc, jpeg = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 80])
            if not ok_enc:
                logger.warning("JPEG encoding failed, skipping frame")
                continue
            jpeg_bytes = jpeg.tobytes()
        except Exception as e:
            logger.warning("Frame encoding error: %s", e)
            continue

        with _lock:
            _latest_frame = jpeg_bytes
            _frame_count += 1

        fps_count += 1
        elapsed = time.monotonic() - fps_start
        if elapsed >= 2.0:
            with _lock:
                _fps = round(fps_count / elapsed, 1)
            fps_count = 0
            fps_start = time.monotonic()

        if interval > 0:
            time.sleep(interval)

    cap.release()
    logger.info("Capture loop ended")


def _generate_mjpeg():
    while _running:
        with _lock:
            frame = _latest_frame
        if frame is None:
            time.sleep(0.05)
            continue
        yield (
            b"--frame\r\n"
            b"Content-Type: image/jpeg\r\n\r\n" + frame + b"\r\n"
        )
        time.sleep(0.033)


# ── Routes ──────────────────────────────────────────────────────────────

@app.route("/")
def index():
    ip = _get_local_ip()
    uptime_s = int((datetime.now(timezone.utc) - _started_at).total_seconds())
    m, s = divmod(uptime_s, 60)
    h, m = divmod(m, 60)
    uptime = f"{h}h {m}m" if h > 0 else f"{m}m {s}s"
    fps, frames = _safe_stats()

    return render_template_string(
        STATUS_PAGE,
        camera_info=_camera_info,
        fps=fps,
        frames=frames,
        uptime=uptime,
        host=ip,
        port=app.config.get("PORT", 8554),
    )


@app.route("/stream")
@check_stream_token
def stream():
    resp = Response(
        _generate_mjpeg(),
        mimetype="multipart/x-mixed-replace; boundary=frame",
    )
    resp.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    resp.headers["X-Accel-Buffering"] = "no"
    return resp


@app.route("/frame")
@check_stream_token
def frame():
    with _lock:
        jpeg = _latest_frame
    if jpeg is None:
        return Response("No frame yet", status=503)
    resp = Response(jpeg, mimetype="image/jpeg")
    resp.headers["Content-Length"] = str(len(jpeg))
    resp.headers["Cache-Control"] = "no-cache"
    return resp


@app.route("/cameras")
def cameras():
    """Enumerate available cameras on this system."""
    import json as json_mod
    import platform
    import subprocess
    import glob

    camera_list = []
    names = {}
    os_name = platform.system()

    # Get friendly names from OS
    if os_name == "Darwin":
        try:
            raw = subprocess.check_output(
                ["system_profiler", "SPCameraDataType", "-json"],
                stderr=subprocess.DEVNULL, timeout=5,
            )
            data = json_mod.loads(raw)
            for i, cam in enumerate(data.get("SPCameraDataType", [])):
                names[i] = cam.get("_name", f"Camera {i}")
        except Exception:
            pass
    elif os_name == "Linux":
        devs = sorted(glob.glob("/dev/video*"))
        for dev in devs:
            try:
                idx = int(dev.replace("/dev/video", ""))
                out = subprocess.check_output(
                    ["v4l2-ctl", "--device", dev, "--info"],
                    stderr=subprocess.DEVNULL, timeout=3,
                ).decode()
                for line in out.splitlines():
                    if "Card type" in line:
                        names[idx] = line.split(":", 1)[1].strip()
                        break
            except Exception:
                pass

    # Probe indices 0-9 with OpenCV
    for i in range(10):
        cap = cv2.VideoCapture(i)
        if cap.isOpened():
            w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
            h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
            name = names.get(i, f"Camera {i}")
            camera_list.append({"index": i, "name": name, "resolution": f"{w}x{h}"})
            cap.release()

    body = json_mod.dumps(camera_list)
    return Response(body, mimetype="application/json")


@app.route("/status")
def status():
    fps, frames = _safe_stats()
    uptime_s = int((datetime.now(timezone.utc) - _started_at).total_seconds())
    import json as json_mod
    body = json_mod.dumps({
        "status": "streaming" if _running and _latest_frame else "starting",
        "camera": _camera_info,
        "fps": fps,
        "frames": frames,
        "uptime_seconds": uptime_s,
    })
    resp = Response(body, mimetype="application/json")
    resp.headers["Content-Length"] = str(len(body))
    resp.headers["Cache-Control"] = "no-cache"
    return resp


# ── Auto-start capture for gunicorn ─────────────────────────────────────

def _auto_start_capture():
    """Start capture thread automatically when running under gunicorn."""
    import os as _os
    source_env = _os.environ.get("SOURCE", "")
    camera_env = _os.environ.get("CAMERA", "0")
    res_env = _os.environ.get("RESOLUTION", "640x480")
    fps_raw = _os.environ.get("FPS", "15")

    # Validate CAMERA index
    if source_env:
        source = source_env
    else:
        try:
            source = int(camera_env)
        except (ValueError, TypeError):
            logger.warning("Invalid CAMERA='%s', defaulting to 0", camera_env)
            source = 0

    # Validate FPS
    try:
        fps_env = int(fps_raw)
    except (ValueError, TypeError):
        logger.warning("Invalid FPS='%s', defaulting to 15", fps_raw)
        fps_env = 15

    # Validate RESOLUTION
    res = None
    try:
        parts = res_env.lower().split("x")
        if len(parts) == 2:
            res = (int(parts[0]), int(parts[1]))
    except (ValueError, TypeError):
        logger.warning("Invalid RESOLUTION='%s', using camera default", res_env)

    cap_thread = threading.Thread(target=capture_loop, args=(source, res, fps_env), daemon=True)
    cap_thread.start()


if __name__ != "__main__":
    _auto_start_capture()


# ── Entrypoint ──────────────────────────────────────────────────────────

def main():
    global _running

    parser = argparse.ArgumentParser(description="Canopy Edge Streaming Server")
    parser.add_argument("--camera", type=int, default=0, help="Camera index (default: 0)")
    parser.add_argument("--source", type=str, default=None, help="Video file or RTSP URL instead of camera")
    parser.add_argument("--resolution", type=str, default="640x480", help="Resolution WxH (default: 640x480)")
    parser.add_argument("--fps", type=int, default=15, help="Target FPS (default: 15)")
    parser.add_argument("--port", type=int, default=8554, help="Server port (default: 8554)")
    parser.add_argument("--host", type=str, default="0.0.0.0", help="Bind address (default: 0.0.0.0)")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    res = None
    if args.resolution:
        parts = args.resolution.lower().split("x")
        try:
            if len(parts) == 2:
                res = (int(parts[0]), int(parts[1]))
        except ValueError:
            logger.error("Invalid resolution format: %s (expected WxH, e.g. 640x480)", args.resolution)
            sys.exit(1)

    source = args.source if args.source else args.camera

    def signal_handler(sig, _frame):
        global _running
        logger.info("Received signal %d, shutting down...", sig)
        _running = False
        threading.Timer(3.0, lambda: os._exit(0)).start()

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # On macOS, open the camera on the MAIN thread first to trigger the
    # permission dialog. AVFoundation requires main-thread access for auth.
    # Then release it so the capture thread can re-open it.
    if isinstance(source, int):
        logger.info("Initializing camera %d on main thread (macOS auth)...", source)
        _warmup = cv2.VideoCapture(source)
        if _warmup.isOpened():
            _warmup.read()  # trigger actual frame grab to confirm auth
            _warmup.release()
            logger.info("Camera authorized.")
        else:
            logger.warning("Camera %d could not be opened on main thread.", source)

    cap_thread = threading.Thread(target=capture_loop, args=(source, res, args.fps), daemon=True)
    cap_thread.start()
    time.sleep(1)

    ip = _get_local_ip()
    token_hint = ""
    if os.environ.get("STREAM_TOKEN"):
        token_hint = f"  Auth:      token required (?token=...)\n"

    print(f"""
{'=' * 50}
  CANOPY EDGE STREAMER
{'=' * 50}
  Camera:    {_camera_info or source}
  Stream:    http://{ip}:{args.port}/stream
  Snapshot:  http://{ip}:{args.port}/frame
  Dashboard: http://{ip}:{args.port}/
{token_hint}{'=' * 50}
""")

    app.config["PORT"] = args.port
    app.run(host=args.host, port=args.port, threaded=True)


if __name__ == "__main__":
    main()
